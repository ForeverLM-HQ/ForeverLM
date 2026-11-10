// Stopping, chunk playback and synced audio playback.
#if os(macOS)
import AVFoundation
import Foundation
import SwiftUI

extension ArticleSpeechService {
    /// Stops playback. By default any in-flight audio generation is cancelled
    /// and its partial synced audio cleaned up (explicit stop/cancel actions).
    /// Pass `detachingGeneration: true` when the listener is merely moving to
    /// another source — the generation then keeps running in the background
    /// until every chunk is synced and the manifest is written.
    func stop(detachingGeneration: Bool = false) {
        let sourceID = activeArticleID
        let positionSnapshot = capturePlaybackPositionSnapshot()

        let didDetachGeneration = detachingGeneration && detachActiveGenerationForBackgroundCompletion()

        let partialGenerationSourceID: String? = {
            guard !didDetachGeneration,
                  mode.isCloudProvider,
                  let progress = audioGenerationProgress,
                  !progress.isComplete else {
                return nil
            }
            return syncedAudioContext?.sourceID ?? activeArticleID
        }()

        cancelSleepTimer()
        clearNowPlayingInfo()
        playbackEpoch += 1
        playbackTask?.cancel()
        playbackTask = nil
        audioGenerationID = UUID()
        preparationRequestID = UUID()
        foregroundGenerationChunksRemaining = 0
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        preloadedNextPlayer = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        audioChunks = []
        audioChunkIndex = 0
        syncedChunkURLs = []
        completedSyncedChunks = []
        failedGenerationChunkCount = 0
        activeArticleID = nil
        preparingArticleID = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        syncedAudioContext = nil
        audioGenerationProgress = nil
        preparationStatus = nil
        isPlaying = false
        isPaused = false
        isLoading = false
        hasStartedPlayback = false
        highestReadyChunkIndex = -1
        pendingResumeGlobalTime = nil
        pendingResumeAppleCharacterOffset = nil
        activeNarrationSignature = nil
        appleSpeechBaseCharacterOffset = 0
        appleSpeechCharacterOffset = 0
        lastPlaybackPositionSaveAt = nil
        lastAccountPositionSaveAt = nil
        resetPlaybackPosition()

        if let sourceID, let positionSnapshot {
            persistPlaybackPosition(positionSnapshot, sourceID: sourceID)
        }

        if let partialGenerationSourceID {
            Task.detached {
                if SyncedArticleAudioStore.loadCompleteManifest(sourceID: partialGenerationSourceID) == nil {
                    ArticleSpeechAudioCache.deleteCachedAudio(sourceID: partialGenerationSourceID, forgettingReplicaNarration: false)
                }
            }
        }
    }

    /// Moves the current generation's chunk tasks into `detachedGenerations`
    /// so they keep running after playback state is torn down. Returns false
    /// when there is no incomplete cloud generation to hand over.
    private func detachActiveGenerationForBackgroundCompletion() -> Bool {
        guard mode.isCloudProvider,
              let context = syncedAudioContext,
              !audioChunks.isEmpty,
              completedSyncedChunks.count < audioChunks.count,
              !prefetchTasks.isEmpty else { return false }

        let hasScheduledRemainingChunks = audioChunks.count == 1
            || prefetchTasks.keys.contains { $0 > 0 }
            || completedSyncedChunks.contains { $0.index > 0 }
        // Only the lead chunk ever ran and it already failed permanently: the
        // generation is dead, so let the normal cancel path clean it up.
        guard hasScheduledRemainingChunks || failedGenerationChunkCount == 0 else { return false }

        // At most one background generation per source: an older record for
        // this source would race the new one on the same chunk files.
        cancelBackgroundGeneration(sourceID: context.sourceID, cleaningUpPartialAudio: false)

        // Completed chunks are already on disk (synced store + request cache);
        // dropping their task handles releases the audio Data they retain.
        var tasks = prefetchTasks
        for chunk in completedSyncedChunks {
            tasks[chunk.index] = nil
        }

        let generationID = audioGenerationID
        detachedGenerations[generationID] = DetachedAudioGeneration(
            context: context,
            chunkTexts: audioChunks,
            tasks: tasks,
            completedChunks: completedSyncedChunks,
            failedChunkCount: failedGenerationChunkCount,
            hasScheduledRemainingChunks: hasScheduledRemainingChunks
        )
        backgroundGenerationSourceIDs.insert(context.sourceID)
        backgroundGenerationProgress[context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: completedSyncedChunks.count,
            totalChunks: audioChunks.count
        )
        prefetchTasks = [:]
        if hasScheduledRemainingChunks {
            // A chunk whose prefetch task failed and was dropped during
            // playback would otherwise never be retried; give every missing
            // chunk a fresh task. Audio that already exists returns straight
            // from the per-request cache.
            fillMissingDetachedChunkTasks(generationID: generationID)
        }
        articleSpeechLogger.info(
            "Text-to-speech generation continues in background: \(self.completedSyncedChunks.count)/\(self.audioChunks.count) chunks done for \(context.sourceID)"
        )
        ArticleSpeechDiagnostics.append(
            "GENERATION_DETACHED source=\(context.sourceID) completed=\(completedSyncedChunks.count)/\(audioChunks.count)"
        )
        return true
    }

    /// True while chunk tasks for this generation should keep saving results:
    /// either it is the generation playback is consuming, or it was detached
    /// to finish in the background.
    func isGenerationActive(_ generationID: UUID) -> Bool {
        generationID == audioGenerationID || detachedGenerations[generationID] != nil
    }

    /// Ends any background generation for the source. Explicit stops and cache
    /// deletion clean up partial synced audio (matching `stop()`); a restart of
    /// the same source passes false so the new generation can reuse the chunks.
    func cancelBackgroundGeneration(sourceID: String, cleaningUpPartialAudio: Bool = true) {
        for (generationID, generation) in detachedGenerations
        where generation.context.sourceID == sourceID {
            cancelDetachedGeneration(
                generationID: generationID,
                cleaningUpPartialAudio: cleaningUpPartialAudio
            )
        }
    }

    func cancelDetachedGeneration(
        generationID: UUID,
        cleaningUpPartialAudio: Bool = true,
        outcome: ArticleSpeechBackgroundGenerationOutcome = .cancelled
    ) {
        guard let generation = detachedGenerations.removeValue(forKey: generationID) else { return }
        if !detachedGenerations.values.contains(where: { $0.context.sourceID == generation.context.sourceID }) {
            backgroundGenerationSourceIDs.remove(generation.context.sourceID)
        }
        generation.tasks.values.forEach { $0.cancel() }
        noteBackgroundGenerationEnded(sourceID: generation.context.sourceID, outcome: outcome)
        guard cleaningUpPartialAudio else { return }
        let sourceID = generation.context.sourceID
        Task.detached {
            if SyncedArticleAudioStore.loadCompleteManifest(sourceID: sourceID) == nil {
                ArticleSpeechAudioCache.deleteCachedAudio(sourceID: sourceID, forgettingReplicaNarration: false)
            }
        }
    }

    func playNextChunk() async {
        guard audioChunkIndex < totalChunkCount else {
            if let activeArticleID, syncedChunkURLs.isEmpty {
                Task.detached(priority: .utility) {
                    ArticleSpeechAudioCache.markCached(articleID: activeArticleID)
                }
                writeSyncedAudioManifestFromSavedChunks()
            }
            finishPlayback(completedSuccessfully: true)
            return
        }

        isLoading = true
        let epoch = playbackEpoch
        let currentChunkIndex = audioChunkIndex
        currentlyPlayingChunkIndex = currentChunkIndex

        if let preloaded = takePreloadedPlayer(for: currentChunkIndex) {
            audioChunkIndex = currentChunkIndex + 1
            do {
                try startPlayer(preloaded)
            } catch {
                pausePlayback(withError: error, retryingChunk: currentChunkIndex)
            }
            return
        }

        do {
            let data = try await segmentData(at: currentChunkIndex)
            guard !Task.isCancelled, epoch == playbackEpoch, activeArticleID != nil else {
                deferPublishedUpdate { [weak self] in
                    self?.isLoading = false
                }
                return
            }

            audioChunkIndex = currentChunkIndex + 1
            try playAudioData(data)
            // Consumed: from here on this chunk replays from disk if needed.
            prefetchTasks[currentChunkIndex] = nil
        } catch {
            guard !Task.isCancelled, epoch == playbackEpoch, activeArticleID != nil else {
                deferPublishedUpdate { [weak self] in
                    self?.isLoading = false
                }
                return
            }
            pausePlayback(withError: error, retryingChunk: currentChunkIndex)
        }
    }

    /// Data for the chunk at `index`, wherever it currently lives: the synced
    /// chunk file for cached replays, an in-flight prefetch task, the
    /// per-request disk cache, or a fresh generation.
    private func segmentData(at index: Int) async throws -> Data {
        if !syncedChunkURLs.isEmpty {
            guard index < syncedChunkURLs.count else {
                throw MacArticleTTSError.badResponse("Audio segment \(index + 1) is out of range.")
            }
            return try await Task.detached { [url = syncedChunkURLs[index]] in
                try Data(contentsOf: url)
            }.value
        }
        return try await audioData(forChunkAt: index)
    }

    func beginSyncedPlayback(manifest: SyncedArticleAudioManifest) {
        isLoading = true
        audioGenerationProgress = nil
        let epoch = playbackEpoch
        startPlaybackTask { [weak self] in
            let urls = Self.syncedChunkURLs(for: manifest)
            guard let self, !Task.isCancelled, epoch == self.playbackEpoch else { return }
            self.syncedChunkURLs = urls
            self.audioChunkIndex = 0

            if let resumeTime = self.pendingResumeGlobalTime,
               resumeTime >= Self.minimumResumeInterval {
                let resolution = await Task.detached(priority: .userInitiated) {
                    Self.resolveSyncedResume(
                        resumeTime: resumeTime,
                        chunkURLs: urls
                    )
                }.value
                guard !Task.isCancelled, epoch == self.playbackEpoch else { return }
                self.applySyncedResumeResolution(resolution)
                if resolution.shouldClearSavedPosition {
                    if let sourceID = self.activeArticleID {
                        Task.detached(priority: .utility) { [storage = self.activityStorage] in
                            await Self.clearListenPosition(sourceID: sourceID, storage: storage)
                        }
                    }
                    await self.playNextChunk()
                    self.loadAllChunkDurations()
                    return
                }
                if let chunkIndex = resolution.chunkIndex {
                    self.loadAllChunkDurations()
                    await self.jumpToChunk(chunkIndex, offset: resolution.offset)
                    return
                }
            }

            self.pendingResumeGlobalTime = nil
            await self.playNextChunk()
            self.loadAllChunkDurations()
        }
    }

    nonisolated static func syncedChunkURLs(for manifest: SyncedArticleAudioManifest) -> [URL] {
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: manifest.sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        return manifest.chunks
            .sorted { $0.index < $1.index }
            .map { directory.appendingPathComponent($0.fileName) }
    }

    nonisolated static func firstSyncedChunkIsAvailable(in manifest: SyncedArticleAudioManifest) -> Bool {
        guard !MacArticleSpeechSettings.isRetiredModel(manifest.model) else { return false }
        guard let first = syncedChunkURLs(for: manifest).first else { return false }
        return FileManager.default.fileExists(atPath: first.path)
    }

    private nonisolated static func resolveSyncedResume(
        resumeTime: TimeInterval,
        chunkURLs: [URL]
    ) -> SyncedResumeResolution {
        var loadedDurations: [Int: TimeInterval] = [:]
        var elapsed: TimeInterval = 0
        let target = max(0, resumeTime)

        for (index, url) in chunkURLs.enumerated() {
            if Task.isCancelled { break }
            guard let duration = audioDuration(at: url), duration > 0 else {
                return SyncedResumeResolution(
                    chunkIndex: nil,
                    offset: 0,
                    loadedDurations: loadedDurations,
                    totalDuration: nil,
                    shouldClearSavedPosition: false
                )
            }
            loadedDurations[index] = duration
            if target <= elapsed + duration || index == chunkURLs.count - 1 {
                let totalDuration = index == chunkURLs.count - 1 ? elapsed + duration : nil
                let shouldClear = totalDuration.map {
                    target >= $0 - completionResumeThreshold
                } ?? false
                return SyncedResumeResolution(
                    chunkIndex: shouldClear ? nil : index,
                    offset: min(max(target - elapsed, 0), duration),
                    loadedDurations: loadedDurations,
                    totalDuration: totalDuration,
                    shouldClearSavedPosition: shouldClear
                )
            }
            elapsed += duration
        }

        return SyncedResumeResolution(
            chunkIndex: nil,
            offset: 0,
            loadedDurations: loadedDurations,
            totalDuration: loadedDurations.count == chunkURLs.count ? elapsed : nil,
            shouldClearSavedPosition: false
        )
    }

    private nonisolated static func audioDuration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url),
              player.duration > 0 else {
            return nil
        }
        return player.duration
    }

    private func applySyncedResumeResolution(_ resolution: SyncedResumeResolution) {
        pendingResumeGlobalTime = nil
        for (index, duration) in resolution.loadedDurations {
            chunkDurations[index] = duration
        }
        if let totalDuration = resolution.totalDuration, totalDuration > 0 {
            playbackDuration = totalDuration
        } else {
            updatePlaybackDuration()
        }
    }

    private func playAudioData(_ data: Data, startingAt offset: TimeInterval = 0) throws {
        try startPlayer(AVAudioPlayer(data: data), startingAt: offset)
    }

    private func startPlayer(_ player: AVAudioPlayer, startingAt offset: TimeInterval = 0) throws {
        let wasPaused = isPaused
        player.delegate = self
        player.enableRate = true
        player.rate = Self.audioPlaybackRate(for: speed)
        player.prepareToPlay()
        recordChunkDuration(index: currentlyPlayingChunkIndex, duration: player.duration)
        if offset > 0 {
            player.currentTime = min(offset, player.duration)
        }
        audioPlayer = player
        hasStartedPlayback = true
        deferPublishedUpdate { [weak self] in
            self?.isLoading = false
        }
        startPlaybackTimeUpdatesIfNeeded()

        guard player.play() else {
            throw MacArticleTTSError.badResponse("Audio playback could not start.")
        }

        if wasPaused {
            player.pause()
        }
        playbackCurrentTime = currentGlobalPlaybackTime()
        updateNowPlayingInfo()
        preloadNextSegment()
    }

    private func takePreloadedPlayer(for index: Int) -> AVAudioPlayer? {
        guard let preloaded = preloadedNextPlayer, preloaded.index == index else { return nil }
        preloadedNextPlayer = nil
        return preloaded.player
    }

    /// Prepares the next chunk's player while the current chunk is still
    /// playing, so the handoff at the chunk boundary has no fetch/decode gap.
    /// Especially audible with Orpheus's ~180-character chunks, where a
    /// boundary lands every sentence or two.
    private func preloadNextSegment() {
        guard mode.isCloudProvider else { return }
        let nextIndex = audioChunkIndex
        guard nextIndex < totalChunkCount, preloadedNextPlayer?.index != nextIndex else { return }
        let epoch = playbackEpoch
        Task { [weak self] in
            guard let self else { return }
            guard let data = try? await self.segmentData(at: nextIndex) else { return }
            guard self.playbackEpoch == epoch,
                  self.activeArticleID != nil,
                  self.preloadedNextPlayer?.index != nextIndex,
                  let player = try? AVAudioPlayer(data: data) else { return }
            player.prepareToPlay()
            self.preloadedNextPlayer = (index: nextIndex, player: player)
        }
    }

    /// Surfaces a chunk failure without tearing the session down: playback
    /// pauses in place with position and chunk state intact, and resume (or
    /// the media-key play command) retries the failed chunk.
    private func pausePlayback(withError error: Error, retryingChunk index: Int) {
        articleSpeechLogger.error(
            "Playback paused on chunk \(index + 1): \(error.localizedDescription, privacy: .public)"
        )
        ArticleSpeechDiagnostics.append(
            "PLAYBACK_PAUSED chunk=\(index) \(error.localizedDescription)"
        )
        audioChunkIndex = index
        currentlyPlayingChunkIndex = index
        // A CancellationError here usually means abortAudioGeneration tore the
        // prefetch tasks down and already published the real provider error —
        // don't overwrite that message (or its provider-switch hint) with a
        // generic "operation cancelled".
        if !(error is CancellationError) || errorMessage == nil {
            errorMessage = error.localizedDescription
            errorSuggestsProviderSwitch = (error as? MacArticleTTSError)?.suggestsProviderSwitch == true
        }
        isPaused = true
        isLoading = false
        savePlaybackPositionNow()
        updateNowPlayingInfo()
    }

    func jumpToChunk(_ index: Int, offset: TimeInterval) async {
        let wasPaused = isPaused
        playbackEpoch += 1
        let epoch = playbackEpoch
        preloadedNextPlayer = nil
        audioPlayer?.stop()
        audioPlayer = nil

        currentlyPlayingChunkIndex = index
        audioChunkIndex = index
        isPaused = wasPaused

        do {
            let data = try await segmentData(at: index)
            guard epoch == playbackEpoch, activeArticleID != nil else { return }
            audioChunkIndex = index + 1
            try playAudioData(data, startingAt: offset)
        } catch is CancellationError {
            return
        } catch {
            guard epoch == playbackEpoch, activeArticleID != nil else { return }
            pausePlayback(withError: error, retryingChunk: index)
        }
    }
}
#endif
