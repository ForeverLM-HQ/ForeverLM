// Playback rate, remote commands, now playing info and the synced audio manifest.
#if os(macOS)
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
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPaused ? .paused : .playing
        }
    }

    private var playbackNowPlayingRate: Double {
        if mode == .apple {
            return isPaused ? 0 : 1
        }
        return Double(Self.audioPlaybackRate(for: speed))
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
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
            generatedOnPlatform: "macos"
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
