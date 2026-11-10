// Preparing and starting playback, and the playback controls.
#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import os
import PDFKit
import SwiftUI
import WebKit

extension ArticleSpeechService {
    /// Everything the main actor needs to start playback, computed off-main.
    struct PlaybackPreparation {
        let narrationText: String
        let contentSignature: String
        let sourceContentSignature: String?
        let narrationPreparationSignature: String?
        let speakableText: String?
        let chunks: [String]
        let manifest: SyncedArticleAudioManifest?
        let manifestChunkTexts: [String]?
        let hasCompleteRequestCache: Bool
        /// Characters of narration that have no cached audio yet and would be
        /// billed to the cloud provider if generation starts. 0 for free
        /// providers and fully cached sources.
        let uncachedCharacterCount: Int
        let savedPosition: ArticleSpeechPlaybackPosition?
        let model: String
        let voice: String
    }

    struct SyncedResumeResolution {
        let chunkIndex: Int?
        let offset: TimeInterval
        let loadedDurations: [Int: TimeInterval]
        let totalDuration: TimeInterval?
        let shouldClearSavedPosition: Bool
    }

    nonisolated static func preparePlayback(
        sourceID: String,
        content: String,
        provider: MacArticleSpeechMode,
        model: String,
        voice: String,
        isPaper: Bool,
        sourceContentSignature: String?,
        narrationPreparationSignature: String?,
        accountPosition: ArticleSpeechPlaybackPosition? = nil
    ) -> PlaybackPreparation {
        let narrationText = isPaper
            ? MacArticleSpeechText.paperNarrationText(from: content)
            : MacArticleSpeechText.narrationText(from: content)
        let contentSignature = SyncedArticleAudioStore.contentSignature(for: narrationText)
        // Apple speech used to bypass the full narration cleanup and speak the
        // raw PDF extraction, even though cloud voices received cleaned chunks.
        // All providers must consume the exact same preflight-cleaned text.
        let speakableText = MacArticleSpeechText.speakableInput(from: narrationText)
        // Boundaries only move for a generation that has no complete manifest
        // yet; anything already generated replays from its manifest's own chunk
        // texts, so cached audio keeps seeking and resuming exactly as before.
        let chunks = narrationChunks(
            from: narrationText,
            maxLength: chunkLimit(for: provider, model: model),
            firstChunkMaxLength: firstChunkLimit(for: provider, model: model),
            leadChunkCount: leadChunkCount(for: provider)
        )

        var manifest: SyncedArticleAudioManifest?
        var manifestChunkTexts: [String]?
        if provider.isCloudProvider,
           let complete = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID),
           complete.usesSupportedPlaybackFormat,
           firstSyncedChunkIsAvailable(in: complete),
           cachedContentMatches(
               manifest: complete,
               content: content,
               narrationSignature: contentSignature,
               isPaper: isPaper
           ) {
            let sortedChunks = complete.chunks.sorted { $0.index < $1.index }
            let texts = sortedChunks.compactMap(\.text)
            // This is already-generated, content-matched audio. Its recorded
            // model, voice, and chunking outrank this Mac's current settings;
            // changing a preference must not hide audio made on the iPhone.
            manifest = complete
            if texts.count == sortedChunks.count {
                manifestChunkTexts = texts
            }
        }

        return PlaybackPreparation(
            narrationText: narrationText,
            contentSignature: contentSignature,
            sourceContentSignature: sourceContentSignature,
            narrationPreparationSignature: narrationPreparationSignature,
            speakableText: speakableText,
            chunks: chunks,
            manifest: manifest,
            manifestChunkTexts: manifestChunkTexts,
            hasCompleteRequestCache: manifest != nil
                || completeRequestCacheExists(
                    chunks: chunks,
                    provider: provider,
                    model: model,
                    voice: voice
                ),
            uncachedCharacterCount: manifest != nil
                ? 0
                : uncachedCharacterCount(
                    chunks: chunks,
                    provider: provider,
                    model: model,
                    voice: voice
                ),
            // Generation 2's account copy is the source's ReadingState; the newer saved time wins.
            savedPosition: ListeningPositionSync.newest(SyncedArticleAudioStore.loadPlaybackPosition(sourceID: sourceID), accountPosition),
            model: model,
            voice: voice
        )
    }

    private nonisolated static func completeRequestCacheExists(
        chunks: [String],
        provider: MacArticleSpeechMode,
        model: String,
        voice: String
    ) -> Bool {
        guard provider.isCloudProvider, !chunks.isEmpty else { return false }
        for chunk in chunks {
            guard let parts = MacArticleTTSClient.requestCacheParts(
                provider: provider,
                model: model,
                voice: voice,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                text: chunk
            ) else {
                return false
            }
            let cacheKey = ArticleSpeechAudioCache.key(parts: parts)
            guard ArticleSpeechAudioCache.hasData(for: cacheKey) else { return false }
        }
        return true
    }

    /// Total characters of chunks that would need fresh (billable) generation.
    /// Chunks whose request cache is already on disk play back for free.
    nonisolated static func uncachedCharacterCount(
        chunks: [String],
        provider: MacArticleSpeechMode,
        model: String,
        voice: String
    ) -> Int {
        guard provider.isCloudProvider else { return 0 }
        var total = 0
        for chunk in chunks {
            if let parts = MacArticleTTSClient.requestCacheParts(
                provider: provider,
                model: model,
                voice: voice,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                text: chunk
            ), ArticleSpeechAudioCache.hasData(for: ArticleSpeechAudioCache.key(parts: parts)) {
                continue
            }
            total += chunk.count
        }
        return total
    }

    private func applySavedPosition(_ preparation: PlaybackPreparation) {
        pendingResumeGlobalTime = nil
        pendingResumeAppleCharacterOffset = nil
        guard let saved = preparation.savedPosition else { return }
        if let savedSignature = saved.contentSignature, savedSignature != preparation.contentSignature {
            return
        }
        pendingResumeGlobalTime = saved.globalTime >= Self.minimumResumeInterval ? saved.globalTime : nil
        pendingResumeAppleCharacterOffset = saved.appleCharacterOffset
    }

    /// Publishes playback state and starts audio. All heavy work already
    /// happened off-main in `preparePlayback`; this only mutates UI state.
    func startPlayback(
        article: StudioArticle,
        preparation: PlaybackPreparation,
        provider: MacArticleSpeechMode
    ) {
        guard let speakableText = preparation.speakableText else {
            isLoading = false
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            return
        }

        applySavedPosition(preparation)
        activeNarrationSignature = preparation.contentSignature
        activeArticleID = article.id
        nowPlayingTitle = article.title
        loadNowPlayingArtwork(for: article)
        errorMessage = nil
        isPlaying = true
        isPaused = false
        appleSpeechBaseCharacterOffset = pendingResumeAppleCharacterOffset ?? 0
        appleSpeechCharacterOffset = appleSpeechBaseCharacterOffset
        updateNowPlayingInfo()
        Task { [activityStorage] in
            do {
                try await activityStorage.recordScheduledSourceActivity(
                    sourceID: article.id,
                    on: Date(),
                    kind: .listening
                )
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening activity for \(article.id, privacy: .public): \(error.localizedDescription)"
                )
            }
        }

        if provider == .apple {
            var textToSpeak = speakableText
            if let resumeOffset = pendingResumeAppleCharacterOffset,
               resumeOffset > 0,
               resumeOffset < speakableText.count {
                let startIndex = speakableText.index(speakableText.startIndex, offsetBy: resumeOffset)
                textToSpeak = String(speakableText[startIndex...])
            }
            pendingResumeAppleCharacterOffset = nil

            let utterance = AVSpeechUtterance(string: textToSpeak)
            utterance.prefersAssistiveTechnologySettings = false
            utterance.rate = Self.appleSpeechRate(for: speed)
            utterance.pitchMultiplier = 0.95
            if let identifier = activeAppleVoiceIdentifier ?? appleVoiceIdentifier,
               let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                utterance.voice = voice
            }
            isLoading = false
            synthesizer.speak(utterance)
            return
        }

        syncedAudioContext = SyncedArticleAudioContext(
            sourceID: article.id,
            title: article.title,
            subtitle: displaySubtitle(for: article),
            sourceType: article.sourceType.rawValue,
            sourceURL: article.url,
            provider: provider,
            model: preparation.model,
            voice: preparation.voice,
            voiceLabel: providerVoiceLabel(
                provider: provider,
                voice: preparation.voice,
                model: preparation.model
            ),
            contentSignature: preparation.contentSignature,
            sourceContentSignature: preparation.sourceContentSignature,
            narrationPreparationSignature: preparation.narrationPreparationSignature,
            totalCharacters: preparation.narrationText.count,
            sourceText: preparation.narrationText,
            fileExtension: Self.syncedAudioFileExtension(provider: provider, model: preparation.model),
            createdAt: Date()
        )

        if let manifest = preparation.manifest {
            // Prefer the chunk texts recorded in the manifest: they match the
            // audio files exactly, so seeking and resume stay aligned even when
            // the current provider would chunk the source differently.
            audioChunks = preparation.manifestChunkTexts ?? preparation.chunks
            beginSyncedPlayback(manifest: manifest)
            return
        }

        audioChunks = preparation.chunks
        guard !audioChunks.isEmpty else {
            stop()
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            return
        }
        audioChunkIndex = 0
        isLoading = true
        let generationID = UUID()
        audioGenerationID = generationID
        if !preparation.hasCompleteRequestCache {
            audioGenerationProgress = ArticleSpeechChunkProgress(
                completedChunks: 0,
                totalChunks: audioChunks.count
            )
            articleSpeechLogger.info(
                "Text-to-speech generation started: \(self.audioChunks.count) chunks, \(preparation.narrationText.count) characters"
            )
            ArticleSpeechDiagnostics.append(
                "GENERATION_STARTED provider=\(provider.rawValue) chunks=\(audioChunks.count) characters=\(preparation.narrationText.count) source=\(article.id)"
            )
        } else {
            articleSpeechLogger.info(
                "Text-to-speech replay started from request cache: \(self.audioChunks.count) chunks"
            )
        }
        prefetchAllAudioChunks(generationID: generationID)

        startPlaybackTask { [weak self] in
            if await self?.applyPendingResumeIfNeeded() == true { return }
            await self?.playNextChunk()
        }
    }

    /// Replaces the active playback task, cancelling the previous one from the
    /// outside. The replacement must never cancel `playbackTask` from within
    /// its own body — that self-cancels and silently aborts the operation.
    func startPlaybackTask(_ operation: @escaping @MainActor () async -> Void) {
        playbackTask?.cancel()
        playbackTask = Task { await operation() }
    }

    func pauseOrResume() {
        guard isPlaying else { return }
        if mode == .apple {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
                isPaused = false
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isPaused = true
                savePlaybackPositionNow()
            }
            updateNowPlayingInfo()
            return
        }

        if isBufferingNextChunk {
            isPaused.toggle()
            if isPaused {
                savePlaybackPositionNow()
            }
            updateNowPlayingInfo()
            return
        }

        guard let audioPlayer else {
            // No player and not buffering: a chunk failed and playback paused in
            // place. Resume retries the failed chunk from the saved position.
            if isPaused {
                isPaused = false
                errorMessage = nil
                startPlaybackTask { [weak self] in
                    await self?.playNextChunk()
                }
                updateNowPlayingInfo()
            }
            return
        }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            isPaused = true
            savePlaybackPositionNow()
        } else {
            audioPlayer.play()
            isPaused = false
        }
        updateNowPlayingInfo()
    }

    func skipBackward(seconds: TimeInterval = 15) {
        guard canSeek else { return }

        if let player = audioPlayer {
            let offset = player.currentTime
            if offset >= seconds {
                player.currentTime = offset - seconds
                playbackCurrentTime = currentGlobalPlaybackTime()
                updateNowPlayingInfo()
                return
            }

            var remaining = seconds - offset
            var chunkIndex = currentlyPlayingChunkIndex - 1
            while chunkIndex >= 0 {
                guard let duration = chunkDurations[chunkIndex], duration > 0 else { break }
                if remaining <= duration {
                    startPlaybackTask { [weak self] in
                        await self?.jumpToChunk(chunkIndex, offset: duration - remaining)
                    }
                    return
                }
                remaining -= duration
                chunkIndex -= 1
            }
        }

        seek(to: max(0, currentGlobalPlaybackTime() - seconds))
    }

    func skipForward(seconds: TimeInterval = 15) {
        guard canSeek else { return }

        if let player = audioPlayer {
            let offset = player.currentTime
            let duration = chunkDurations[currentlyPlayingChunkIndex] ?? player.duration
            if duration > 0, offset + seconds <= duration {
                player.currentTime = offset + seconds
                playbackCurrentTime = currentGlobalPlaybackTime()
                updateNowPlayingInfo()
                return
            }

            var remaining = seconds - max(0, duration - offset)
            var chunkIndex = currentlyPlayingChunkIndex + 1
            while chunkIndex < totalChunkCount {
                guard let chunkDuration = chunkDurations[chunkIndex], chunkDuration > 0 else { break }
                if remaining <= chunkDuration {
                    startPlaybackTask { [weak self] in
                        await self?.jumpToChunk(chunkIndex, offset: remaining)
                    }
                    return
                }
                remaining -= chunkDuration
                chunkIndex += 1
            }
        }

        seek(to: min(playbackDuration, currentGlobalPlaybackTime() + seconds))
    }

    func cycleSpeed() {
        speed = MacArticleSpeechSpeed.nextOption(after: speed)
    }

    func startSleepTimer(duration: TimeInterval) {
        guard duration > 0 else { return }
        cancelSleepTimer()
        let endsAt = Date().addingTimeInterval(duration)
        sleepTimerEndsAt = endsAt
        sleepTimerRemaining = duration
        sleepTimerTask = Task { [weak self, endsAt] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self?.sleepTimerEndsAt == endsAt else { return }
                let remaining = endsAt.timeIntervalSinceNow
                if remaining <= 0 {
                    self?.deferPublishedUpdate { [weak self] in
                        guard self?.sleepTimerEndsAt == endsAt else { return }
                        self?.cancelSleepTimer()
                        self?.stop()
                    }
                    return
                }
                self?.deferPublishedUpdate { [weak self] in
                    guard self?.sleepTimerEndsAt == endsAt else { return }
                    self?.sleepTimerRemaining = remaining
                }
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepTimerRemaining = nil
    }

    func seek(to time: TimeInterval) {
        guard canSeek else { return }
        let clamped = min(max(time, 0), playbackDuration)
        let (chunkIndex, offset) = location(forGlobalTime: clamped)
        let availableLimit = availableSeekChunkLimit()
        guard chunkIndex <= availableLimit else { return }

        startPlaybackTask { [weak self] in
            await self?.jumpToChunk(chunkIndex, offset: offset)
            self?.savePlaybackPositionNow()
        }
    }

    func seek(toFraction fraction: Double) {
        guard playbackDuration > 0 else { return }
        seek(to: playbackDuration * min(max(fraction, 0), 1))
    }
}
#endif
