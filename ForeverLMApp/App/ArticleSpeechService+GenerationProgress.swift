// Recording the progress of foreground and detached audio generation.
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
    /// Re-reads the stored configuration at the start of a listening session,
    /// so a provider or voice changed in Settings takes effect on the next
    /// Listen. This one is synchronous on purpose: it runs from a click rather
    /// than from launch, the vault is cached in memory by then, and narrating
    /// with a stale provider would be worse than the read. It supersedes any
    /// launch-time read still in flight.
    func refreshConfiguration() {
        configurationEpoch += 1
        apply(.loadStored())
        appleVoiceIdentifier = MacArticleSpeechSettings.appleVoiceIdentifier
        speed = MacArticleSpeechSpeed.stored
    }

    func recordAudioGenerationChunkSucceeded(
        generationID: UUID,
        chunkIndex: Int,
        attempt: Int,
        byteCount: Int
    ) {
        guard generationID == audioGenerationID else {
            recordDetachedGenerationChunkSucceeded(
                generationID: generationID,
                chunkIndex: chunkIndex,
                byteCount: byteCount
            )
            return
        }
        guard !completedSyncedChunks.contains(where: { $0.index == chunkIndex }) else { return }

        foregroundGenerationChunksRemaining = max(0, foregroundGenerationChunksRemaining - 1)
        highestReadyChunkIndex = max(highestReadyChunkIndex, chunkIndex)

        if chunkIndex == 0 {
            prefetchRemainingAudioChunks(generationID: generationID)
        }

        if let context = syncedAudioContext {
            completedSyncedChunks.append(SyncedArticleAudioManifest.Chunk(
                index: chunkIndex,
                fileName: SyncedArticleAudioStore.chunkFileName(
                    index: chunkIndex,
                    fileExtension: context.fileExtension
                ),
                byteCount: byteCount,
                text: chunkIndex < audioChunks.count ? audioChunks[chunkIndex] : nil
            ))
            if completedSyncedChunks.count == audioChunks.count {
                writeSyncedAudioManifest(chunks: completedSyncedChunks)
                let sourceID = context.sourceID
                Task.detached(priority: .utility) {
                    ArticleSpeechAudioCache.markCached(articleID: sourceID)
                }
            }
        }

        // The chunk now lives in the synced store and the per-request disk cache,
        // so the in-memory prefetch result can be released — holding every task's
        // Data kept a whole chapter of audio (WAV for Orpheus) resident in RAM.
        // Keep only the chunk playback is about to consume and the preload target.
        if chunkIndex < audioChunkIndex || chunkIndex > audioChunkIndex + 1 {
            prefetchTasks[chunkIndex] = nil
        }

        if var progress = audioGenerationProgress,
           progress.completedChunks < progress.totalChunks {
            progress.completedChunks += 1
            deferPublishedUpdate { [weak self] in
                guard var current = self?.audioGenerationProgress,
                      current.completedChunks < current.totalChunks else { return }
                current.completedChunks = progress.completedChunks
                self?.audioGenerationProgress = current
            }
            if attempt > 1 {
                articleSpeechLogger.info(
                    "Chunk \(chunkIndex + 1)/\(progress.totalChunks) ready after \(attempt) attempts"
                )
            } else {
                articleSpeechLogger.debug(
                    "Chunk \(chunkIndex + 1)/\(progress.totalChunks) ready"
                )
            }
            if progress.isComplete {
                articleSpeechLogger.info(
                    "Text-to-speech generation finished: \(progress.totalChunks) chunks"
                )
                loadAllChunkDurations()
            }
        }
    }

    /// Bookkeeping for a chunk that finished after its generation was detached.
    /// Mirrors the active-generation path minus playback and progress UI, and
    /// writes the synced manifest once the last chunk lands.
    private func recordDetachedGenerationChunkSucceeded(
        generationID: UUID,
        chunkIndex: Int,
        byteCount: Int
    ) {
        guard var generation = detachedGenerations[generationID] else { return }
        // The chunk is on disk; releasing the task handle frees its audio Data.
        generation.tasks[chunkIndex] = nil
        if !generation.completedChunks.contains(where: { $0.index == chunkIndex }) {
            generation.completedChunks.append(SyncedArticleAudioManifest.Chunk(
                index: chunkIndex,
                fileName: SyncedArticleAudioStore.chunkFileName(
                    index: chunkIndex,
                    fileExtension: generation.context.fileExtension
                ),
                byteCount: byteCount,
                text: chunkIndex < generation.chunkTexts.count ? generation.chunkTexts[chunkIndex] : nil
            ))
        }
        detachedGenerations[generationID] = generation
        backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: generation.completedChunks.count,
            totalChunks: generation.chunkTexts.count,
            failedChunks: generation.failedChunkCount
        )

        if !generation.hasScheduledRemainingChunks {
            scheduleRemainingDetachedChunks(generationID: generationID)
        }

        if generation.completedChunks.count == generation.chunkTexts.count {
            finishDetachedGeneration(generationID: generationID)
        } else if Self.isEveryChunkAccountedFor(generation) {
            endIncompleteDetachedGeneration(generationID: generationID)
        }
    }

    /// Schedules the chunks a detached generation never started because the
    /// listener switched away while the lead chunk was still in flight.
    private func scheduleRemainingDetachedChunks(generationID: UUID) {
        guard var generation = detachedGenerations[generationID],
              !generation.hasScheduledRemainingChunks else { return }
        generation.hasScheduledRemainingChunks = true
        detachedGenerations[generationID] = generation
        fillMissingDetachedChunkTasks(generationID: generationID)
    }

    /// Creates a chunk task for every index that has neither a running task
    /// nor a completed chunk on disk.
    func fillMissingDetachedChunkTasks(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }

        let permitPool = ArticleSpeechAudioCachePermitPool(
            limit: Self.backgroundAudioCacheConcurrency(for: generation.context.provider)
        )
        for index in 0..<generation.chunkTexts.count
        where generation.tasks[index] == nil
            && !generation.completedChunks.contains(where: { $0.index == index }) {
            generation.tasks[index] = makeChunkGenerationTask(
                text: generation.chunkTexts[index],
                index: index,
                provider: generation.context.provider,
                model: generation.context.model,
                voice: generation.context.voice,
                syncedContext: generation.context,
                permitPool: permitPool,
                generationID: generationID
            )
        }
        detachedGenerations[generationID] = generation
    }

    private func finishDetachedGeneration(generationID: UUID) {
        guard let generation = detachedGenerations.removeValue(forKey: generationID) else { return }
        let context = generation.context
        if !detachedGenerations.values.contains(where: { $0.context.sourceID == context.sourceID }) {
            backgroundGenerationSourceIDs.remove(context.sourceID)
        }
        let chunks = generation.completedChunks
        articleSpeechLogger.info(
            "Background text-to-speech generation finished: \(chunks.count) chunks for \(context.sourceID)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_FINISHED source=\(context.sourceID) chunks=\(chunks.count)"
        )
        Task.detached(priority: .utility) { [weak self] in
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in
                    self?.errorMessage = failure
                    self?.noteBackgroundGenerationEnded(sourceID: context.sourceID, outcome: .failed(failure))
                }
            } else {
                ArticleSpeechAudioCache.markCached(articleID: context.sourceID)
                await MainActor.run { [weak self] in
                    self?.noteBackgroundGenerationEnded(sourceID: context.sourceID, outcome: .ready)
                }
            }
        }
    }

    func recordAudioGenerationChunkFailed(generationID: UUID, chunkIndex: Int) {
        guard generationID == audioGenerationID else {
            recordDetachedGenerationChunkFailed(generationID: generationID)
            return
        }
        failedGenerationChunkCount += 1
        foregroundGenerationChunksRemaining = max(0, foregroundGenerationChunksRemaining - 1)
        if chunkIndex == 0 {
            // The opening owns the first-audio gate, so no continuation chunks
            // were scheduled. End generation UI now; playback surfaces the
            // actual error instead of leaving a zero-percent spinner behind.
            deferPublishedUpdate { [weak self] in
                self?.audioGenerationProgress = nil
            }
            return
        }
        // Progress can never reach 100% once a chunk failed permanently. Drop the
        // generation UI instead of spinning forever — the failure itself surfaces
        // (and pauses playback in place) when the listener reaches that chunk.
        if let progress = audioGenerationProgress,
           progress.completedChunks + failedGenerationChunkCount >= progress.totalChunks {
            deferPublishedUpdate { [weak self] in
                self?.audioGenerationProgress = nil
            }
        }
    }

    private func recordDetachedGenerationChunkFailed(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }
        generation.failedChunkCount += 1
        detachedGenerations[generationID] = generation
        backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: generation.completedChunks.count,
            totalChunks: generation.chunkTexts.count,
            failedChunks: generation.failedChunkCount
        )
        // The manifest can never be written once a chunk failed permanently.
        // Let the other in-flight chunks land in the request cache, but once
        // every chunk is accounted for — or the lead chunk failed before the
        // rest were even scheduled — drop the record. Completed chunks stay
        // cached, so a later Listen only regenerates the failed ones.
        let isUnschedulable = !generation.hasScheduledRemainingChunks
        if isUnschedulable || Self.isEveryChunkAccountedFor(generation) {
            endIncompleteDetachedGeneration(generationID: generationID)
        }
    }

    private static func isEveryChunkAccountedFor(_ generation: DetachedAudioGeneration) -> Bool {
        generation.completedChunks.count + generation.failedChunkCount >= generation.chunkTexts.count
    }

    /// Ends a background run that has failed parts and nothing left in
    /// flight. Either the last failure or the last success can be the one
    /// that settles it: a run whose final part landed after its failures used
    /// to wait for ever at 98%, since only a failure asked.
    private func endIncompleteDetachedGeneration(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }
        // Before giving up, ask for the failed parts once more: the rest are
        // cached, so only they are made (and billed), and a provider that
        // answered one part empty usually answers it the second time.
        if !generation.hasRetriedFailedChunks, generation.hasScheduledRemainingChunks,
           generation.failedChunkCount > 0 {
            generation.hasRetriedFailedChunks = true
            generation.failedChunkCount = 0
            backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
                completedChunks: generation.completedChunks.count,
                totalChunks: generation.chunkTexts.count
            )
            let landed = Set(generation.completedChunks.map(\.index))
            for index in Array(generation.tasks.keys) where !landed.contains(index) {
                generation.tasks[index] = nil
            }
            detachedGenerations[generationID] = generation
            ArticleSpeechDiagnostics.append(
                "BACKGROUND_GENERATION_RETRYING_FAILED source=\(generation.context.sourceID) missing=\(generation.chunkTexts.count - landed.count)"
            )
            narrationStages[generation.context.sourceID] = "Retrying the parts that failed"
            fillMissingDetachedChunkTasks(generationID: generationID)
            return
        }
        articleSpeechLogger.error(
            "Background text-to-speech generation for \(generation.context.sourceID) ended with \(generation.failedChunkCount) failed chunk(s)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_INCOMPLETE source=\(generation.context.sourceID) failed=\(generation.failedChunkCount)"
        )
        let message = "Audio generation for \(generation.context.title) could not finish."
        errorMessage = message
        // The parts that landed stay: the next Listen or Generate Audio asks
        // for only the ones that are missing.
        cancelDetachedGeneration(
            generationID: generationID,
            cleaningUpPartialAudio: false,
            outcome: .failed(message)
        )
    }

    /// Stops the whole generation after a provider rejection (bad key, dead
    /// credits, billing failure): every remaining chunk request would fail the
    /// same way, so cancelling them avoids hammering the provider with
    /// per-chunk retries. Audio that already arrived keeps playing; the error
    /// surfaces immediately in the player UI.
    func abortAudioGeneration(generationID: UUID, with error: Error) {
        guard generationID == audioGenerationID else {
            if detachedGenerations[generationID] != nil {
                articleSpeechLogger.error(
                    "Background text-to-speech generation aborted: \(error.localizedDescription, privacy: .public)"
                )
                ArticleSpeechDiagnostics.append(
                    "BACKGROUND_GENERATION_ABORTED \(error.localizedDescription)"
                )
                cancelDetachedGeneration(
                    generationID: generationID,
                    outcome: .failed(error.localizedDescription)
                )
            }
            return
        }
        let message = error.localizedDescription
        articleSpeechLogger.error(
            "Text-to-speech generation aborted: \(message, privacy: .public)"
        )
        ArticleSpeechDiagnostics.append("GENERATION_ABORTED \(message)")
        audioGenerationID = UUID()
        foregroundGenerationChunksRemaining = 0
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        deferPublishedUpdate { [weak self] in
            guard let self else { return }
            self.audioGenerationProgress = nil
            self.errorMessage = message
            // Every caller aborts with a `MacArticleTTSError`; the default only
            // covers a future one that does not.
            self.errorSuggestsProviderSwitch =
                (error as? MacArticleTTSError)?.suggestsProviderSwitch ?? true
            if !self.hasStartedPlayback {
                // Nothing is playing and nothing further will arrive — stop
                // the "waiting for first chunk" spinner in place.
                self.isLoading = false
                self.isPaused = true
                self.savePlaybackPositionNow()
                self.updateNowPlayingInfo()
            }
        }
    }
}
#endif
