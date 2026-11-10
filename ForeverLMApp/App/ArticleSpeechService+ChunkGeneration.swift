// Chunk timing, prefetching and chunk generation tasks.
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
    var totalChunkCount: Int {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs.count
        }
        return audioChunks.count
    }

    func availableSeekChunkLimit() -> Int {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs.count - 1
        }
        let played = max(0, audioChunkIndex - 1)
        return max(highestReadyChunkIndex, played)
    }

    func chunkDuration(at index: Int) -> TimeInterval {
        if let duration = chunkDurations[index], duration > 0 {
            return duration
        }
        return estimatedChunkDuration
    }

    private var estimatedChunkDuration: TimeInterval {
        guard !chunkDurations.isEmpty else { return 0 }
        let total = chunkDurations.values.reduce(0, +)
        return total / Double(chunkDurations.count)
    }

    func location(forGlobalTime time: TimeInterval) -> (chunkIndex: Int, offset: TimeInterval) {
        let count = totalChunkCount
        guard count > 0 else { return (0, 0) }

        var remaining = min(max(time, 0), playbackDuration)
        for index in 0..<count {
            let duration = chunkDuration(at: index)
            if remaining <= duration || index == count - 1 {
                return (index, min(remaining, duration))
            }
            remaining -= duration
        }
        return (0, 0)
    }

    private func chunkStartTime(forChunk index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { partial, chunkIndex in
            partial + chunkDuration(at: chunkIndex)
        }
    }

    func currentGlobalPlaybackTime() -> TimeInterval {
        chunkStartTime(forChunk: currentlyPlayingChunkIndex) + (audioPlayer?.currentTime ?? 0)
    }

    func recordChunkDuration(index: Int, duration: TimeInterval) {
        guard duration > 0 else { return }
        chunkDurations[index] = duration
        updatePlaybackDuration()
    }

    func updatePlaybackDuration() {
        let count = totalChunkCount
        guard count > 0 else {
            playbackDuration = 0
            return
        }

        let knownTotal = chunkDurations.values.reduce(0, +)
        let knownCount = chunkDurations.count
        if knownCount == count {
            playbackDuration = knownTotal
        } else if knownCount > 0 {
            let average = knownTotal / Double(knownCount)
            playbackDuration = knownTotal + average * Double(count - knownCount)
        } else {
            playbackDuration = 0
        }
    }

    func startPlaybackTimeUpdatesIfNeeded() {
        playbackTimeUpdateTask?.cancel()
        playbackTimeUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.playbackCurrentTime = self?.currentGlobalPlaybackTime() ?? 0
                self?.updateNowPlayingInfo()
                self?.schedulePlaybackPositionSave()
            }
        }
    }

    func loadAllChunkDurations() {
        let urls = chunkFileURLs()
        guard !urls.isEmpty else { return }

        chunkDurationLoadTask?.cancel()
        chunkDurationLoadTask = Task.detached(priority: .utility) { [weak self, urls] in
            var durations: [Int: TimeInterval] = [:]
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { return }
                guard FileManager.default.fileExists(atPath: url.path),
                      let player = try? AVAudioPlayer(contentsOf: url),
                      player.duration > 0 else { continue }
                durations[index] = player.duration
            }
            let total = durations.values.reduce(0, +)
            await MainActor.run { [weak self, durations, total] in
                guard let self, !Task.isCancelled else { return }
                for (index, duration) in durations {
                    self.chunkDurations[index] = duration
                }
                if total > 0 {
                    self.playbackDuration = total
                } else {
                    self.updatePlaybackDuration()
                }
            }
        }
    }

    private func chunkFileURLs() -> [URL] {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs
        }
        guard let context = syncedAudioContext, totalChunkCount > 0 else { return [] }
        return (0..<totalChunkCount).map { index in
            SyncedArticleAudioStore.chunkURL(
                sourceID: context.sourceID,
                index: index,
                fileExtension: context.fileExtension
            )
        }
    }

    func resetPlaybackPosition() {
        playbackTimeUpdateTask?.cancel()
        playbackTimeUpdateTask = nil
        chunkDurationLoadTask?.cancel()
        chunkDurationLoadTask = nil
        chunkDurations = [:]
        currentlyPlayingChunkIndex = 0
        playbackCurrentTime = 0
        playbackDuration = 0
    }

    /// Returns true when `content` matches the narration that produced `manifest`.
    /// Blocking file I/O on the stored-text fallback — never call on the main actor.
    nonisolated static func cachedContentMatches(
        manifest: SyncedArticleAudioManifest,
        content: String,
        narrationSignature: String,
        isPaper: Bool
    ) -> Bool {
        var signatures: Set<String> = [narrationSignature]
        if !isPaper {
            signatures.insert(
                SyncedArticleAudioStore.contentSignature(
                    for: content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        if signatures.contains(manifest.contentSignature) {
            return true
        }

        if let storedText = try? SyncedArticleAudioStore.loadSourceText(for: manifest) {
            let storedNarration = isPaper
                ? MacArticleSpeechText.paperNarrationText(from: storedText)
                : MacArticleSpeechText.narrationText(from: storedText)
            if signatures.contains(SyncedArticleAudioStore.contentSignature(for: storedNarration)) {
                return true
            }
        }

        return false
    }

    func audioData(forChunkAt index: Int) async throws -> Data {
        if let task = prefetchTasks[index] {
            do {
                return try await task.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Drop the failed task so a later retry starts fresh instead of
                // re-awaiting the same stored failure.
                prefetchTasks[index] = nil
                articleSpeechLogger.warning(
                    "Prefetch task failed for chunk \(index + 1); retrying for playback: \(error.localizedDescription, privacy: .public)"
                )
                return try await generateAudioWithRetry(forChunkAt: index)
            }
        }

        return try await generateAudioWithRetry(forChunkAt: index)
    }

    func prefetchAllAudioChunks(generationID: UUID) {
        guard mode.isCloudProvider, !audioChunks.isEmpty else { return }
        completedSyncedChunks = []
        failedGenerationChunkCount = 0
        foregroundGenerationChunksRemaining = audioChunks.count

        // Give the opening request the provider to itself. Starting six requests
        // in the same turn let a whole chapter compete with the one short chunk
        // blocking the first audible word. Once the opening lands, its playback
        // duration is the buffer while the remainder generates concurrently.
        prefetchChunk(at: 0, permitPool: nil, generationID: generationID)
    }

    func prefetchRemainingAudioChunks(generationID: UUID) {
        guard generationID == audioGenerationID,
              mode.isCloudProvider,
              audioChunks.count > 1 else { return }
        let permitPool = ArticleSpeechAudioCachePermitPool(
            limit: Self.backgroundAudioCacheConcurrency(for: mode)
        )
        for index in 1..<audioChunks.count {
            prefetchChunk(at: index, permitPool: permitPool, generationID: generationID)
        }
    }

    private func prefetchChunk(
        at index: Int,
        permitPool: ArticleSpeechAudioCachePermitPool?,
        generationID: UUID
    ) {
        guard mode.isCloudProvider,
              index < audioChunks.count,
              prefetchTasks[index] == nil else { return }

        prefetchTasks[index] = makeChunkGenerationTask(
            text: audioChunks[index],
            index: index,
            provider: mode,
            model: activeSpeechModel,
            voice: activeSpeechVoice,
            syncedContext: syncedAudioContext,
            permitPool: permitPool,
            generationID: generationID
        )
    }

    /// Generates one chunk, saves it to the synced store, and reports the
    /// outcome back to whichever generation (active or detached) owns
    /// `generationID`. Shared by playback prefetch and background completion.
    func makeChunkGenerationTask(
        text: String,
        index: Int,
        provider: MacArticleSpeechMode,
        model: String,
        voice: String,
        syncedContext: SyncedArticleAudioContext?,
        permitPool: ArticleSpeechAudioCachePermitPool?,
        generationID: UUID
    ) -> Task<Data, Error> {
        // Detached: a plain Task would inherit this class's @MainActor isolation,
        // putting every saveChunk write (into the iCloud-synced Audio folder) on
        // the main thread — one blocking write per chunk beachballs playback.
        Task.detached { [weak self] in
            if let permitPool {
                await permitPool.acquire(order: index)
            }
            let releasePermit: () async -> Void = {
                if let permitPool {
                    await permitPool.release()
                }
            }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.waitWhileYieldingToForegroundGeneration(generationID: generationID)
                } catch {
                    await releasePermit()
                    throw CancellationError()
                }
                attempt += 1
                do {
                    let data = try await MacArticleTTSClient.speech(
                        provider: provider,
                        text: text,
                        speed: MacArticleSpeechSpeed.defaultSpeed,
                        model: model,
                        voice: voice,
                        task: "read_aloud",
                        source: syncedContext.map {
                            AIUsageSource(id: $0.sourceID, type: $0.sourceType, title: $0.title)
                        }
                    )
                    try Task.checkCancellation()
                    let generationStillActive = await MainActor.run { [weak self] in
                        self?.isGenerationActive(generationID) ?? false
                    }
                    guard generationStillActive else {
                        await releasePermit()
                        throw CancellationError()
                    }
                    if let syncedContext {
                        do {
                            _ = try SyncedArticleAudioStore.saveChunk(
                                data,
                                sourceID: syncedContext.sourceID,
                                index: index,
                                fileExtension: syncedContext.fileExtension
                            )
                        } catch {
                            // A sync failure must not interrupt listening: the audio
                            // still plays from memory and the per-request disk cache.
                            articleSpeechLogger.error(
                                "Could not sync chunk \(index + 1) to iCloud: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                    await releasePermit()
                    let succeededAttempt = attempt
                    let byteCount = data.count
                    await MainActor.run { [weak self] in
                        self?.recordAudioGenerationChunkSucceeded(
                            generationID: generationID,
                            chunkIndex: index,
                            attempt: succeededAttempt,
                            byteCount: byteCount
                        )
                    }
                    return data
                } catch is CancellationError {
                    await releasePermit()
                    throw CancellationError()
                } catch {
                    articleSpeechLogger.warning(
                        "Chunk \(index + 1) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    // A MacArticleTTSError means the TTS client already exhausted
                    // its own retries or hit a permanent failure (bad request,
                    // missing API key) — retrying from out here cannot succeed.
                    // One exception: a provider that returns HTTP 200 with no
                    // audio ("empty audio stream") does it for one part and not
                    // the next. Giving up on that part ended the whole narration
                    // as incomplete once the other parts landed, so it is asked
                    // again, a few times.
                    let isEmptyStream = error.localizedDescription.contains("empty audio stream")
                    let isPermanent = error is MacArticleTTSError && !(isEmptyStream && attempt < 4)
                    guard !isPermanent, attempt < Self.maxChunkGenerationAttempts else {
                        articleSpeechLogger.error(
                            "Chunk \(index + 1) failed permanently after \(attempt) attempt(s)"
                        )
                        ArticleSpeechDiagnostics.append(
                            "CHUNK_FAILED index=\(index) attempts=\(attempt) \(error.localizedDescription)"
                        )
                        await releasePermit()
                        if let ttsError = error as? MacArticleTTSError, ttsError.abortsGeneration {
                            await MainActor.run { [weak self] in
                                self?.abortAudioGeneration(generationID: generationID, with: ttsError)
                            }
                        } else {
                            await MainActor.run { [weak self] in
                                self?.recordAudioGenerationChunkFailed(
                                    generationID: generationID,
                                    chunkIndex: index
                                )
                            }
                        }
                        throw error
                    }
                    try await Task.sleep(nanoseconds: Self.chunkRetryDelayNanoseconds(attempt: attempt))
                }
            }
            await releasePermit()
            throw CancellationError()
        }
    }

    /// Parks a detached generation's chunk task while the generation the
    /// listener is actually playing still has chunks to produce. Every
    /// generation runs its own permit pool, so chapters left generating in the
    /// background otherwise compete with the foreground chapter for provider
    /// throughput and rate limits — which is what made a freshly started
    /// chapter buffer for half a minute right after its 2-second lead chunk.
    /// Polled rather than gated: the wait self-corrects within one interval no
    /// matter how playback state changed while the task slept, and Task.sleep
    /// honors cancellation.
    nonisolated func waitWhileYieldingToForegroundGeneration(generationID: UUID) async throws {
        while true {
            let shouldYield = await MainActor.run {
                self.foregroundGenerationChunksRemaining > 0
                    && generationID != self.audioGenerationID
            }
            guard shouldYield else { return }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private func generateAudioWithRetry(forChunkAt index: Int) async throws -> Data {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                return try await MacArticleTTSClient.speech(
                    provider: mode,
                    text: audioChunks[index],
                    speed: MacArticleSpeechSpeed.defaultSpeed,
                    model: activeSpeechModel,
                    voice: activeSpeechVoice,
                    task: "read_aloud",
                    source: syncedAudioContext.map {
                        AIUsageSource(id: $0.sourceID, type: $0.sourceType, title: $0.title)
                    }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                articleSpeechLogger.warning(
                    "Playback chunk \(index + 1) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                )
                let isPermanent = error is MacArticleTTSError
                guard !isPermanent, attempt < Self.maxChunkGenerationAttempts else {
                    articleSpeechLogger.error(
                        "Playback chunk \(index + 1) failed permanently after \(attempt) attempt(s)"
                    )
                    ArticleSpeechDiagnostics.append(
                        "PLAYBACK_CHUNK_FAILED index=\(index) attempts=\(attempt) \(error.localizedDescription)"
                    )
                    if let ttsError = error as? MacArticleTTSError, ttsError.abortsGeneration {
                        abortAudioGeneration(generationID: audioGenerationID, with: ttsError)
                    }
                    throw error
                }
                try await Task.sleep(nanoseconds: Self.chunkRetryDelayNanoseconds(attempt: attempt))
            }
        }
        throw CancellationError()
    }
}
#endif
