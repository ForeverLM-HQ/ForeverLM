// Playback rate, remote commands, now playing info and the synced audio manifest.
#if os(macOS)
import CoreAudio
import Foundation
import MediaPlayer
import SwiftUI

extension ArticleSpeechService {
    func applyAudioPlaybackRate() {
        guard mode.isCloudProvider, let audioPlayer else { return }
        audioPlayer.enableRate = true
        audioPlayer.rate = Self.audioPlaybackRate(for: speed)
        updateNowPlayingInfo()
    }

    func installRemoteCommandHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, self.isPaused else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipBackward()
            }
            return .success
        }

        // AirPods' double press and triple press (and the keyboard's next and
        // previous keys) arrive as next and previous track. A narration has no
        // track list, so they skip within it, as a podcast player does.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.skipForward()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.skipBackward()
            }
            return .success
        }

        // Stop pauses in place; closing the narration stays the learner's own.
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.pauseOrResume()
            }
            return .success
        }
    }

    /// Pauses Listen when the default output stops being Bluetooth headphones:
    /// AirPods put back in the case, switched to the iPhone, or out of range.
    /// macOS moves the sound to the speakers, and a narration carrying on out
    /// loud is the wrong answer; music players pause there too.
    func installOutputDeviceWatcher() {
        guard outputDeviceWatcher == nil else { return }
        recordOutputDevice()
        outputDeviceWatcher = MacDefaultAudioDevicesWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.outputDeviceChanged()
            }
        }
    }

    private func recordOutputDevice() {
        outputDeviceID = MacAudioDevice.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        outputDeviceIsBluetooth = MacAudioDevice.isBluetooth(outputDeviceID)
    }

    private func outputDeviceChanged() {
        let previousID = outputDeviceID
        let leftHeadphones = outputDeviceIsBluetooth
        recordOutputDevice()
        // The watcher also reports input changes; only a new output counts.
        guard outputDeviceID != previousID, leftHeadphones else { return }
        guard isPlaying, !isPaused else { return }
        pauseOrResume()
    }

    func updateNowPlayingInfo() {
        guard isPlaying, let title = nowPlayingTitle else {
            clearNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "ForeverLM",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0 : playbackNowPlayingRate
        ]
        if playbackDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        }
        // The book (or author) reads as the album line under the title.
        if let subtitle = nowPlayingSubtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let nowPlayingArtwork, nowPlayingArtworkSourceID == activeArticleID {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPaused ? .paused : .playing
    }

    private var playbackNowPlayingRate: Double {
        if mode == .apple {
            return isPaused ? 0 : 1
        }
        return Double(Self.audioPlaybackRate(for: speed))
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func writeSyncedAudioManifest(chunks: [SyncedArticleAudioManifest.Chunk]) {
        guard let context = syncedAudioContext,
              !chunks.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in self?.errorMessage = failure }
            }
        }
    }

    func writeSyncedAudioManifestFromSavedChunks() {
        guard let context = syncedAudioContext,
              !audioChunks.isEmpty else { return }
        let chunkCount = audioChunks.count
        let chunkTexts = audioChunks

        Task.detached(priority: .utility) { [weak self] in
            let chunks: [SyncedArticleAudioManifest.Chunk] = (0..<chunkCount).compactMap { index in
                let url = SyncedArticleAudioStore.chunkURL(
                    sourceID: context.sourceID,
                    index: index,
                    fileExtension: context.fileExtension
                )
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0 else { return nil }
                return SyncedArticleAudioManifest.Chunk(
                    index: index,
                    fileName: url.lastPathComponent,
                    byteCount: size,
                    text: index < chunkTexts.count ? chunkTexts[index] : nil
                )
            }

            guard chunks.count == chunkCount else { return }
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in self?.errorMessage = failure }
            }
        }
    }

    /// Verify every chunk file exists, then write the synced source text and manifest.
    /// Blocking file I/O against the iCloud-synced Audio folder — never call on the main actor.
    nonisolated static func persistSyncedAudio(
        context: SyncedArticleAudioContext,
        chunks: [SyncedArticleAudioManifest.Chunk]
    ) -> String? {
        let sortedChunks = chunks.sorted { $0.index < $1.index }
        let chunkDirectory = SyncedArticleAudioStore.sourceDirectory(sourceID: context.sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        guard sortedChunks.allSatisfy({
            FileManager.default.fileExists(atPath: chunkDirectory.appendingPathComponent($0.fileName).path)
        }) else { return nil }

        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion,
            sourceID: context.sourceID,
            title: context.title,
            subtitle: context.subtitle,
            sourceType: context.sourceType,
            sourceURL: context.sourceURL,
            provider: context.provider.rawValue,
            model: context.model,
            voice: context.voice,
            voiceLabel: context.voiceLabel,
            contentSignature: context.contentSignature,
            totalCharacters: context.totalCharacters,
            createdAt: context.createdAt,
            chunks: sortedChunks,
            sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
            narrationVersion: context.sourceType == StudioSourceType.paper.rawValue
                ? PaperNarrationFilter.version
                : nil,
            sourceContentSignature: context.sourceContentSignature,
            narrationPreparationSignature: context.narrationPreparationSignature,
            generatedOnPlatform: "macos",
            pcmSampleRate: ArticleSpeechCatalog.pcmSampleRate(forModel: context.model)
        )

        do {
            try SyncedArticleAudioStore.saveSourceText(context.sourceText, sourceID: context.sourceID)
            try SyncedArticleAudioStore.saveManifest(manifest)
            ArticleSpeechAudioCache.markCached(articleID: context.sourceID)
            // Opportunistic housekeeping while already off-main: the per-request
            // cache is otherwise append-only and would grow without bound.
            ArticleSpeechAudioCache.pruneStaleEntries()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
