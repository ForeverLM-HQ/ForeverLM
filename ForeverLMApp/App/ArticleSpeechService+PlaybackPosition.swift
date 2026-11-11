// Finishing playback and saving the listening position.
#if os(macOS)
import Foundation
import SwiftUI

extension ArticleSpeechService {
    func finishPlayback(completedSuccessfully: Bool = false) {
        let finishedSourceID = activeArticleID
        // Anything short of a clean finish keeps the resume point: a network
        // failure mid-book must not lose the listener's place.
        let positionSnapshot = completedSuccessfully ? nil : capturePlaybackPositionSnapshot()

        cancelSleepTimer()
        clearNowPlayingInfo()
        playbackEpoch += 1
        playbackTask = nil
        audioPlayer = nil
        preloadedNextPlayer = nil
        audioGenerationID = UUID()
        preparationRequestID = UUID()
        foregroundGenerationChunksRemaining = 0
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

        if completedSuccessfully, let finishedSourceID {
            let sourceID = finishedSourceID
            Task.detached(priority: .utility) { [activityStorage] in
                await Self.clearListenPosition(sourceID: sourceID, storage: activityStorage)
            }
            Task { [activityStorage] in
                do {
                    try await activityStorage.recordScheduledSourceCompletion(
                        sourceID: sourceID,
                        on: Date(),
                        kind: .listening
                    )
                    NotificationCenter.default.post(
                        name: .sourceListeningCompletionDidChange,
                        object: sourceID
                    )
                } catch {
                    articleSpeechLogger.error(
                        "Failed to log completed listening for \(sourceID, privacy: .public): \(error.localizedDescription)"
                    )
                }
            }
            finishedListeningArticleID = finishedSourceID
        } else if let finishedSourceID, let positionSnapshot {
            persistPlaybackPosition(positionSnapshot, sourceID: finishedSourceID)
        }
    }

    /// Consumes the finished-listening event so exactly one reader host
    /// auto-advances to the next chapter, even when several observe the service.
    func consumeFinishedListening(articleID: String) -> Bool {
        guard finishedListeningArticleID == articleID else { return false }
        finishedListeningArticleID = nil
        return true
    }

    @discardableResult
    func applyPendingResumeIfNeeded() async -> Bool {
        guard mode.isCloudProvider else { return false }
        guard let resumeTime = pendingResumeGlobalTime,
              resumeTime >= Self.minimumResumeInterval else {
            pendingResumeGlobalTime = nil
            return false
        }

        for _ in 0..<50 {
            if playbackDuration > 0 || !chunkDurations.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let duration = playbackDuration
        guard duration <= 0 || resumeTime < duration - Self.completionResumeThreshold else {
            pendingResumeGlobalTime = nil
            if let sourceID = activeArticleID {
                let sourceIDCopy = sourceID
                Task.detached(priority: .utility) { [activityStorage] in
                    await Self.clearListenPosition(sourceID: sourceIDCopy, storage: activityStorage)
                }
            }
            return false
        }

        pendingResumeGlobalTime = nil
        let clamped = duration > 0 ? min(resumeTime, max(0, duration - 1)) : resumeTime
        let target = location(forGlobalTime: clamped)
        let availableLimit = availableSeekChunkLimit()
        guard target.chunkIndex <= availableLimit else { return false }

        await jumpToChunk(target.chunkIndex, offset: target.offset)
        return true
    }

    private func shouldPersistPosition(time: TimeInterval, duration: TimeInterval) -> Bool {
        guard time >= Self.minimumResumeInterval else { return false }
        guard duration > 0 else { return true }
        return time < duration - Self.completionResumeThreshold
    }

    func capturePlaybackPositionSnapshot() -> ArticleSpeechPlaybackPosition? {
        guard activeArticleID != nil,
              isPlaying || isPaused,
              hasStartedPlayback || mode == .apple else {
            return nil
        }

        if mode == .apple {
            guard appleSpeechCharacterOffset > 0 else { return nil }
            return ArticleSpeechPlaybackPosition(
                globalTime: 0,
                appleCharacterOffset: appleSpeechCharacterOffset,
                contentSignature: activeNarrationSignature,
                updatedAt: Date()
            )
        }

        let time = currentGlobalPlaybackTime()
        guard shouldPersistPosition(time: time, duration: playbackDuration) else { return nil }
        return ArticleSpeechPlaybackPosition(
            globalTime: time,
            appleCharacterOffset: nil,
            contentSignature: activeNarrationSignature,
            updatedAt: Date()
        )
    }

    func schedulePlaybackPositionSave() {
        guard mode.isCloudProvider || mode == .apple else { return }
        guard activeArticleID != nil, hasStartedPlayback || mode == .apple else { return }
        if let last = lastPlaybackPositionSaveAt,
           Date().timeIntervalSince(last) < Self.playbackPositionSaveInterval {
            return
        }
        savePlaybackPositionNow()
    }

    func savePlaybackPositionNow() {
        guard let sourceID = activeArticleID,
              let snapshot = capturePlaybackPositionSnapshot() else { return }
        let now = Date()
        lastPlaybackPositionSaveAt = now
        // A pause is the moment the listener is most likely to reach for the
        // other device, so it publishes at once; steady playback republishes
        // on the account interval.
        let publishesToAccount = isPaused
            || lastAccountPositionSaveAt.map {
                now.timeIntervalSince($0) >= ListeningPositionSync.accountSaveInterval
            } ?? true
        persistPlaybackPosition(snapshot, sourceID: sourceID, toAccount: publishesToAccount)
        recordListeningDepth(sourceID: sourceID)
    }

    /// Promote resumable playback position into durable consumption evidence.
    ///
    /// Abandoning a podcast at 70% would leave nothing behind but a resume
    /// locator, and the memory companion could not tell it apart from an episode
    /// that was never opened. Depth rides the same throttle as the position
    /// save, and completion separately records 1.0.
    ///
    /// Deliberately skipped while the duration is still extrapolated from the
    /// chunks generated so far: depth merges with MAX and never decreases, so a
    /// single inflated sample against an underestimated duration would stick
    /// permanently. Apple's local voice reports no duration and so records
    /// nothing here — its progress is a character offset, not a time.
    private func recordListeningDepth(sourceID: String) {
        // Time listened accrues in slices between position saves while playing:
        // the ledger's engaged seconds for text-to-speech. A slice is capped at two
        // save intervals so a sleep or a stall cannot book hours.
        let now = Date()
        var listened = 0.0
        if isPlaying, !isPaused {
            if let last = lastListeningTickAt, lastListeningTickSourceID == sourceID {
                listened = min(max(0, now.timeIntervalSince(last)), 2 * Self.playbackPositionSaveInterval)
            }
            lastListeningTickAt = now
            lastListeningTickSourceID = sourceID
        } else {
            lastListeningTickAt = nil
            lastListeningTickSourceID = nil
        }
        // Depth is skipped while the duration is still an estimate; time is
        // honest either way.
        let fraction: Double? = isPlaybackDurationEstimated || playbackFraction <= 0 ? nil : playbackFraction
        guard fraction != nil || listened > 0 else { return }
        let title = nowPlayingTitle ?? ""
        Task { [activityStorage] in
            do {
                try await activityStorage.recordScheduledSourceActivity(
                    sourceID: sourceID,
                    on: now,
                    kind: .listening,
                    fraction: fraction,
                    engagedSeconds: listened
                )
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening depth for \(sourceID, privacy: .public): \(error.localizedDescription)"
                )
            }
            // The day's log, which History and the Activity pane draw as time: a
            // minute heard aloud is a minute on the clock, whether or not the
            // Reader is open on the source.
            guard listened > 0 else { return }
            do {
                try await activityStorage.recordDayActivity(kind: .listening, targetID: sourceID, title: title, at: now)
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening in the day's log for \(sourceID, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Saves the resume point beside the audio and, when `toAccount`, mirrors
    /// it to the account so another device resumes from it. Stop paths always
    /// mirror: they are the last word this device has on the position.
    func persistPlaybackPosition(
        _ position: ArticleSpeechPlaybackPosition,
        sourceID: String,
        toAccount: Bool = true
    ) {
        if toAccount {
            lastAccountPositionSaveAt = Date()
        }
        Task.detached(priority: .utility) { [activityStorage] in
            try? SyncedArticleAudioStore.savePlaybackPosition(position, sourceID: sourceID)
            if toAccount {
                await SyncedArticleAudioStore.publishPlaybackPositionToAccount(position, sourceID: sourceID)
                // The account copy is the source's ReadingState (`listen.position.*` stays on this Mac).
                do {
                    try await activityStorage.saveListenPosition(position, sourceID: sourceID)
                } catch {
                    articleSpeechLogger.error(
                        "Could not save the listen position for \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    /// The account copy of a source's resume point under generation 2 (its ReadingState), read before
    /// playback is prepared; nil under generation 1, whose account copy `loadPlaybackPosition` reads.
    func accountListenPosition(sourceID: String) async -> ArticleSpeechPlaybackPosition? {
        do {
            return try await activityStorage.loadListenPosition(sourceID: sourceID)
        } catch {
            articleSpeechLogger.error("Could not read the account resume point of \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Forgets a source's resume point everywhere: the file beside the audio, the account copy and,
    /// under generation 2, its ReadingState. The ReadingState goes first: when that write fails the
    /// local copy stays too, so the next play still finds the resume point at the end and forgets it
    /// again, rather than this Mac forgetting while every other device resumes from it.
    nonisolated static func clearListenPosition(sourceID: String, storage: StorageService) async {
        do {
            try await storage.saveListenPosition(nil, sourceID: sourceID)
        } catch {
            articleSpeechLogger.error("Could not forget the resume point of \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        SyncedArticleAudioStore.clearPlaybackPosition(sourceID: sourceID)
    }
}
#endif
