import Foundation
import Testing
@testable import ForeverLM

/// The sync status the Mac shows while a round runs, and the watched marks a stale write must not undo.
@Suite("Sync status and watched marks")
@MainActor
struct SyncStatusCenterTests {
    @Test("Sync progress is monotonic across CloudKit windows and appended work")
    func syncProgressIsMonotonicAcrossWindows() {
        let status = CloudKitSyncStatusCenter()

        status.beginSending(remaining: 100)
        #expect(status.phase == .sending(remaining: 100, total: 100))
        #expect(status.fractionComplete == 0)

        status.advanceSending(remaining: 60, sentInBatch: 40)
        #expect(status.phase == .sending(remaining: 60, total: 100))
        #expect(status.fractionComplete == 0.4)

        // CloudKit can close several healthy windows without changing the
        // durable count. They are seams in one drain, not evidence of a stall.
        for _ in 0..<5 {
            status.finishSending(remaining: 60)
            status.beginSending(remaining: 60)
        }
        #expect(status.phase == .sending(remaining: 60, total: 100))
        #expect(status.fractionComplete == 0.4)

        // New local writes may join while the drain is active. The honest total
        // grows, but recorded progress never runs backward.
        status.beginSending(remaining: 80)
        #expect(status.phase == .sending(remaining: 80, total: 120))
        #expect(status.fractionComplete == 0.4)

        status.advanceSending(remaining: 20, sentInBatch: 60)
        #expect(status.phase == .sending(remaining: 20, total: 120))
        #expect(status.fractionComplete.map { $0 > 0.83 } == true)

        // A no-progress pass enters retry backoff. The next attempt resumes the
        // same drain instead of resetting its progress.
        status.waitToRetry(remaining: 20, stalled: true)
        #expect(status.phase == .waitingToRetry(remaining: 20, total: 120))
        status.beginSending(remaining: 20)
        #expect(status.phase == .sending(remaining: 20, total: 120))
        #expect(status.fractionComplete.map { $0 > 0.83 } == true)
    }

    @Test("A paced drain reports uploading, and only a refused one reports retrying")
    func syncPacedBackoffIsNotReportedAsAStall() {
        let status = CloudKitSyncStatusCenter()

        status.beginSending(remaining: 2_000)
        status.advanceSending(remaining: 1_900, sentInBatch: 100)

        // One window that lands nothing is a seam in a throttled backfill. The
        // whole-library re-upload spent most of its life here and the readout
        // called all 2,899 changes failed.
        status.waitToRetry(remaining: 1_900, stalled: false)
        #expect(status.phase == .backingOff(remaining: 1_900, total: 2_000))
        #expect(status.remainingCount == 1_900)

        // The drain resumes without losing recorded progress.
        status.beginSending(remaining: 1_900)
        #expect(status.phase == .sending(remaining: 1_900, total: 2_000))

        status.waitToRetry(remaining: 1_900, stalled: true)
        #expect(status.phase == .waitingToRetry(remaining: 1_900, total: 2_000))
    }

    @Test("Send completion coalesces its paired fetch and immediate follow-up batch")
    func syncProgressCoalescesFetchSeams() {
        let status = CloudKitSyncStatusCenter()

        status.beginSending(remaining: 20)
        status.advanceSending(remaining: 0, sentInBatch: 20)
        status.finishSending(remaining: 0)
        let completedFraction = status.fractionComplete
        #expect(status.phase == .sending(remaining: 0, total: 20))

        status.beginReceiving()
        status.finishReceiving()
        #expect(status.phase == .sending(remaining: 0, total: 20))

        status.beginSending(remaining: 8)
        #expect(status.phase == .sending(remaining: 8, total: 28))
        #expect(status.fractionComplete == completedFraction)

        let noOpStatus = CloudKitSyncStatusCenter()
        noOpStatus.finishSending(remaining: 0)
        #expect(noOpStatus.phase == .idle)
    }

    @Test("A quiescent send finishes once after the settle window")
    func syncProgressFinishesAfterSettling() async throws {
        let status = CloudKitSyncStatusCenter(
            completionSettleDelay: .milliseconds(10)
        )

        status.beginSending(remaining: 1)
        status.advanceSending(remaining: 0, sentInBatch: 1)
        status.finishSending(remaining: 0)
        try await Task.sleep(for: .milliseconds(50))

        #expect(status.phase == .idle)
        #expect(status.lastCompleted != nil)
    }

    private func makeWatchedVideo(_ slug: String, readAt: Date? = nil) -> StudioArticle {
        var video = StudioArticle(url: "https://youtube.com/watch?v=\(slug)", title: "Lecture")
        video.normalizedURL = URLNormalizer.normalize(video.url)
        video.sourceType = .video
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 3500,
            watchedSeconds: 3550,
            durationSeconds: 3600
        ).encoded
        video.readAt = readAt
        return video
    }

    @Test("A reader's write from before a Mark as Not Watched cannot undo it")
    func staleReaderWriteCannotUndoNotWatched() throws {
        let store = try KnowledgeStore(inMemory: true)
        let video = makeWatchedVideo("unwatch-stale-write")
        try store.saveSource(video)
        let watched = try #require(VideoWatchProgress(encoded: video.readingPositionLocator))
        let mark = try store.setVideoWatched(sourceID: video.id, watched: false)

        try store.updateSourceReadingLocator(
            sourceID: video.id,
            locator: watched.advanced(to: 3590, durationSeconds: nil).encoded
        )
        #expect(try store.loadSourceReadingLocator(sourceID: video.id) == mark.locator)

        // Watching after the mark is kept, and a lower watched mark never
        // replaces a higher one; the latest write owns the position.
        let marker = try #require(VideoWatchProgress(encoded: mark.locator))
        try store.updateSourceReadingLocator(
            sourceID: video.id,
            locator: marker.advanced(to: 600, durationSeconds: nil).encoded
        )
        try store.updateSourceReadingLocator(
            sourceID: video.id,
            locator: marker.advanced(to: 300, durationSeconds: nil).encoded
        )
        let stored = try #require(VideoWatchProgress(encoded: try store.loadSourceReadingLocator(sourceID: video.id)))
        #expect(stored.positionSeconds == 300)
        #expect(stored.watchedSeconds == 600)
        #expect(stored.unwatchedAt == marker.unwatchedAt)
    }

    @Test("A full save of a copy taken before Mark as Not Watched keeps the mark")
    func staleFullSaveCannotUndoNotWatched() throws {
        let store = try KnowledgeStore(inMemory: true)
        let before = makeWatchedVideo("unwatch-full-save", readAt: Date(timeIntervalSinceNow: -86_400))
        try store.saveSource(before)
        let mark = try store.setVideoWatched(sourceID: before.id, watched: false)

        // A transcript or metadata save that read the source list before the
        // mark writes its whole copy after it.
        try store.saveSource(before)

        let reloaded = try #require(try store.loadSourceForSync(before.id))
        #expect(reloaded.readingPositionLocator == mark.locator)
        #expect(reloaded.readAt == nil)

        // Watching after the mark is saved like any position.
        var rewatched = reloaded
        rewatched.readingPositionLocator = VideoWatchProgress(encoded: mark.locator)?
            .advanced(to: 240, durationSeconds: nil)
            .encoded
        try store.saveSource(rewatched)
        #expect(try store.loadSourceReadingLocator(sourceID: before.id) == rewatched.readingPositionLocator)
    }
}
