import Foundation
import CloudKit
import CoreGraphics
import SQLite3
import Testing
@testable import ForeverLM

private func makeCloudKitArticle(url: String, title: String) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

private func installCloudKitPaperText(on paper: inout StudioArticle) {
    let text = "Durable canonical paper text."
    let hash = PaperContentPreparationService.sha256(text)
    paper.installPreparedPaperContent(
        raw: text,
        clean: text,
        metadata: PaperContentPreparationMetadata(
            cleanerVersion: PaperContentPreparationMetadata.currentVersion,
            rawSHA256: hash,
            cleanSHA256: hash,
            preparedAt: Date()
        )
    )
}

private func writeCloudKitTestPDF(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(mediaBox)
    context.endPDFPage()
    context.closePDF()
}

private func execSQLite(_ db: OpaquePointer?, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &error)
    if rc != SQLITE_OK {
        let message = error.map { String(cString: $0) } ?? "SQLite error \(rc)"
        sqlite3_free(error)
        throw NSError(domain: "CloudKitMigrationTests", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class CloudKitConflictNotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedLogicalKeys = Set<String>()

    func record(_ notification: Notification) {
        guard let logicalKey = notification.userInfo?[
            CloudKitSyncNotificationInfo.conflictLogicalKey
        ] as? String else { return }
        _ = lock.withLock {
            observedLogicalKeys.insert(logicalKey)
        }
    }

    func observed(_ logicalKey: String) -> Bool {
        lock.withLock { observedLogicalKeys.contains(logicalKey) }
    }
}

private final class CrossSurfaceCloudKitFixtureBundleToken {}

@Suite("CloudKit Migration")
struct CloudKitMigrationTests {
    @Test("CloudKit delivery echoes require the same record identity and etag")
    func cloudKitDeliveryEchoIdentityIsExact() {
        let sourceID = CloudKitRecordMapper.recordID(
            for: .source,
            logicalKey: "echo-source"
        )
        let otherSourceID = CloudKitRecordMapper.recordID(
            for: .source,
            logicalKey: "other-source"
        )

        #expect(CloudKitSyncEngine.serverVersionsMatch(
            incomingRecordID: sourceID,
            incomingChangeTag: "etag-42",
            acknowledgedRecordID: sourceID,
            acknowledgedChangeTag: "etag-42"
        ))
        #expect(!CloudKitSyncEngine.serverVersionsMatch(
            incomingRecordID: sourceID,
            incomingChangeTag: "etag-43",
            acknowledgedRecordID: sourceID,
            acknowledgedChangeTag: "etag-42"
        ))
        #expect(!CloudKitSyncEngine.serverVersionsMatch(
            incomingRecordID: sourceID,
            incomingChangeTag: "etag-42",
            acknowledgedRecordID: otherSourceID,
            acknowledgedChangeTag: "etag-42"
        ))
    }

    @Test("CloudKit automatic sending stays disabled behind the retry coordinator")
    func cloudKitAutomaticSendingStaysDisabled() {
        #expect(!CloudKitSyncSendPolicy.allowsEngineAutomaticSync)
    }

    @Test("CloudKit batch failures isolate one record before bounded retry")
    func cloudKitBatchFailuresAreIsolated() {
        #expect(CloudKitSyncBatchIsolationPolicy.batchLimit(
            defaultLimit: 100,
            isIsolating: false
        ) == 100)
        #expect(CloudKitSyncBatchIsolationPolicy.batchLimit(
            defaultLimit: 100,
            isIsolating: true
        ) == 1)
        #expect(!CloudKitSyncBatchIsolationPolicy.isSingletonFailure(
            failedChangeCount: 2
        ))
        #expect(CloudKitSyncBatchIsolationPolicy.isSingletonFailure(
            failedChangeCount: 1
        ))
        #expect(CloudKitSyncBatchIsolationPolicy.requiresImmediateIsolationPass(
            failedChangeCount: 2
        ))
        #expect(!CloudKitSyncBatchIsolationPolicy.requiresImmediateIsolationPass(
            failedChangeCount: 1
        ))
    }

    @Test("An accepted delete dequeues even when its metadata is gone")
    func acceptedDeleteClearsQueueWithoutMetadata() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let source = makeCloudKitArticle(
            url: "https://example.com/retired",
            title: "Retired source"
        )
        try store.saveSource(source)
        let recordName = try #require(
            store.pendingSyncChanges().first { $0.entity == .source }?.recordName
        )

        // Clearing the metadata leaves the queued change behind, which is the
        // state a stalled library is actually in: queued deletes whose
        // sync_metadata row is gone.
        try store.clearSyncMetadata(entity: .source, logicalKey: source.id)
        #expect(try store.loadSyncMetadata(recordName: recordName) == nil)
        #expect(try store.pendingSyncChanges().contains { $0.recordName == recordName })

        // CloudKit reports an accepted delete by CKRecordID alone. Clearing by
        // record name is the only thing that can dequeue it; without this the
        // row is re-sent forever and blocks every save behind it.
        try store.clearPendingSyncChange(recordName: recordName)
        #expect(try !store.pendingSyncChanges().contains { $0.recordName == recordName })
    }

    @Test("Pending sync status names user-visible records")
    func pendingSyncStatusNamesRecords() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let source = makeCloudKitArticle(
            url: "https://example.com/mitochondria",
            title: "Mitochondrial therapeutics"
        )
        try store.saveSource(source)
        try store.saveArtifactRecord(ArtifactRecord(
            id: "sync-note",
            title: "Treatment landscape notes",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: Date(),
            updatedAt: Date()
        ))

        let items = try store.pendingSyncItemSummaries()
        #expect(items.contains {
            $0.title == "Mitochondrial therapeutics" && $0.kind == "Source"
        })
        // Artifacts are surfaced as "Article" since the collaborative editor
        // landed; this row is the same record the old "Note" label named.
        #expect(items.contains {
            $0.title == "Treatment landscape notes" && $0.kind == "Article"
        })
    }

    @Test("Pending sync status includes the oldest and newest work")
    func pendingSyncStatusIncludesQueueEnds() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        for index in 0..<25 {
            let article = makeCloudKitArticle(
                url: "https://example.com/queue-\(index)",
                title: "Queue item \(index)"
            )
            try store.saveSource(article)
            try store.markRecordChanged(
                entity: .source,
                logicalKey: article.id,
                at: Date(timeIntervalSinceReferenceDate: TimeInterval(index + 1))
            )
        }

        let items = try store.pendingSyncItemSummaries(limit: 20)

        #expect(items.count == 20)
        #expect(items.first?.title == "Queue item 0")
        #expect(items.first?.changedAt == Date(timeIntervalSinceReferenceDate: 1))
        #expect(items.contains { $0.title == "Queue item 24" })
        #expect(!items.contains { $0.title == "Queue item 12" })
    }

    @Test("CloudKit retry policy backs off and respects the server minimum")
    func cloudKitRetryPolicyRespectsServerDelay() {
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 1) == 60)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 2) == 120)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 20) == 1_800)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 2,
            serverRetryAfter: 600
        ) == 600)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 1,
            serverRetryAfter: .infinity
        ) == 60)

        let serverError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: NSNumber(value: 275)]
        )
        #expect(CloudKitSyncRetryPolicy.serverRetryAfterSeconds(from: serverError) == 275)
    }

    @Test("A throttled send waits the server's delay, not the exponential cap")
    func cloudKitRetryPolicyHonoursShortServerDelay() {
        // The bulk backfill case: CloudKit hands back 429s with a two-second
        // retry while the failure count is already deep into the curve. Taking
        // the larger of the two parked a cleared retry behind 30 minutes.
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 8,
            serverRetryAfter: 2
        ) == CloudKitSyncRetryPolicy.minimumThrottleDelay)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 8,
            serverRetryAfter: 19
        ) == 19)
        // Without a server delay the exponential curve is untouched.
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 8) == 1_800)
    }

    @Test("A migration-sized backlog is paced; ordinary edits are not")
    func cloudKitBackfillPacingAppliesOnlyToMigrations() {
        // Editing backlogs keep the immediate follow-on send.
        #expect(!CloudKitSyncBackfillPolicy.shouldPaceNextBatch(pendingCount: 0))
        #expect(!CloudKitSyncBackfillPolicy.shouldPaceNextBatch(pendingCount: 1))
        #expect(!CloudKitSyncBackfillPolicy.shouldPaceNextBatch(
            pendingCount: CloudKitSyncBackfillPolicy.migrationBacklogThreshold
        ))
        // A container rename queues the whole library; that gets the gap.
        #expect(CloudKitSyncBackfillPolicy.shouldPaceNextBatch(
            pendingCount: CloudKitSyncBackfillPolicy.migrationBacklogThreshold + 1
        ))
        #expect(CloudKitSyncBackfillPolicy.shouldPaceNextBatch(pendingCount: 7_931))
        #expect(CloudKitSyncBackfillPolicy.batchPacingNanoseconds > 0)
    }

    @Test("Server throttles are backpressure, not sync failures")
    func cloudKitThrottleIsNotCountedAsFailure() {
        for code in [CKError.Code.requestRateLimited, .serviceUnavailable, .zoneBusy] {
            let throttle = CKError(code)
            #expect(CloudKitSyncRetryPolicy.isServerThrottle(throttle))
        }
        #expect(!CloudKitSyncRetryPolicy.isServerThrottle(CKError(.networkFailure)))
        #expect(!CloudKitSyncRetryPolicy.isServerThrottle(CKError(.quotaExceeded)))
        #expect(!CloudKitSyncRetryPolicy.isServerThrottle(CancellationError()))
    }

    @Test("A sustained throttle escalates past the server's repeated answer")
    func cloudKitSustainedThrottleEscalates() {
        // The server's answer is obeyed as given while the drain may still be
        // moving, which is what keeps a healthy backfill fast.
        for throttles in 0...CloudKitSyncRetryPolicy.throttleEscalationGrace {
            #expect(CloudKitSyncRetryPolicy.delaySeconds(
                consecutiveFailures: 0,
                serverRetryAfter: 18,
                consecutiveThrottles: throttles
            ) == 18)
        }

        // Past the grace the wait doubles per refusal, so the limiter gets a
        // chance to refill instead of being re-armed every 18 seconds. This is
        // the 2026-08-30 loop: 555 refusals, zero records sent.
        let grace = CloudKitSyncRetryPolicy.throttleEscalationGrace
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 0, serverRetryAfter: 18, consecutiveThrottles: grace + 1
        ) == 36)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 0, serverRetryAfter: 18, consecutiveThrottles: grace + 2
        ) == 72)

        // Escalation is bounded, so a container that recovers is picked up
        // without waiting on a relaunch.
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 0, serverRetryAfter: 18, consecutiveThrottles: 500
        ) == CloudKitSyncRetryPolicy.maximumThrottleDelay)

        // A tiny server delay still cannot become a hot loop.
        #expect(CloudKitSyncRetryPolicy.delaySeconds(
            consecutiveFailures: 0, serverRetryAfter: 0.25, consecutiveThrottles: 0
        ) == CloudKitSyncRetryPolicy.minimumThrottleDelay)

        // With no server answer the ordinary failure curve is unchanged.
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 1) == 60)
        #expect(CloudKitSyncRetryPolicy.delaySeconds(consecutiveFailures: 2) == 120)
    }

    @Test("A refused batch comes back smaller as well as later")
    func cloudKitThrottleShrinksTheBatch() {
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: 100, consecutiveThrottles: 0
        ) == 100)
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: 100, consecutiveThrottles: 1
        ) == 50)
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: 100, consecutiveThrottles: 2
        ) == 25)

        // Bounded below and saturating: a batch of one turns a large backlog
        // into one round trip per record, which is its own way of never
        // finishing. Shrinking stops after four halvings (100 → 6) and never
        // dips under the floor however long the refusals run.
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: 100, consecutiveThrottles: 4
        ) == 6)
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: 100, consecutiveThrottles: 99
        ) == 6)
        for throttles in 0...99 {
            #expect(CloudKitSyncThrottleAdaptation.batchLimit(
                defaultLimit: 100, consecutiveThrottles: throttles
            ) >= CloudKitSyncThrottleAdaptation.minimumBatchLimit)
        }
        // A default already at the floor is left alone rather than shrunk.
        #expect(CloudKitSyncThrottleAdaptation.batchLimit(
            defaultLimit: CloudKitSyncThrottleAdaptation.minimumBatchLimit,
            consecutiveThrottles: 9
        ) == CloudKitSyncThrottleAdaptation.minimumBatchLimit)

        // Isolation still wins: it is hunting one poisoned record.
        #expect(CloudKitSyncBatchIsolationPolicy.batchLimit(
            defaultLimit: CloudKitSyncThrottleAdaptation.batchLimit(
                defaultLimit: 100, consecutiveThrottles: 3
            ),
            isIsolating: true
        ) == 1)
    }

    @Test("Only a send the server took clears the throttle count")
    func cloudKitLocalEditsDoNotClearThrottles() {
        let before = CloudKitSyncBacklogCheckpoint(
            pendingCount: 7_929,
            successfulChangeGeneration: 4,
            localChangeGeneration: 9
        )

        // An app that keeps writing rows must not erase the evidence that
        // CloudKit has refused every batch for hours.
        let localEditOnly = CloudKitSyncBacklogCheckpoint(
            pendingCount: 7_930,
            successfulChangeGeneration: 4,
            localChangeGeneration: 10
        )
        #expect(before.shouldContinueImmediately(to: localEditOnly))
        #expect(!before.didDrain(to: localEditOnly))

        // A server acknowledgement does clear it.
        let acknowledged = CloudKitSyncBacklogCheckpoint(
            pendingCount: 7_929,
            successfulChangeGeneration: 5,
            localChangeGeneration: 9
        )
        #expect(before.didDrain(to: acknowledged))

        // So does the queue actually shrinking.
        let drained = CloudKitSyncBacklogCheckpoint(
            pendingCount: 7_829,
            successfulChangeGeneration: 4,
            localChangeGeneration: 9
        )
        #expect(before.didDrain(to: drained))
    }

    @Test("Backlog changes continue immediately even when the count is flat")
    func backlogProgressDoesNotEnterBackoff() {
        let before = CloudKitSyncBacklogCheckpoint(
            pendingCount: 4,
            successfulChangeGeneration: 10,
            localChangeGeneration: 20
        )

        #expect(before.shouldContinueImmediately(to: .init(
            pendingCount: 3,
            successfulChangeGeneration: 10,
            localChangeGeneration: 20
        )))
        #expect(before.shouldContinueImmediately(to: .init(
            pendingCount: 4,
            successfulChangeGeneration: 11,
            localChangeGeneration: 20
        )))
        #expect(before.shouldContinueImmediately(to: .init(
            pendingCount: 4,
            successfulChangeGeneration: 10,
            localChangeGeneration: 21
        )))
        #expect(!before.shouldContinueImmediately(to: before))
    }

    @Test("Drain retries stop when CloudKit makes no progress")
    func drainPolicyStopsRapidFailureRetries() {
        #expect(CloudKitSyncDrainPolicy.shouldAttemptAgain(
            previousRemaining: 100,
            currentRemaining: 40,
            attempt: 0,
            maxAttempts: 4
        ))
        #expect(!CloudKitSyncDrainPolicy.shouldAttemptAgain(
            previousRemaining: 40,
            currentRemaining: 40,
            attempt: 1,
            maxAttempts: 4
        ))
        #expect(!CloudKitSyncDrainPolicy.shouldAttemptAgain(
            previousRemaining: 2,
            currentRemaining: 1,
            attempt: 3,
            maxAttempts: 4
        ))
    }

    @MainActor
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

    @MainActor
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

    @Test("Only a streak of untaken attempts counts as a stalled drain")
    func syncStallPolicyIgnoresIsolatedNoProgressWindows() {
        #expect(!CloudKitSyncStallPolicy.isStalled(consecutiveFailures: 0, consecutiveThrottles: 0))
        #expect(!CloudKitSyncStallPolicy.isStalled(consecutiveFailures: 1, consecutiveThrottles: 2))
        #expect(CloudKitSyncStallPolicy.isStalled(consecutiveFailures: 0, consecutiveThrottles: 3))
        #expect(CloudKitSyncStallPolicy.isStalled(consecutiveFailures: 4, consecutiveThrottles: 0))
    }

    @Test("The bulk re-enqueue stamp is recognised as a sort key, not an edit time")
    func syncBootstrapStampIsNotReadAsATimestamp() {
        #expect(CloudKitSyncBootstrapStamp.isBootstrap(CloudKitSyncBootstrapStamp.date))
        #expect(CloudKitSyncBootstrapStamp.isBootstrap(Date(timeIntervalSinceReferenceDate: -1)))
        #expect(!CloudKitSyncBootstrapStamp.isBootstrap(Date(timeIntervalSinceReferenceDate: 1)))
        #expect(!CloudKitSyncBootstrapStamp.isBootstrap(Date()))

        // The stamp must keep sorting a mass republish behind genuine edits.
        #expect(CloudKitSyncBootstrapStamp.date < Date())
    }

    @MainActor
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

    @MainActor
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

    @Test("Production-shaped Web and iPhone records converge through URL and published DOI identity")
    func productionShapedCrossSurfaceRelationshipsConverge() throws {
        let fixtureURL = try #require(
            Bundle(for: CrossSurfaceCloudKitFixtureBundleToken.self).url(
                forResource: "cross-surface-cloudkit-roundtrip-v1",
                withExtension: "json"
            )
        )
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try #require(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        )
        let records = try #require(fixture["records"] as? [[String: Any]])

        // First prove that the fixture's identity envelopes are the payloads
        // authored by the real Mac mapper, rather than hand-maintained lookalikes.
        let sender = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var urlSource = StudioArticle(
            url: "https://www.example.com/identity/article?utm_source=fixture",
            title: "Portable URL identity",
            sourceType: .article,
            id: "sender-url-source"
        )
        urlSource.normalizedURL = "example.com/identity/article"
        try sender.saveSource(urlSource)
        var publishedPaper = StudioArticle(
            url: "https://preprints.example.org/manuscript/42",
            title: "Portable published DOI identity",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Fixture Journal",
            publishedYear: "2026",
            id: "sender-published-paper"
        )
        publishedPaper.doi = "10.1000/preprint-42"
        publishedPaper.publishedDOI = "10.1000/published-42"
        try sender.saveSource(publishedPaper)

        let sourceFixtures: [String: [String: Any]] = Dictionary(
            uniqueKeysWithValues: records.compactMap { record -> (String, [String: Any])? in
                guard record["recordType"] as? String == "Source",
                      let logicalKey = record["logicalKey"] as? String,
                      let payload = record["payload"] as? [String: Any] else { return nil }
                return (logicalKey, payload)
            }
        )
        for sourceID in [urlSource.id, publishedPaper.id] {
            let change = try #require(sender.pendingSyncChanges().first {
                $0.entity == .source && $0.logicalKey == sourceID
            })
            let record = try #require(
                try CloudKitRecordMapper.makeRecord(for: change, store: sender)
            )
            let payloadData = try #require(record.encryptedValues[.payload] as? NSData) as Data
            let payload = try #require(
                JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            )
            let actualIdentity = try #require(payload["sourceIdentity"] as? [String: Any])
            let fixtureIdentity = try #require(
                sourceFixtures[sourceID]?["sourceIdentity"] as? [String: Any]
            )
            #expect(actualIdentity["sourceID"] as? String == fixtureIdentity["sourceID"] as? String)
            #expect(actualIdentity["url"] as? String == fixtureIdentity["url"] as? String)
            #expect(actualIdentity["normalizedURL"] as? String == fixtureIdentity["normalizedURL"] as? String)
            #expect(actualIdentity["doi"] as? String == fixtureIdentity["doi"] as? String)
            #expect(actualIdentity["publishedDOI"] as? String == fixtureIdentity["publishedDOI"] as? String)
            #expect(record.encryptedValues[.payload] != nil)
            #expect(record.encryptedValues[.userModificationDate] != nil)
        }

        // The receiving Mac already knows the same works under independent
        // primary keys. The first matches by normalized URL; the second has a
        // different URL and DOI, so publishedDOI is its only shared identity.
        let receiver = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var receiverURLSource = StudioArticle(
            url: "https://example.com/identity/article",
            title: "Receiver URL copy",
            sourceType: .article,
            id: "receiver-url-source"
        )
        receiverURLSource.normalizedURL = "example.com/identity/article"
        try receiver.saveSource(receiverURLSource)
        var receiverPaper = StudioArticle(
            url: "https://publisher.example.org/final/42",
            title: "Receiver published paper",
            sourceType: .paper,
            id: "receiver-published-paper"
        )
        receiverPaper.publishedDOI = "10.1000/PUBLISHED-42"
        try receiver.saveSource(receiverPaper)

        for item in records where item["recordType"] as? String != "Source" {
            let entityName = try #require(item["entity"] as? String)
            let entity = try #require(CloudKitSyncEntity(rawValue: entityName))
            let logicalKey = try #require(item["logicalKey"] as? String)
            let payload = try #require(item["payload"] as? [String: Any])
            let record = CKRecord(
                recordType: entity.recordType,
                recordID: CloudKitRecordMapper.recordID(for: entity, logicalKey: logicalKey)
            )
            record.encryptedValues[.payload] = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ) as NSData
            record.encryptedValues[.userModificationDate] = Date() as NSDate
            _ = try CloudKitRecordMapper.apply(record: record, to: receiver)
        }

        let notebook = try #require(try receiver.loadLearningGoal("fixture-notebook"))
        #expect(notebook.items.map(\.sourceID) == [receiverURLSource.id, receiverPaper.id])
        #expect(notebook.items.first { $0.sourceID == receiverPaper.id }?.completedAt != nil)
        let notebookOutbound = try #require(
            try receiver.loadLearningGoalForSync("fixture-notebook")
        )
        #expect(notebookOutbound.sourceIdentities.map(\.sourceID) == [
            receiverURLSource.id,
            receiverPaper.id,
        ])
        #expect(notebookOutbound.sourceIdentities.last?.publishedDOI == "10.1000/published-42")

        let placement = try #require(
            try receiver.scheduledPlacement(forSource: receiverPaper.id)
        )
        #expect(placement.id == "scheduled-source-v1-cb8f90b01d631ded87ceb5bfb3eb398985ce7d659fee99af2d62aba4947d5312")
        #expect(placement.completedAt != nil)
        #expect(try receiver.scheduledSourceGoalIDs(sourceID: receiverPaper.id) == ["fixture-notebook"])
        let placementOutbound = try #require(
            try receiver.loadScheduledSourceForSync(placement.id)
        )
        #expect(placementOutbound.sourceIdentity?.sourceID == receiverPaper.id)
        #expect(placementOutbound.sourceIdentity?.publishedDOI == "10.1000/published-42")
        #expect(placementOutbound.activityDays.map(\.sourceID) == [receiverPaper.id])

        let review = try #require(
            try receiver.loadReviewSessionForSync("fixture-review")
        )
        #expect(review.goalID == "fixture-notebook")
        #expect(review.sourceIDs == [receiverURLSource.id, receiverPaper.id])
        #expect(review.sourceIdentities.map(\.sourceID) == [receiverURLSource.id, receiverPaper.id])
        #expect(review.exchanges.first?.sourceRefs == [receiverURLSource.id, receiverPaper.id])
    }

    @Test("Inbound ready source without readable text is queued locally, not republished")
    func inboundTextlessReadySourceIsRequeued() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = makeCloudKitArticle(
            url: "https://example.com/textless",
            title: "Textless Source"
        )
        remote.state = .ready
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.state == .queued)
        #expect(reloaded.content == nil)
        // The demotion stays local. "No asset in this fetch" is the ordinary
        // shape of a modification, not evidence the library has no text, so
        // publishing the verdict let one Mac's gap demote healthy sources
        // everywhere. Re-ingestion repairs the server copy through a real save.
        #expect(!applied.requiresRepublish)
    }

    @Test("Inbound CloudKit sources are applied before courses that reference them")
    func inboundSourcesSortBeforeCourses() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let courseID = "course-1"
        let source = makeCloudKitArticle(
            url: "https://youtube.com/watch?v=lecture-1",
            title: "Lecture 1"
        )
        let lecture = CourseSession(id: "lecture-1", courseName: courseID, number: 1)
        let item = CourseLectureItem(
            id: "item-1",
            lectureId: lecture.id,
            sourceId: source.id,
            role: .video,
            sortIndex: 0
        )

        let sourceRecord = try makeInboundRecord(
            entity: .source,
            logicalKey: source.id,
            payload: CloudKitSourcePayload(article: source)
        )
        let courseRecord = try makeInboundRecord(
            entity: .course,
            logicalKey: courseID,
            payload: CloudKitCoursePayload(
                id: courseID,
                title: "Language Modeling from Scratch",
                courseCode: "CS336",
                institution: "Stanford",
                instructors: nil,
                playlistURL: nil,
                lectures: [lecture],
                lectureItems: [item]
            )
        )

        let orderedRecords = [courseRecord, sourceRecord].enumerated().sorted { lhs, rhs in
            let lhsPriority = CloudKitRecordMapper.inboundApplicationPriority(for: lhs.element)
            let rhsPriority = CloudKitRecordMapper.inboundApplicationPriority(for: rhs.element)
            if lhsPriority == rhsPriority {
                return lhs.offset < rhs.offset
            }
            return lhsPriority < rhsPriority
        }.map(\.element)

        #expect(orderedRecords.map(\.recordType) == ["Source", "Course"])
        for record in orderedRecords {
            _ = try CloudKitRecordMapper.apply(record: record, to: store)
        }
        #expect(try store.loadCourseLectures() == [lecture])
        #expect(try store.loadCourseLectureItems() == [item])
    }

    @Test("Inbound source metadata cannot erase local video watch progress")
    func inboundSourcePreservesLocalVideoWatchProgress() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var local = makeCloudKitArticle(
            url: "https://youtube.com/watch?v=lecture-progress",
            title: "Lecture"
        )
        local.sourceType = .video
        local.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 300,
            watchedSeconds: 600,
            durationSeconds: 900
        ).encoded
        try store.saveSource(local)

        var remote = local
        remote.title = "Lecture metadata updated elsewhere"
        remote.readingPositionLocator = nil
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(local.id))
        #expect(reloaded.title == remote.title)
        #expect(reloaded.readingPositionLocator == local.readingPositionLocator)
        #expect(applied.requiresRepublish)
    }

    // MARK: Mark as Watched / Mark as Not Watched (product owner, 2026-09-27)

    private func makeWatchedVideo(_ slug: String, readAt: Date? = nil) -> StudioArticle {
        var video = makeCloudKitArticle(url: "https://youtube.com/watch?v=\(slug)", title: "Lecture")
        video.sourceType = .video
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 3500,
            watchedSeconds: 3550,
            durationSeconds: 3600
        ).encoded
        video.readAt = readAt
        return video
    }

    @Test("A Mark as Not Watched from another Mac replaces this Mac's watched progress")
    func inboundNotWatchedBeatsLocalHighWaterMark() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let local = makeWatchedVideo("unwatch-inbound")
        try store.saveSource(local)

        var remote = local
        remote.readingPositionLocator = VideoWatchProgress.notWatched(
            from: VideoWatchProgress(encoded: local.readingPositionLocator),
            at: Date()
        ).encoded
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(local.id))
        #expect(reloaded.readingPositionLocator == remote.readingPositionLocator)
        #expect(VideoWatchProgress(encoded: reloaded.readingPositionLocator)?.isEssentiallyWatched == false)
        #expect(!reloaded.hasSavedReadingPosition)
        // The record already says what this Mac now holds: nothing to send back.
        #expect(!applied.requiresRepublish)
    }

    @Test("This Mac's Mark as Not Watched survives a copy from before it, read stamp included")
    func localNotWatchedSurvivesStaleInbound() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let local = makeWatchedVideo("unwatch-local", readAt: Date(timeIntervalSinceNow: -86_400))
        try store.saveSource(local)
        let mark = try store.setVideoWatched(sourceID: local.id, watched: false)
        #expect(mark.changed)
        #expect(mark.readAt == nil)
        try store.clearPendingSyncChange(entity: .source, logicalKey: local.id)

        // Another Mac publishes the copy it had before the mark: watched, and
        // stamped read by a finished Schedule item the day before.
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: local.id,
            payload: CloudKitSourcePayload(article: local)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(local.id))
        #expect(reloaded.readingPositionLocator == mark.locator)
        #expect(reloaded.readAt == nil)
        // The mark goes back up, so the other Mac learns it too.
        #expect(applied.requiresRepublish)
    }

    @Test("A progress conflict keeps the Mark as Not Watched the server holds")
    func progressConflictKeepsServerNotWatched() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var local = makeWatchedVideo("unwatch-conflict", readAt: Date(timeIntervalSinceNow: -86_400))
        local.readingPositionLocator = nil
        try store.saveSource(local)
        try store.clearPendingSyncChange(entity: .source, logicalKey: local.id)
        // This Mac is still playing it: a progress-only save from before the
        // mark reached it is waiting to go up.
        try store.updateSourceReadingLocator(
            sourceID: local.id,
            locator: VideoWatchProgress(positionSeconds: 3500, watchedSeconds: 3550, durationSeconds: 3600).encoded
        )
        #expect(try store.hasPendingTutorOnlySyncChange(entity: .source, logicalKey: local.id))

        // The other Mac marked it not watched.
        var remote = local
        remote.readAt = nil
        remote.readingPositionLocator = VideoWatchProgress.notWatched(
            from: VideoWatchProgress(positionSeconds: 3500, watchedSeconds: 3550, durationSeconds: 3600),
            at: Date()
        ).encoded
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: local.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        _ = try #require(
            try CloudKitRecordMapper.mergeSourceProgressServerConflict(record: record, to: store)
        )

        let merged = try #require(try store.loadSourceForSync(local.id))
        #expect(merged.readingPositionLocator == remote.readingPositionLocator)
        #expect(merged.readAt == nil)
    }

    @Test("A reader's write from before a Mark as Not Watched cannot undo it")
    func staleReaderWriteCannotUndoNotWatched() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
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
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
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

    @Test("Marking a video watched or not watched is a progress-only synced write")
    func videoWatchedMarksAreProgressOnlyWrites() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var video = makeWatchedVideo("unwatch-queue")
        video.readingPositionLocator = nil
        try store.saveSource(video)
        try store.clearPendingSyncChange(entity: .source, logicalKey: video.id)

        // Never played: nothing to clear, and no length to finish it with.
        #expect(try store.setVideoWatched(sourceID: video.id, watched: false).changed == false)
        #expect(try !store.hasPendingSyncChange(entity: .source, logicalKey: video.id))
        #expect(throws: (any Error).self) {
            _ = try store.setVideoWatched(sourceID: video.id, watched: true)
        }

        try store.updateSourceReadingLocator(
            sourceID: video.id,
            locator: VideoWatchProgress(positionSeconds: 600, watchedSeconds: 600, durationSeconds: 3600).encoded
        )
        try store.clearPendingSyncChange(entity: .source, logicalKey: video.id)
        let finished = try store.setVideoWatched(sourceID: video.id, watched: true)
        #expect(finished.changed)
        #expect(finished.readAt == nil)
        #expect(VideoWatchProgress(encoded: finished.locator)?.isEssentiallyWatched == true)
        #expect(try store.hasPendingTutorOnlySyncChange(entity: .source, logicalKey: video.id))
        #expect(try store.setVideoWatched(sourceID: video.id, watched: true).changed == false)

        // A finished Schedule item stamps it read; Not Watched takes that too.
        try store.updateSourceReadAt(sourceID: video.id, readAt: Date())
        let cleared = try store.setVideoWatched(sourceID: video.id, watched: false)
        #expect(cleared.changed)
        #expect(cleared.readAt == nil)
        let reloaded = try #require(try store.loadSourceForSync(video.id))
        #expect(reloaded.readAt == nil)
        #expect(VideoWatchProgress.isUnwatchedMarker(reloaded.readingPositionLocator))
        #expect(!reloaded.hasSavedReadingPosition)

        #expect(throws: (any Error).self) {
            _ = try store.setVideoWatched(sourceID: "missing-video", watched: false)
        }
    }

    @Test("Inbound source without a file path cannot erase a local attachment")
    func inboundSourcePreservesLocalFilePath() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var local = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/39933528/",
            title: "Impact of physical activity",
            sourceType: .paper,
            localFilePath: "/tmp/10.1016_j.xcrm.2025.101968.pdf",
            author: "Amanda Cefis",
            journal: "Cell Reports Medicine",
            publishedYear: "2025"
        )
        installCloudKitPaperText(on: &local)
        let attested = local.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(local)

        var remote = local
        remote.title = "Impact of physical activity on aging skeletal muscle"
        remote.localFilePath = nil
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(local.id))
        #expect(reloaded.title == remote.title)
        #expect(reloaded.localFilePath == local.localFilePath)
        #expect(applied.requiresRepublish)
    }

    @Test("Inbound Book cover asset is materialized for the receiving Mac")
    func inboundBookCoverMaterializesForMacLibraryRows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-book-cover-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingCover = root.appendingPathComponent("incoming-cover.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        ))
        try png.write(to: incomingCover)

        let payload = CloudKitBookPayload(
            id: "incoming-book",
            title: "Incoming Book",
            author: "Author",
            coverPath: "Books/Incoming/cover.jpg"
        )
        let record = try makeInboundRecord(
            entity: .book,
            logicalKey: payload.id,
            payload: payload
        )
        record[.bookCoverAsset] = CKAsset(fileURL: incomingCover)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        _ = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: root.appendingPathComponent("Content", isDirectory: true)
        )

        // The book keeps the portable relative path it was published with; the
        // bytes land under this run's content root. `loadBooks` re-roots that
        // path against the live app root, so the installed file is checked where
        // the mapper actually wrote it.
        let coverPath = try #require(try store.loadBooks().coverPaths[payload.id])
        #expect(coverPath.hasSuffix("Books/Incoming/cover.jpg"))
        let installedCover = root
            .appendingPathComponent("Content", isDirectory: true)
            .appendingPathComponent("Books/Incoming/cover.jpg")
        #expect(fileManager.isReadableFile(atPath: installedCover.path))
    }

    @Test("Republishing a book whose cover bytes are elsewhere keeps the server asset")
    func bookRepublishWithoutLocalCoverKeepsServerCoverAsset() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-cover-keep-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // The path a sending Mac recorded; its bytes never reached this device.
        let absentCover = root.appendingPathComponent("cover.jpg").path

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: "coverless-book",
            title: "Coverless Book",
            coverPath: absentCover
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "coverless-book"
        })

        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))

        // Untouched, not cleared: assigning nil here would delete the cover this
        // book already has in CloudKit for every other device.
        #expect(record[.bookCoverAsset] == nil)
        #expect(!record.changedKeys().contains(CKRecord.FieldKey.bookCoverAsset))
    }

    @Test("Republishing a book with readable cover bytes uploads the cover asset")
    func bookRepublishUploadsReadableCoverAsset() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-cover-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("cover.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        ))
        try png.write(to: cover)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: "covered-book",
            title: "Covered Book",
            coverPath: cover.path
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "covered-book"
        })

        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))

        let asset = try #require(record[.bookCoverAsset] as? CKAsset)
        let assetURL = try #require(asset.fileURL)
        #expect(fileManager.isReadableFile(atPath: assetURL.path))
    }

    @Test("A deferred save ships metadata now and owes its content to a later pass")
    func deferredContentShipsMetadataAndReattachesLater() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-deferred-content-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("cover.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        ))
        try png.write(to: cover)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: "deferred-book",
            title: "Deferred Book",
            coverPath: cover.path
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "deferred-book"
        })

        // Migration pass: the record goes, the bytes stay behind.
        let metadataOnly = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store, deferContent: true)
        )
        #expect(metadataOnly[.bookCoverAsset] == nil)
        try store.commitStagedAssetDigests(recordName: change.recordName)
        #expect(try store.deferredContentRecordCount() == 1)

        // Nothing was acknowledged for that field, so the record still owes it.
        #expect(try store.committedAssetDigests(recordName: change.recordName)[
            CKRecord.FieldKey.bookCoverAsset
        ] == nil)

        // Content pass: the record comes back and this time carries the cover.
        let enqueued = try store.enqueueDeferredContentRecords(limit: 200)
        #expect(enqueued == 1)
        #expect(try store.deferredContentRecordCount() == 0)

        let contentChange = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "deferred-book"
        })
        let withContent = try #require(
            try CloudKitRecordMapper.makeRecord(for: contentChange, store: store)
        )
        #expect(withContent[.bookCoverAsset] as? CKAsset != nil)
    }

    @Test("Content is deferred only for a migration-sized backlog")
    func contentDeferralMatchesTheMigrationThreshold() {
        #expect(!CloudKitSyncBackfillPolicy.shouldDeferContent(pendingCount: 1))
        #expect(!CloudKitSyncBackfillPolicy.shouldDeferContent(
            pendingCount: CloudKitSyncBackfillPolicy.migrationBacklogThreshold
        ))
        #expect(CloudKitSyncBackfillPolicy.shouldDeferContent(pendingCount: 7_931))
        #expect(CloudKitSyncBackfillPolicy.contentPassBatchSize > 0)
    }

    @Test("A one-time republish re-uploads a cover the server no longer holds")
    func bookCoverRepublishSurvivesTheAcknowledgedDigestGate() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-cover-republish-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("cover.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        ))
        try png.write(to: cover)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: "republished-book",
            title: "Republished Book",
            coverPath: cover.path
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "republished-book"
        })

        // The upload CloudKit acknowledged.
        _ = try CloudKitRecordMapper.makeRecord(for: change, store: store)
        try store.commitStagedAssetDigests(recordName: change.recordName)

        // An ordinary re-save must not re-upload bytes that have not moved.
        let unchanged = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        #expect(unchanged[.bookCoverAsset] == nil)

        // A one-time republish nudge is evidence that the server copy is gone —
        // another Mac erased it. Without forgetting the acknowledgement the nudge
        // ships a save that omits the very cover it was queued to restore, which
        // is why marked-changed books stayed coverless on every other device.
        try store.invalidateAssetDigests(
            recordName: change.recordName,
            fields: [CKRecord.FieldKey.bookCoverAsset]
        )
        let repaired = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        #expect(repaired[.bookCoverAsset] as? CKAsset != nil)
    }

    @Test("Rebuilding before CloudKit acknowledges reuses the asset file instead of copying it again")
    func unacknowledgedRebuildReusesTheSameAssetFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-asset-reuse-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("cover.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        ))
        try png.write(to: cover)

        // Unique per run so the assertion counts only this test's files: the asset
        // directory is the shared user temp dir and outlives any one process.
        let groupName = "asset-reuse-\(UUID().uuidString)"
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: groupName,
            title: "Asset Reuse Book",
            coverPath: cover.path
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == groupName
        })

        let first = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let firstURL = try #require((first[.bookCoverAsset] as? CKAsset)?.fileURL)

        // A save CloudKit never acknowledged: the engine drops the staged digest,
        // so the next batch builds this record's cover all over again. That rebuild
        // used to write a second full copy under a fresh UUID, which is how one
        // day's syncing turned 8,066 asset fields into 19,305 files.
        try store.clearStagedAssetDigests(recordName: change.recordName)

        let second = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let secondURL = try #require((second[.bookCoverAsset] as? CKAsset)?.fileURL)

        #expect(firstURL == secondURL)
        let copies = try fileManager.contentsOfDirectory(
            at: firstURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("\(change.recordName)-book-cover-") }
        #expect(copies.count == 1)
    }

    @Test("Repeated unacknowledged save passes stage one CKAsset, not one per pass")
    func unacknowledgedRebuildReusesTheSameCKAsset() throws {
        CloudKitRecordMapper.resetStagedAssetCacheForTesting()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-ckasset-reuse-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = root.appendingPathComponent("cover.png")
        try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9J9f8AAAAASUVORK5CYII="
        )).write(to: cover)

        let groupName = "ckasset-reuse-\(UUID().uuidString)"
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: groupName,
            title: "CKAsset Reuse Book",
            coverPath: cover.path
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == groupName
        })

        func buildCover() throws -> CKAsset {
            let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
            return try #require(record[.bookCoverAsset] as? CKAsset)
        }

        // Pass 1 stages a digest CloudKit is never told about.
        let first = try buildCover()

        // Pass 2 is the abandoned-save shape: the engine saw neither a save nor a
        // failure, so `pending_digest` is still set and still unpromoted. Nothing
        // is committed, so the field is genuinely owed and must be re-attached —
        // but re-attaching must not mint a second CKAsset, because CloudKit
        // copies each one it is handed into its own cache under a fresh UUID.
        let pending = try #require(try store.pendingAssetDigests(recordName: change.recordName)[
            CKRecord.FieldKey.bookCoverAsset
        ])
        let second = try buildCover()

        // Pass 3 is the failed-save shape: `clearStagedAssetDigests` dropped the
        // row outright, so not even a pending digest survives. Same rule applies.
        try store.clearStagedAssetDigests(recordName: change.recordName)
        #expect(try store.pendingAssetDigests(recordName: change.recordName).isEmpty)
        let third = try buildCover()

        // One payload staged for one field is one CKAsset — identity, not just an
        // equal file URL. Three separate CKAssets over the same path is exactly
        // what filled 20 GB of ~/Library/Caches/CloudKit in two days.
        #expect(first === second)
        #expect(second === third)
        #expect(try store.pendingAssetDigests(recordName: change.recordName)[
            CKRecord.FieldKey.bookCoverAsset
        ] == pending)

        let staged = try fileManager.contentsOfDirectory(
            at: try #require(first.fileURL).deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("\(change.recordName)-book-cover-") }
        #expect(staged.count == 1)

        // The other half of the contract: content that actually moved still
        // uploads. A larger cover is a new payload, so it gets its own asset.
        try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGO4o6EBRwzEcQDzAxLBI9OCRQAAAABJRU5ErkJggg=="
        )).write(to: cover)
        let republished = try buildCover()
        #expect(republished !== first)
        #expect(republished.fileURL != first.fileURL)
    }

    @Test("Leaving the queue clears staged digests, whichever exit the record takes")
    func queueExitsClearStagedAssetDigests() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let digests = [CKRecord.FieldKey.sourcePDFAsset: "f:pdf:2:0:/q.pdf"]
        let future = Date().addingTimeInterval(3600)

        // Quarantine: the record is parked outside the retry queue, so nothing
        // will rebuild it and neither savedRecords nor failedRecordSaves will
        // ever mention it again.
        let quarantined = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-q")
        try store.stageAssetDigests(digests, recordName: quarantined)
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: "src-q",
            recordName: quarantined,
            reason: "test-quarantine",
            localModificationDate: Date(),
            serverModificationDate: Date(),
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil
        ))
        #expect(try store.pendingAssetDigests(recordName: quarantined).isEmpty)

        // And the repair for rows already stranded before either path cleared:
        // staged with no queue entry at all.
        let orphan = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-orphan")
        try store.stageAssetDigests(digests, recordName: orphan)
        #expect(try !store.pendingAssetDigests(recordName: orphan).isEmpty)
        #expect(try store.repairOrphanedAssetStaging() == 1)
        #expect(try store.pendingAssetDigests(recordName: orphan).isEmpty)
        #expect(try store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 0
        ).isEmpty)
    }

    @Test("Repairing orphans leaves a queued record's in-flight staging alone")
    func repairingOrphansSparesQueuedRecords() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let digests = [CKRecord.FieldKey.sourcePDFAsset: "f:pdf:3:0:/live.pdf"]

        // A record still in the queue is a save that may be in the air right
        // now. An unscoped repair would delete its staging and silently drop
        // the upload, which is worse than the orphan it was fixing.
        let article = makeCloudKitArticle(url: "https://example.com/live", title: "Live")
        try store.saveSource(article)
        let queued = try #require(try store.pendingSyncChanges().first {
            $0.entity == .source
        })
        try store.stageAssetDigests(digests, recordName: queued.recordName)

        let orphan = CloudKitRecordMapper.recordName(for: .book, logicalKey: "book-orphan")
        try store.stageAssetDigests(
            [CKRecord.FieldKey.bookCoverAsset: "f:cover:1:0:/o.jpg"],
            recordName: orphan
        )

        #expect(try store.repairOrphanedAssetStaging() == 1)
        #expect(try store.pendingAssetDigests(recordName: orphan).isEmpty)
        #expect(try store.pendingAssetDigests(recordName: queued.recordName)[
            CKRecord.FieldKey.sourcePDFAsset
        ] == "f:pdf:3:0:/live.pdf")
    }

    @Test("Repeated staging of one payload is counted so a stall can be told from a flight")
    func stalledAssetStagingSeparatesAbandonedFromInFlight() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-stall")
        let digests = [CKRecord.FieldKey.sourcePDFAsset: "f:pdf:2:0:/a.pdf"]
        // Anything staged is "older than" a cutoff in the future, which is how
        // the age gate is exercised without waiting an hour.
        let future = Date().addingTimeInterval(3600)

        // One pass is an ordinary save in flight and must not report.
        try store.stageAssetDigests(digests, recordName: recordName)
        #expect(try store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 3
        ).isEmpty)

        // Three passes of byte-identical content with no acknowledgement either
        // way is the abandoned-save shape. The digest never changes, so the
        // pending count alone looks exactly like the single pass above.
        try store.stageAssetDigests(digests, recordName: recordName)
        try store.stageAssetDigests(digests, recordName: recordName)
        let stalled = try store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 3
        )
        #expect(stalled.recordCount == 1)
        #expect(stalled.fieldCount == 1)
        #expect(stalled.maxAttempts == 3)
        #expect(stalled.oldestStagedAt != nil)

        // The age gate is the other half: a run that began after the cutoff is
        // in flight by definition, however many attempts it has.
        #expect(try store.stalledAssetStagingSummary(
            stagedBefore: Date(timeIntervalSinceReferenceDate: 0), minimumAttempts: 3
        ).isEmpty)

        // Acknowledgement clears the history rather than leaving a record that
        // once stalled looking permanently suspect.
        try store.commitStagedAssetDigests(recordName: recordName)
        #expect(try store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 1
        ).isEmpty)
    }

    @Test("A visibly failed save resets the staging history it accumulated")
    func clearingStagedDigestsResetsStalledStagingHistory() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-fail")
        let digests = [CKRecord.FieldKey.sourcePDFAsset: "f:pdf:2:0:/b.pdf"]
        let future = Date().addingTimeInterval(3600)

        for _ in 0..<4 {
            try store.stageAssetDigests(digests, recordName: recordName)
        }
        #expect(try !store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 3
        ).isEmpty)

        // A save that fails visibly is already handled: the row resets and the
        // next attempt starts its own history. Only silence accumulates.
        try store.clearStagedAssetDigests(recordName: recordName)
        #expect(try store.stalledAssetStagingSummary(
            stagedBefore: future, minimumAttempts: 1
        ).isEmpty)
    }

    @Test("Migrating to schema 82 adds the staging columns without losing digests")
    func schema82AddsStagingColumnsToAnExistingLedger() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-staging-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-migrated")
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try store.stageAssetDigests(
                [CKRecord.FieldKey.sourcePDFAsset: "f:pdf:9:0:/c.pdf"],
                recordName: recordName
            )
            try store.commitStagedAssetDigests(recordName: recordName)
        }

        // Rebuild the pre-82 shape on a real database: drop the three columns
        // and put the version stamp back, so reopening exercises the migration
        // rather than the fresh-schema path.
        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        for column in ["staged_attempts", "first_staged_at", "last_staged_at"] {
            #expect(sqlite3_exec(
                database, "ALTER TABLE sync_asset_digests DROP COLUMN \(column)", nil, nil, nil
            ) == SQLITE_OK)
        }
        #expect(sqlite3_exec(database, "PRAGMA user_version = 81", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let migrated = try KnowledgeStore(storeDirectory: root)
        // The acknowledged digest has to survive the migration: losing it would
        // silently re-upload the whole library on the next pass.
        #expect(try migrated.committedAssetDigests(recordName: recordName)[
            CKRecord.FieldKey.sourcePDFAsset
        ] == "f:pdf:9:0:/c.pdf")
        // And the new columns are usable immediately, defaulted rather than guessed.
        #expect(try migrated.stalledAssetStagingSummary(
            stagedBefore: Date().addingTimeInterval(3600), minimumAttempts: 0
        ).isEmpty)
    }

    @Test("Invalidating one asset field leaves the record's other assets alone")
    func invalidatingOneAssetDigestKeepsSiblingFieldsAcknowledged() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: "src-1")
        try store.stageAssetDigests(
            [
                CKRecord.FieldKey.paperThumbnailAsset: "f:thumbnail-v1:1:0:/a.jpg",
                CKRecord.FieldKey.sourcePDFAsset: "f:pdf:2:0:/a.pdf",
            ],
            recordName: recordName
        )
        try store.commitStagedAssetDigests(recordName: recordName)

        // The paper-thumbnail nudge must never drag a 30 MB PDF back up with it.
        try store.invalidateAssetDigests(
            recordName: recordName,
            fields: [CKRecord.FieldKey.paperThumbnailAsset]
        )

        let digests = try store.committedAssetDigests(recordName: recordName)
        #expect(digests[CKRecord.FieldKey.paperThumbnailAsset] == nil)
        #expect(digests[CKRecord.FieldKey.sourcePDFAsset] == "f:pdf:2:0:/a.pdf")
    }

    @Test("A book that has no cover at all still clears the server asset")
    func bookWithoutCoverPathClearsServerCoverAsset() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.saveBookMetadata(
            groupName: "never-covered-book",
            title: "Never Covered Book",
            coverPath: nil
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .book && $0.logicalKey == "never-covered-book"
        })

        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))

        #expect(record[.bookCoverAsset] == nil)
        #expect(record.changedKeys().contains(CKRecord.FieldKey.bookCoverAsset))
    }

    @Test("Inbound Web Studio PDF becomes a durable local paper and enters text recovery")
    func inboundWebStudioPDFMaterializesForPaperProcessing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-web-pdf-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingPDF = root.appendingPathComponent("incoming.pdf")
        try writeCloudKitTestPDF(to: incomingPDF)

        let webImportID = UUID()
        let fileName = "Learning from the Browser.pdf"
        var remote = StudioArticle(
            url: "Web Imports/\(webImportID.uuidString)/\(fileName)",
            title: "Learning from the Browser",
            sourceType: .paper,
            id: "web-pdf-source"
        )
        remote.state = .queued
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(
                article: remote,
                webFileName: fileName,
                webFileKind: "pdf"
            )
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingPDF)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let durableImportRoot = root.appendingPathComponent(
            ".appdata/.web-pdf-imports",
            isDirectory: true
        )

        let applied = try CloudKitRecordMapper.apply(
            record: record,
            to: KnowledgeStore(inMemory: true, syncGeneration: .one),
            sourceContentRoot: contentRoot,
            durableImportRoot: durableImportRoot
        )

        // Re-apply against a retained store below: the first call proves the
        // filesystem operation is independently replay-safe after a partial
        // sync attempt, while the second verifies the canonical SQLite result.
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        _ = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: contentRoot,
            durableImportRoot: durableImportRoot
        )
        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        let localFilePath = try #require(reloaded.localFilePath)
        #expect(reloaded.url.hasSuffix(
            "/Web Imports/\(webImportID.uuidString)/\(fileName)"
        ))
        #expect(reloaded.sourceType == .paper)
        #expect(localFilePath.hasSuffix(
            "/Papers/Web Imports/\(webImportID.uuidString)/\(fileName)"
        ))
        #expect(SourceService.canOpenPDF(at: localFilePath))
        #expect(reloaded.state == .queued)
        #expect(applied.requiresRepublish)

        _ = StudioArticle.warmResolvedLocalPathCache(forRawPaths: [localFilePath])
        #expect(StudioViewModel.paperNeedsAutoFetch(
            reloaded,
            alreadyAttempted: [],
            dedupKeysWithPDF: [],
            unavailableRecordedPDFIDs: []
        ))

        // The marker survives the Mac's mandatory republish so a second Mac can
        // recognize the same browser-originated asset instead of treating it as
        // an ordinary one-way Mac -> iOS attachment.
        try store.saveSource(reloaded)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == remote.id
        })
        let outboundRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let outboundData = try #require(outboundRecord.encryptedValues[.payload] as? NSData) as Data
        let outboundPayload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: outboundData)
        #expect(outboundPayload.webFileKind == "pdf")
        #expect(outboundPayload.webFileName == fileName)
        #expect(outboundRecord[.sourcePDFAsset] == nil)
    }

    @Test("Inbound Web Studio EPUB becomes a durable queued book import")
    func inboundWebStudioEPUBMaterializesForBookProcessing() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-web-epub-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingEPUB = root.appendingPathComponent("incoming.epub")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: incomingEPUB)

        let webImportID = UUID()
        let fileName = "Learning from the Browser.epub"
        var remote = StudioArticle(
            url: "Web Imports/\(webImportID.uuidString)/\(fileName)",
            title: "Learning from the Browser",
            sourceType: .book,
            id: "web-epub-source"
        )
        remote.state = .queued
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(
                article: remote,
                webFileName: fileName,
                webFileKind: "epub"
            )
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingEPUB)
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)

        let applied = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: contentRoot,
            durableImportRoot: root.appendingPathComponent("Durable", isDirectory: true)
        )

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        let localFilePath = try #require(reloaded.localFilePath)
        #expect(reloaded.sourceType == .book)
        #expect(reloaded.state == .queued)
        #expect(localFilePath.hasSuffix(
            "/Books/Web Imports/\(webImportID.uuidString)/\(fileName)"
        ))
        #expect((try Data(contentsOf: URL(fileURLWithPath: localFilePath))).starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #expect(applied.requiresRepublish)

        try store.saveSource(reloaded)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == remote.id
        })
        let outboundRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let outboundData = try #require(outboundRecord.encryptedValues[.payload] as? NSData) as Data
        let outboundPayload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: outboundData)
        #expect(outboundPayload.webFileKind == "epub")
        #expect(outboundPayload.webFileName == fileName)
        #expect(outboundRecord[.sourcePDFAsset] == nil)
    }

    @Test("A server copy whose narration metadata arrives without its asset keeps the local narration")
    func listenableMetadataWithoutAssetKeepsLocalNarration() throws {
        // The server record inside a `.serverRecordChanged` error has every
        // encrypted field and no asset bytes. Resolving that miss in the
        // server's favour applies exactly this shape, and until 2026-09-01 the
        // mapper called it corrupt: 47 narrated sources then failed their
        // refusal bookkeeping on every flush and the engine backed off.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-narration-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let content = "Narrated source\n\nThe body a learner reads."
        let contentFile = root.appendingPathComponent("content.txt")
        try content.write(to: contentFile, atomically: true, encoding: .utf8)

        var remote = StudioArticle(
            url: "https://example.com/narrated-source",
            title: "Narrated source",
            sourceType: .article,
            id: "narrated-source"
        )
        remote.state = .ready
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)

        // A full fetch installs the source with its content.
        let fetched = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )
        fetched[.sourceContentAsset] = CKAsset(fileURL: contentFile)
        _ = try CloudKitRecordMapper.apply(record: fetched, to: store, sourceContentRoot: contentRoot)

        // This Mac prepared a narration for it.
        let narration = "Narrated source. The body a learner reads."
        let metadata = SourceListenableContentMetadata(
            sourceSHA256: PaperContentPreparationService.sha256(content),
            generatorVersion: SourceListenableContentMetadata.currentVersion,
            preparationSignature: nil,
            characterCount: narration.count,
            preparedAt: Date()
        )
        try store.saveSourceListenableContentFromSync(
            sourceID: remote.id,
            content: narration,
            metadata: metadata
        )

        // The conflict copy: metadata says there is narration, no asset carries it.
        let conflictCopy = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote, listenableContentMetadata: metadata)
        )
        let applied = try CloudKitRecordMapper.apply(
            record: conflictCopy,
            to: store,
            sourceContentRoot: contentRoot
        )

        let kept = try #require(try store.loadSourceListenableContent(remote.id))
        #expect(kept.text == narration)
        #expect(kept.metadata == metadata)
        #expect(try store.loadSourceForSync(remote.id)?.content == content)
        // The peer's copy lacks what this Mac holds, so this Mac publishes it.
        #expect(applied.requiresRepublish)
    }

    @Test("Inbound archived article HTML is installed at a portable local path")
    func inboundArchivedArticleHTMLMaterializes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-article-inbound-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingHTML = root.appendingPathComponent("incoming.html")
        try "<article><h1>Synced archive</h1><p>Rich body.</p></article>"
            .write(to: incomingHTML, atomically: true, encoding: .utf8)
        let incomingText = root.appendingPathComponent("content.txt")
        try "Synced archive\n\nRich body."
            .write(to: incomingText, atomically: true, encoding: .utf8)

        var remote = StudioArticle(
            url: "https://example.com/synced-archive",
            title: "Synced archive",
            sourceType: .article,
            id: "synced-archive"
        )
        remote.localFilePath = "/Users/another/Library/Application Support/ForeverLM/Content/Articles/synced-archive/article.html"
        remote.state = .ready
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )
        record[.sourceReaderHTMLAsset] = CKAsset(fileURL: incomingHTML)
        record[.sourceContentAsset] = CKAsset(fileURL: incomingText)
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)

        let applied = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: contentRoot
        )

        let portablePath = "Articles/synced-archive/article.html"
        var persistedLocalFilePath: String?
        try store.queryBind(
            "SELECT local_file_path FROM articles WHERE source_id = ? LIMIT 1",
            bind: { statement in store.bind(statement, 1, remote.id) }
        ) { statement in
            persistedLocalFilePath = store.string(statement, 0)
        }
        #expect(persistedLocalFilePath == portablePath)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        // Source reads deliberately resolve portable database paths against the
        // current Mac's content root; portability belongs to the stored row.
        #expect(reloaded.localFilePath == StorageService.absoluteSourcePath(portablePath))
        #expect(reloaded.content == "Synced archive\n\nRich body.")
        #expect(!applied.requiresRepublish)
        let installed = contentRoot.appendingPathComponent(
            "Articles/synced-archive/article.html"
        )
        #expect(try String(contentsOf: installed, encoding: .utf8).contains("Rich body."))

        // The next ordinary save must keep that convergence. Source reads
        // resolve the stored path for this Mac, but the payload must put the
        // portable database identity on the wire; otherwise receiving our own
        // save alternates absolute/relative paths forever.
        try store.markRecordChanged(entity: .source, logicalKey: remote.id)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == remote.id
        })
        let outboundRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let outboundData = try #require(
            outboundRecord.encryptedValues[.payload] as? NSData
        ) as Data
        let outboundPayload = try JSONDecoder().decode(
            CloudKitSourcePayload.self,
            from: outboundData
        )
        #expect(outboundPayload.article.localFilePath == portablePath)

        let echoed = try CloudKitRecordMapper.apply(
            record: outboundRecord,
            to: store,
            sourceContentRoot: contentRoot
        )
        #expect(!echoed.requiresRepublish)
    }

    @Test("Browser course shell keeps its pending playlist import through CloudKit")
    func inboundBrowserCourseShellRoundTripsPendingImport() throws {
        let courseID = UUID().uuidString
        let payloadObject: [String: Any] = [
            "id": courseID,
            "name": courseID,
            "title": NSNull(),
            "playlistURL": "https://www.youtube.com/playlist?list=PLbrowserfixture",
            "isHidden": false,
            "pendingPlaylistImport": true,
            "lectures": [],
            "lectureItems": [],
        ]
        let record = CKRecord(
            recordType: CloudKitSyncEntity.course.recordType,
            recordID: CloudKitRecordMapper.recordID(for: .course, logicalKey: courseID)
        )
        record.encryptedValues[.payload] = try JSONSerialization.data(
            withJSONObject: payloadObject
        ) as NSData
        record.encryptedValues[.userModificationDate] = Date() as NSDate
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)

        _ = try CloudKitRecordMapper.apply(record: record, to: store)

        let metadata = try #require(try store.loadCourseGroups()[courseID])
        #expect(metadata.title == courseID)
        #expect(metadata.playlistURL == "https://www.youtube.com/playlist?list=PLbrowserfixture")
        #expect(metadata.pendingPlaylistImport)

        try store.saveCourseGroup(name: courseID, metadata: metadata)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .course && $0.logicalKey == courseID
        })
        let outboundRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let outboundData = try #require(outboundRecord.encryptedValues[.payload] as? NSData) as Data
        let outboundPayload = try JSONDecoder().decode(CloudKitCoursePayload.self, from: outboundData)
        #expect(outboundPayload.id == courseID)
        #expect(outboundPayload.pendingPlaylistImport)
        #expect(outboundPayload.playlistURL == metadata.playlistURL)
    }

    @Test("Web Studio PDF falls back durably when the canonical Papers root is unavailable")
    func inboundWebStudioPDFUsesDurableFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-web-pdf-fallback-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingPDF = root.appendingPathComponent("incoming.pdf")
        try writeCloudKitTestPDF(to: incomingPDF)
        let blockedContentRoot = root.appendingPathComponent("blocked-content-root")
        try Data("not a directory".utf8).write(to: blockedContentRoot)
        let durableImportRoot = root.appendingPathComponent(
            ".appdata/.web-pdf-imports",
            isDirectory: true
        )

        let webImportID = UUID()
        let fileName = "Durable Browser Paper.pdf"
        let remote = StudioArticle(
            url: "Web Imports/\(webImportID.uuidString)/\(fileName)",
            title: "Durable Browser Paper",
            sourceType: .paper,
            id: "durable-web-pdf-source"
        )
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(
                article: remote,
                webFileName: fileName,
                webFileKind: "pdf"
            )
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingPDF)
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)

        _ = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: blockedContentRoot,
            durableImportRoot: durableImportRoot
        )

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        let localFilePath = try #require(reloaded.localFilePath)
        #expect(localFilePath.hasSuffix(
            "/.web-pdf-imports/\(webImportID.uuidString)/\(fileName)"
        ))
        #expect(SourceService.canOpenPDF(at: localFilePath))
        _ = StudioArticle.warmResolvedLocalPathCache(forRawPaths: [localFilePath])
        #expect(StudioViewModel.paperNeedsAutoFetch(
            reloaded,
            alreadyAttempted: [],
            dedupKeysWithPDF: [],
            unavailableRecordedPDFIDs: []
        ))
        try store.saveSource(reloaded)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == remote.id
        })
        let outboundRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let outboundData = try #require(outboundRecord.encryptedValues[.payload] as? NSData) as Data
        let outboundPayload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: outboundData)
        #expect(outboundPayload.webFileKind == "pdf")
        #expect(outboundPayload.webFileName == fileName)
    }

    @Test("Ordinary sourcePDFAsset remains a one-way Mac to iOS compatibility field")
    func inboundOrdinaryPaperAssetIsNotMaterializedOnMac() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-ordinary-pdf-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingPDF = root.appendingPathComponent("ordinary.pdf")
        try writeCloudKitTestPDF(to: incomingPDF)

        var remote = StudioArticle(
            url: "https://example.com/ordinary-paper",
            title: "Ordinary Paper",
            sourceType: .paper,
            id: "ordinary-paper-asset"
        )
        remote.state = .queued
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingPDF)
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let durableImportRoot = root.appendingPathComponent(
            ".appdata/.web-pdf-imports",
            isDirectory: true
        )

        _ = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: contentRoot,
            durableImportRoot: durableImportRoot
        )

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.localFilePath == nil)
        #expect(!fileManager.fileExists(
            atPath: contentRoot.appendingPathComponent("Papers/Web Imports").path
        ))
    }

    /// The recovery read the sync engine performs for a library whose recorded
    /// documents are on no local disk. It asks CloudKit for one field, so there
    /// is no payload to apply — only bytes to install at the path already on
    /// record.
    @Test("A one-field recovery record installs the PDF at its recorded path")
    func recoveryRecordInstallsRecordedSourcePDF() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-pdf-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let serverCopy = root.appendingPathComponent("server.pdf")
        try writeCloudKitTestPDF(to: serverCopy)

        let sourceID = "recovered-paper-\(UUID().uuidString)"
        let stored = "Papers/\(sourceID).pdf"
        let record = CKRecord(
            recordType: CloudKitSyncEntity.source.recordType,
            recordID: CloudKitRecordMapper.recordID(for: .source, logicalKey: sourceID)
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: serverCopy)

        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let installed = try #require(CloudKitRecordMapper.installRecordedSourcePDFAsset(
            from: record,
            storedPath: stored,
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ))
        #expect(installed == contentRoot.appendingPathComponent(stored).path)
        #expect(fileManager.fileExists(atPath: installed))

        // The digest describes the bytes the server already holds, so the next
        // unrelated save must not re-upload them.
        let digest = CloudKitRecordMapper.recoveredSourcePDFAssetDigest(atPath: installed)
        #expect(digest.hasPrefix("f:pdf:"))
        #expect(digest.hasSuffix(installed))

        // A record that carries no asset leaves the library exactly as it was.
        let assetless = CKRecord(
            recordType: CloudKitSyncEntity.source.recordType,
            recordID: CloudKitRecordMapper.recordID(for: .source, logicalKey: sourceID + "-empty")
        )
        #expect(CloudKitRecordMapper.installRecordedSourcePDFAsset(
            from: assetless,
            storedPath: "Papers/\(sourceID)-empty.pdf",
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ) == nil)
    }

    /// An EPUB book imported on another Mac: this Mac has the chapter's path and
    /// text but not its markup, and the record's reader document is the only
    /// copy of the chapter's layout and figures that can reach it.
    @Test("A recovery record installs an EPUB chapter's reader document at its path")
    func recoveryRecordInstallsBookChapterDocument() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-chapter-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let serverCopy = root.appendingPathComponent("server.html")
        try """
            <h1>1) Artificial vs Animal</h1><p>Volta was <em>astonished</em>.</p>\
            <img src="data:image/png;base64,iVBORw0KGgo=" alt="Figure 1"/>\
            <script>alert(1)</script>
            """
            .write(to: serverCopy, atomically: true, encoding: .utf8)

        let sourceID = "recovered-chapter-\(UUID().uuidString)"
        let stored = "Books/Recovered-\(sourceID)/Chapters/OEBPS/08_Chapter_01.xhtml"
        let record = CKRecord(
            recordType: CloudKitSyncEntity.source.recordType,
            recordID: CloudKitRecordMapper.recordID(for: .source, logicalKey: sourceID)
        )
        record[.sourceReaderHTMLAsset] = CKAsset(fileURL: serverCopy)

        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let installed = try #require(CloudKitRecordMapper.installRecordedBookChapterDocument(
            from: record,
            storedPath: stored,
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ))
        #expect(installed == contentRoot.appendingPathComponent(stored).path)

        let written = try String(contentsOfFile: installed, encoding: .utf8)
        #expect(written.contains("<em>astonished</em>"))
        #expect(written.contains("data:image/png;base64,"))
        #expect(!written.contains("<script"))
        // Sanitized HTML is not well-formed XML; the doctype is what makes the
        // reader load an `.xhtml` path as HTML instead of failing strict parsing.
        #expect(written.hasPrefix("<!DOCTYPE html>\n"))
        #expect(EPUBKitReaderSupport.normalizedXHTMLContent(for: installed) != nil)

        let digest = CloudKitRecordMapper.recoveredReaderDocumentAssetDigest(atPath: installed)
        #expect(digest.hasPrefix("f:reader-html-v2:"))
        #expect(digest.hasSuffix(installed))

        // Bytes already here are never overwritten.
        #expect(CloudKitRecordMapper.installRecordedBookChapterDocument(
            from: record,
            storedPath: installed,
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ) == nil)
        // A PDF path is the other installer's job.
        #expect(CloudKitRecordMapper.installRecordedBookChapterDocument(
            from: record,
            storedPath: "Books/Recovered-\(sourceID)/Chapters/01 Intro.pdf",
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ) == nil)
        // An escaping path never writes outside the content root.
        #expect(CloudKitRecordMapper.installRecordedBookChapterDocument(
            from: record,
            storedPath: "../outside-\(sourceID).xhtml",
            sourceContentRoot: contentRoot,
            logicalKey: sourceID
        ) == nil)
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("outside-\(sourceID).xhtml").path))
    }

    /// A recovery must never reach outside the content root, however a legacy
    /// path is spelled.
    @Test("Recovery refuses a recorded path that escapes the content root")
    func recoveryRefusesEscapingRecordedPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-pdf-escape-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let serverCopy = root.appendingPathComponent("server.pdf")
        try writeCloudKitTestPDF(to: serverCopy)

        let record = CKRecord(
            recordType: CloudKitSyncEntity.source.recordType,
            recordID: CloudKitRecordMapper.recordID(for: .source, logicalKey: "escaping-paper")
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: serverCopy)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let escaped = root.appendingPathComponent("outside-\(UUID().uuidString).pdf")

        #expect(CloudKitRecordMapper.installRecordedSourcePDFAsset(
            from: record,
            storedPath: "../\(escaped.lastPathComponent)",
            sourceContentRoot: contentRoot,
            logicalKey: "escaping-paper"
        ) == nil)
        #expect(!fileManager.fileExists(atPath: escaped.path))
    }

    /// The candidate query behind the recovery read.
    @Test("Recorded source PDF paths list every type that publishes an original")
    func recordedSourcePDFPathsCoverPublishingTypes() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var paper = StudioArticle(
            url: "https://example.com/recorded-paper",
            title: "Recorded Paper",
            sourceType: .paper,
            id: "recorded-paper"
        )
        paper.localFilePath = "Papers/recorded.pdf"
        try store.saveSource(paper)

        var video = StudioArticle(
            url: "https://youtube.com/watch?v=recorded",
            title: "Recorded Video",
            sourceType: .video,
            id: "recorded-video"
        )
        video.localFilePath = "Videos/recorded.mp4"
        try store.saveSource(video)

        try store.saveSource(StudioArticle(
            url: "https://example.com/no-document",
            title: "No Document",
            sourceType: .paper,
            id: "recorded-paper-without-file"
        ))

        let rows = try store.loadRecordedSourcePDFPaths()
        #expect(rows.count == 1)
        #expect(rows.first?.sourceID == "recorded-paper")
        #expect(rows.first?.storedPath == "Papers/recorded.pdf")
    }

    /// The second way the same PDF went missing: this Mac deleting it.
    ///
    /// `sourcePDFAsset` was rebuilt on every source republish, so a Mac that had
    /// the metadata but not the bytes published `nil` into the field and erased
    /// the copy the other Mac had uploaded — on a save that had nothing to do
    /// with the PDF. Missing bytes are absent knowledge, not a detach.
    @Test("A Mac without the bytes leaves the server's PDF asset alone")
    func outboundSourceWithoutLocalPDFPreservesServerAsset() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var paper = StudioArticle(
            url: "https://example.com/preserved-paper",
            title: "Preserved Paper",
            sourceType: .paper,
            id: "preserved-paper-asset"
        )
        // Recorded, but the bytes live on the Mac that imported it.
        paper.localFilePath = "Papers/preserved-\(UUID().uuidString).pdf"
        try store.saveSource(paper)

        let recordName = try #require(
            try store.loadSyncMetadata(entity: .source, logicalKey: paper.id)
        ).recordName

        // The other Mac's upload, already acknowledged on the server.
        let remoteDigest = "f:pdf:remote-upload"
        try store.execForTesting("""
            INSERT INTO sync_asset_digests (record_name, field, digest, pending_digest)
            VALUES ('\(recordName)', 'sourcePDFAsset', '\(remoteDigest)', NULL)
        """)

        // An ordinary metadata edit on this Mac — nothing to do with the PDF.
        paper.title = "Preserved Paper (edited)"
        try store.saveSource(paper)
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        })
        _ = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))

        var digest: String?
        var pending: String?
        try store.query("""
            SELECT digest, pending_digest FROM sync_asset_digests
            WHERE record_name = '\(recordName)' AND field = 'sourcePDFAsset'
        """) { stmt in
            digest = store.string(stmt, 0)
            pending = store.string(stmt, 1)
        }
        // Untouched. The old mapper staged the absent-digest "-" here and put a
        // nil in the record, which is what erased the other Mac's upload.
        #expect(digest == remoteDigest)
        #expect(pending == nil)
    }

    /// The failure this whole rail exists to prevent: a paper published by the
    /// other Mac that reported "PDF needed" here forever, with its own bytes in
    /// the record being applied.
    ///
    /// Builds before commit 3c62e0d put the publishing Mac's absolute path on the
    /// wire. Once content moved to `Library/Application Support/ForeverLM/Content`
    /// those paths had no `Documents/ForeverLM` component to key on, so this Mac
    /// could only match its own `/Users/<name>` prefix — never another's. The path
    /// reduced to nothing and the asset was refused as belonging to an unknown
    /// layout. Reducing it home-agnostically is what lets the bytes land, and the
    /// save then rewrites the row portably so it never happens again.
    @Test("A paper carrying another Mac's absolute path still installs its PDF")
    func inboundForeignHomePaperPathMaterializesItsPDF() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-foreign-home-pdf-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingPDF = root.appendingPathComponent("incoming.pdf")
        try writeCloudKitTestPDF(to: incomingPDF)

        // Exactly the shape the other Mac published: this device's content root
        // under a home directory that does not exist here.
        let localRootSuffix = (StorageService.localContentRootPath as NSString)
            .abbreviatingWithTildeInPath
        guard localRootSuffix.hasPrefix("~/") else { return }
        let foreignPath = "/Users/some-other-account/"
            + String(localRootSuffix.dropFirst(2))
            + "/Papers/foreign-home.pdf"

        var remote = StudioArticle(
            url: "https://example.com/foreign-home-paper",
            title: "Foreign Home Paper",
            sourceType: .paper,
            id: "foreign-home-paper"
        )
        remote.localFilePath = foreignPath
        remote.state = .queued
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingPDF)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let contentRoot = root.appendingPathComponent("Content", isDirectory: true)
        let durableImportRoot = root.appendingPathComponent(
            ".appdata/.web-pdf-imports",
            isDirectory: true
        )

        _ = try CloudKitRecordMapper.apply(
            record: record,
            to: store,
            sourceContentRoot: contentRoot,
            durableImportRoot: durableImportRoot
        )

        // The bytes land under this Mac's root, at the same relative path.
        let installed = contentRoot.appendingPathComponent("Papers/foreign-home.pdf")
        #expect(fileManager.fileExists(atPath: installed.path))
        #expect(SourceService.canOpenPDF(at: installed.path))

        // And the row is portable now, so this Mac never republishes the foreign
        // form back to the other one.
        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        let stored = try #require(reloaded.localFilePath)
        #expect(!stored.contains("some-other-account"))
        #expect(StorageService.relativeSourcePath(stored) == "Papers/foreign-home.pdf")
    }

    @Test("Flagged web PDF without its asset does not persist a broken source path")
    func inboundWebStudioPDFWithoutAssetFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foreverlm-missing-web-pdf-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let webImportID = UUID()
        let remote = StudioArticle(
            url: "Web Imports/\(webImportID.uuidString)/Missing.pdf",
            title: "Missing",
            sourceType: .paper,
            id: "missing-web-pdf"
        )
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(
                article: remote,
                webFileName: "Missing.pdf",
                webFileKind: "pdf"
            )
        )
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let durableImportRoot = root.appendingPathComponent(
            ".appdata/.web-pdf-imports",
            isDirectory: true
        )

        #expect(throws: KnowledgeStoreError.self) {
            _ = try CloudKitRecordMapper.apply(
                record: record,
                to: store,
                sourceContentRoot: root,
                durableImportRoot: durableImportRoot
            )
        }
        #expect(try store.loadSourceForSync(remote.id) == nil)
    }

    @Test("Transient Web Studio PDF apply failure survives token advance and retries after restart")
    func inboundWebStudioPDFTransientFailureRetriesDurably() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-web-pdf-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let incomingPDF = root.appendingPathComponent("incoming.pdf")
        try writeCloudKitTestPDF(to: incomingPDF)

        let importID = UUID()
        let fileName = "Retry Browser Paper.pdf"
        let source = StudioArticle(
            url: "Web Imports/\(importID.uuidString)/\(fileName)",
            title: "Retry Browser Paper",
            sourceType: .paper,
            id: "retry-web-pdf-source"
        )
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: source.id,
            payload: CloudKitSourcePayload(
                article: source,
                webFileName: fileName,
                webFileKind: "pdf"
            )
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: incomingPDF)

        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        let blockedContentRoot = root.appendingPathComponent("blocked-content")
        let blockedDurableRoot = root.appendingPathComponent("blocked-durable")
        try Data("not a directory".utf8).write(to: blockedContentRoot)
        try Data("not a directory".utf8).write(to: blockedDurableRoot)
        let failedAt = Date(timeIntervalSinceReferenceDate: 10_000)

        do {
            let store = try KnowledgeStore(storeDirectory: storeDirectory)
            do {
                _ = try CloudKitRecordMapper.apply(
                    record: record,
                    to: store,
                    sourceContentRoot: blockedContentRoot,
                    durableImportRoot: blockedDurableRoot
                )
                Issue.record("Expected both unavailable destinations to fail transiently")
            } catch {
                let disposition = try CloudKitSyncEngine.persistInboundWebPDFFailure(
                    error,
                    record: record,
                    store: store,
                    failedAt: failedAt
                )
                guard case .retryScheduled(let retry) = disposition else {
                    Issue.record("Expected a durable inbound retry, got \(String(describing: disposition))")
                    return
                }
                #expect(retry.attemptCount == 1)
                #expect(retry.nextAttemptAt == failedAt.addingTimeInterval(5))
            }
            #expect(try store.loadSourceForSync(source.id) == nil)
            #expect(try store.loadInboundWebPDFRetries().count == 1)
            #expect(try store.loadSyncConflicts().isEmpty)
            #expect(try store.syncConflictCount() == 0)
        }

        // CKSyncEngine may have committed the zone token before the next app
        // launch. Reopening SQLite proves the recovery input is independent of
        // that token and the original fetched-event lifetime.
        try fileManager.removeItem(at: blockedDurableRoot)
        let reopened = try KnowledgeStore(storeDirectory: storeDirectory)
        let retry = try #require(try reopened.loadInboundWebPDFRetries().first)
        let applied = try CloudKitSyncEngine.applyInboundWebPDFRetry(
            retry,
            record: record,
            store: reopened,
            sourceContentRoot: blockedContentRoot,
            durableImportRoot: blockedDurableRoot
        )

        #expect(applied?.entity == .source)
        let reloaded = try #require(try reopened.loadSourceForSync(source.id))
        let path = try #require(reloaded.localFilePath)
        let expectedPath = blockedDurableRoot
            .appendingPathComponent(importID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL.path
        #expect(path == expectedPath)
        #expect(SourceService.canOpenPDF(at: path))
        #expect(try reopened.loadInboundWebPDFRetries().isEmpty)
        #expect(try reopened.loadSyncConflicts().isEmpty)
    }

    @Test("Malformed Web Studio PDF is quarantined and never enters the retry loop")
    func inboundWebStudioPDFMalformedAssetIsQuarantined() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-web-pdf-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let malformedPDF = root.appendingPathComponent("malformed.pdf")
        try Data("This is not a PDF".utf8).write(to: malformedPDF)

        let importID = UUID()
        let fileName = "Malformed.pdf"
        let source = StudioArticle(
            url: "Web Imports/\(importID.uuidString)/\(fileName)",
            title: "Malformed Browser Paper",
            sourceType: .paper,
            id: "malformed-web-pdf-source"
        )
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: source.id,
            payload: CloudKitSourcePayload(
                article: source,
                webFileName: fileName,
                webFileKind: "pdf"
            )
        )
        record[.sourcePDFAsset] = CKAsset(fileURL: malformedPDF)
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let notificationProbe = CloudKitConflictNotificationProbe()
        let notificationToken = NotificationCenter.default.addObserver(
            forName: .cloudKitSyncConflictDidOccur,
            object: nil,
            queue: nil
        ) { notification in
            notificationProbe.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(notificationToken) }

        do {
            _ = try CloudKitRecordMapper.apply(
                record: record,
                to: store,
                sourceContentRoot: root.appendingPathComponent("Content"),
                durableImportRoot: root.appendingPathComponent("Durable")
            )
            Issue.record("Expected malformed PDF validation to fail")
        } catch {
            let disposition = try CloudKitSyncEngine.persistInboundWebPDFFailure(
                error,
                record: record,
                store: store
            )
            #expect(disposition == .quarantined)
        }

        #expect(try store.loadSourceForSync(source.id) == nil)
        #expect(try store.loadInboundWebPDFRetries().isEmpty)
        let conflict = try #require(try store.loadSyncConflicts().first)
        #expect(conflict.entity == .source)
        #expect(conflict.logicalKey == source.id)
        #expect(conflict.reason.hasPrefix(CloudKitInboundWebPDFRetry.quarantineReasonPrefix))
        #expect(!notificationProbe.observed(source.id))
    }

    @Test("Inbound source with a file path may replace a local path")
    func inboundSourceAcceptsRemoteFilePath() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var local = StudioArticle(
            url: "https://example.com/paper",
            title: "A Paper",
            sourceType: .paper,
            localFilePath: "/tmp/local-paper.pdf",
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        installCloudKitPaperText(on: &local)
        let attested = local.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(local)

        var remote = local
        remote.localFilePath = "/tmp/remote-paper.pdf"
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(local.id))
        #expect(reloaded.localFilePath == remote.localFilePath)
        #expect(!applied.requiresRepublish)
    }

    @Test("Inbound ready paper without an LLM attestation is demoted and republished")
    func inboundUnattestedPaperCannotRemainReady() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = StudioArticle(
            url: "https://example.com/paper",
            title: "A Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        remote.state = .ready
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.state == .error)
        #expect(reloaded.paperIngestionMethod == nil)
        #expect(reloaded.errorMessage?.contains("AI metadata extraction is required") == true)
        #expect(applied.requiresRepublish)
    }

    @Test("Attestation-less paper already demoted is applied without republishing")
    func inboundUnattestedPaperInSafeStateIsNotRepublished() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = StudioArticle(
            url: "https://example.com/demoted-paper",
            title: "A Demoted Paper",
            sourceType: .paper,
            author: StudioArticle.unknownPaperAuthor,
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: StudioArticle.unknownPaperYear
        )
        remote.state = .error
        remote.errorMessage = StudioArticle.missingPaperIngestionAttestationError
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.state == .error)
        #expect(reloaded.paperIngestionMethod == nil)
        // Republishing here would send back exactly what arrived, and the same
        // record returns on the next pass: an upload loop that never converges.
        #expect(!applied.requiresRepublish)
    }

    @Test("A dismissed source the server still calls active is archived and republished")
    func inboundActiveDismissedSourceIsArchivedAndRepublished() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = StudioArticle(
            url: "https://example.com/dismissed-episode",
            title: "A Dismissed Episode",
            sourceType: .podcast
        )
        try store.saveSource(remote)
        // `dismissSource` archives the matching local source itself.
        try store.dismissSource(url: remote.url, title: remote.title)

        // `remote` is still the pre-dismissal payload, which is exactly what a
        // device that has not seen the dismissal keeps sending: status active.
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.status == .archived)
        // The server still lists it as active, so this archive has to travel.
        #expect(applied.requiresRepublish)
    }

    @Test("A dismissed source the server already calls archived is not republished")
    func inboundArchivedDismissedSourceDoesNotRepublish() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = StudioArticle(
            url: "https://example.com/dismissed-episode",
            title: "A Dismissed Episode",
            sourceType: .podcast
        )
        try store.saveSource(remote)
        // `dismissSource` archives the matching local source itself.
        try store.dismissSource(url: remote.url, title: remote.title)

        // What comes back from CloudKit after that archive was published.
        remote.status = .archived
        remote.archivedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: remote.id,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.status == .archived)
        // Both sides already agree. Republishing here re-sends exactly what
        // arrived, our own save returns on the next pass, and this branch
        // republishes it again — an echo loop with no external input that kept
        // the sync badge busy on an idle app.
        #expect(!applied.requiresRepublish)
    }

    @Test("A refused save leaves the pending queue and comes back when re-armed")
    func refusedSaveQuarantineLeavesAndRejoinsThePendingQueue() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let article = makeCloudKitArticle(
            url: "https://example.com/refused-save",
            title: "Refused Save"
        )
        try store.saveSource(article)
        let queuedAfterSave = try store.pendingSyncChangeCount()
        #expect(try store.hasPendingSyncChange(entity: .source, logicalKey: article.id))

        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: article.id,
            recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: article.id),
            reason: CloudKitRejectedSaveQuarantine.encodedReason(
                errorCode: CKError.Code.invalidArguments.rawValue,
                message: "Cannot create new type Source in production schema"
            ),
            localModificationDate: Date(),
            serverModificationDate: Date(),
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil
        ))

        // Parked, so a permanently refused record can no longer hold the queue
        // above zero — which is what pinned the status indicator permanently.
        #expect(try store.pendingSyncChangeCount() == queuedAfterSave - 1)
        #expect(try !store.hasPendingSyncChange(entity: .source, logicalKey: article.id))
        #expect(try store.syncConflictCount() == 1)

        let rearmed = try store.requeueRejectedSaveQuarantines()

        #expect(rearmed == [.source: 1])
        #expect(try store.pendingSyncChangeCount() == queuedAfterSave)
        #expect(try store.hasPendingSyncChange(entity: .source, logicalKey: article.id))
        #expect(try store.syncConflictCount() == 0)
    }

    @Test("Re-arming leaves divergence quarantines alone")
    func requeueRejectedSavesIgnoresOtherQuarantines() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let article = makeCloudKitArticle(
            url: "https://example.com/divergent",
            title: "Divergent"
        )
        try store.saveSource(article)
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: article.id,
            recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: article.id),
            reason: "Divergent immutable record.",
            localModificationDate: Date(),
            serverModificationDate: Date(),
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil
        ))

        let rearmed = try store.requeueRejectedSaveQuarantines()

        #expect(rearmed.isEmpty)
        #expect(try store.syncConflictCount() == 1)
        #expect(try !store.hasPendingSyncChange(entity: .source, logicalKey: article.id))
    }

    @Test("A refused-save reason round-trips its code and message")
    func rejectedSaveReasonRoundTrips() {
        let encoded = CloudKitRejectedSaveQuarantine.encodedReason(
            errorCode: 12,
            message: "Cannot create new type Artifact in production schema"
        )
        let decoded = CloudKitRejectedSaveQuarantine.decodedReason(encoded)

        #expect(decoded?.errorCode == 12)
        #expect(decoded?.message == "Cannot create new type Artifact in production schema")
        #expect(CloudKitRejectedSaveQuarantine.decodedReason("Divergent immutable record.") == nil)
    }

    @Test("A refused delete is re-armed as a delete")
    func refusedDeleteRearmsAsDelete() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let article = makeCloudKitArticle(
            url: "https://example.com/refused-delete",
            title: "Refused Delete"
        )
        try store.saveSource(article)
        try store.deleteSource(article.id)
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: article.id)
        let reason = CloudKitRejectedChangeQuarantine.encodedReason(
            operation: .delete,
            errorCode: CKError.Code.invalidArguments.rawValue,
            message: "Delete rejected"
        )
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: article.id,
            recordName: recordName,
            reason: reason,
            localModificationDate: Date(),
            serverModificationDate: Date(),
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil
        ))

        #expect(try !store.hasPendingSyncChange(entity: .source, logicalKey: article.id))

        let rearmed = try store.requeueRejectedChangeQuarantines(
            at: Date(timeIntervalSinceReferenceDate: 500)
        )
        let pending = try #require(try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == article.id
        })

        #expect(rearmed == [.source: 1])
        #expect(pending.operation == .delete)
        #expect(try store.syncConflictCount() == 0)
    }

    @Test("A rejected change reason preserves its operation and message")
    func rejectedChangeReasonRoundTrips() {
        let encoded = CloudKitRejectedChangeQuarantine.encodedReason(
            operation: .delete,
            errorCode: 12,
            message: "Delete cannot be applied"
        )
        let decoded = CloudKitRejectedChangeQuarantine.decodedReason(encoded)

        #expect(decoded?.operation == .delete)
        #expect(decoded?.errorCode == 12)
        #expect(decoded?.message == "Delete cannot be applied")
        #expect(CloudKitRejectedChangeQuarantine.decodedReason("Unrelated") == nil)
    }

    @Test("Sync issue status names the rejected item and error")
    func syncIssueStatusNamesRejectedItemAndError() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let article = makeCloudKitArticle(
            url: "https://example.com/rejected-item",
            title: "Rejected item"
        )
        try store.saveSource(article)
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: article.id,
            recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: article.id),
            reason: CloudKitRejectedChangeQuarantine.encodedReason(
                operation: .save,
                errorCode: nil,
                message: "The local payload could not be encoded."
            ),
            localModificationDate: Date(timeIntervalSinceReferenceDate: 50),
            serverModificationDate: Date(timeIntervalSinceReferenceDate: 50),
            detectedAt: Date(timeIntervalSinceReferenceDate: 60),
            serverPayload: nil,
            serverSystemFields: nil
        ))

        let issue = try #require(try store.syncIssueItemSummaries().first)

        #expect(issue.title == "Rejected item")
        #expect(issue.kind == "Source")
        #expect(issue.operation == .save)
        #expect(issue.message == "The local payload could not be encoded.")
        #expect(issue.detectedAt == Date(timeIntervalSinceReferenceDate: 60))
    }

    @Test("Version-zero paper payload with complete metadata is grandfathered once")
    func legacyInboundPaperWithCompleteMetadataIsGrandfathered() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var remote = StudioArticle(
            url: "https://example.com/legacy-paper",
            title: "A Legacy Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2025"
        )
        remote.state = .ready
        let record = try makeLegacyInboundSourceRecord(article: remote)

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(remote.id))
        #expect(reloaded.paperIngestionMethod == .legacy)
        #expect(reloaded.hasPaperIngestionAttestation)
        #expect(reloaded.state == .queued)
        #expect(applied.requiresRepublish)
    }

    @Test("Incomplete inbound paper cannot erase richer local metadata or attestation")
    func inboundPaperPreservesCompletedLocalMetadata() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let sourceID = "completed-paper"
        var local = StudioArticle(
            url: "https://example.com/completed-paper",
            title: "Completed Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026",
            id: sourceID
        )
        local.doi = "10.1000/completed"
        installCloudKitPaperText(on: &local)
        let didCompleteLocalMetadata = local.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteLocalMetadata)
        try store.saveSource(local)

        var remote = StudioArticle(
            url: local.url,
            title: "Completed Paper (read elsewhere)",
            sourceType: .paper,
            author: StudioArticle.unknownPaperAuthor,
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: StudioArticle.unknownPaperYear,
            id: sourceID
        )
        remote.state = .error
        remote.errorMessage = StudioArticle.missingPaperIngestionAttestationError
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: sourceID,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(sourceID))
        #expect(reloaded.title == local.title)
        #expect(reloaded.author == local.author)
        #expect(reloaded.journal == local.journal)
        #expect(reloaded.publishedYear == local.publishedYear)
        #expect(reloaded.doi == local.doi)
        #expect(reloaded.paperIngestionMethod == .llm)
        #expect(reloaded.isPaperReadyForListenPreparation)
        #expect(!reloaded.hasSuccessfulPaperIngestion)
        #expect(applied.requiresRepublish)
    }

    @Test("Older inbound paper payload preserves an existing local LLM attestation")
    func inboundUnattestedPaperPreservesLocalAttestation() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let sourceID = "attested-paper"
        var local = StudioArticle(
            url: "https://example.com/paper",
            title: "A Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026",
            id: sourceID
        )
        installCloudKitPaperText(on: &local)
        let attested = local.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(local)

        var remote = StudioArticle(
            url: local.url,
            title: "A Paper Updated Elsewhere",
            sourceType: .paper,
            author: local.author,
            journal: local.journal,
            publishedYear: local.publishedYear,
            id: sourceID
        )
        remote.state = .ready
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: sourceID,
            payload: CloudKitSourcePayload(article: remote)
        )

        let applied = try CloudKitRecordMapper.apply(record: record, to: store)

        let reloaded = try #require(try store.loadSourceForSync(sourceID))
        #expect(reloaded.title == local.title)
        #expect(reloaded.paperIngestionMethod == .llm)
        #expect(reloaded.isPaperReadyForListenPreparation)
        #expect(!reloaded.hasSuccessfulPaperIngestion)
        #expect(applied.requiresRepublish)
    }

    @Test("Outbound source payload includes video watch progress")
    func outboundSourceIncludesVideoWatchProgress() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = makeCloudKitArticle(
            url: "https://youtube.com/watch?v=outbound-progress",
            title: "Lecture"
        )
        article.sourceType = .video
        article.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 420,
            watchedSeconds: 600,
            durationSeconds: 900
        ).encoded
        try store.saveSource(article)

        let change = try #require(
            store.pendingSyncChanges().first {
                $0.entity == .source && $0.logicalKey == article.id
            }
        )
        let record = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let payloadData: Data
        if let data = record.encryptedValues[.payload] as? Data {
            payloadData = data
        } else {
            let data = try #require(record.encryptedValues[.payload] as? NSData)
            payloadData = data as Data
        }
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)

        #expect(payload.article.readingPositionLocator == article.readingPositionLocator)
    }

    @Test("Outbound paper payload declares its version and carries the LLM attestation")
    func outboundPaperIncludesPayloadVersionAndAttestation() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var paper = StudioArticle(
            url: "https://example.com/attested-paper",
            title: "Attested Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026",
            id: "outbound-attested-paper"
        )
        installCloudKitPaperText(on: &paper)
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let payloadData = try #require(record.encryptedValues[.payload] as? NSData) as Data
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)

        #expect(payload.payloadVersion == CloudKitSourcePayload.currentVersion)
        #expect(payload.article.paperIngestionMethod == .llm)
    }

    @Test("Outbound papers carry a separate first-page thumbnail asset")
    func outboundPaperIncludesThumbnailAsset() throws {
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-paper-thumbnail-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.setFillColor(CGColor(red: 0.35, green: 0.15, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 72, y: 610, width: 468, height: 80))
        context.endPDFPage()
        context.closePDF()

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var paper = StudioArticle(
            url: pdfURL.path,
            title: "Thumbnail Paper",
            sourceType: .paper,
            id: "paper-thumbnail-test"
        )
        paper.localFilePath = pdfURL.path
        paper.prepareForPaperMetadataExtraction()
        try store.saveSource(paper)

        let change = try #require(
            store.pendingSyncChanges().first {
                $0.entity == .source && $0.logicalKey == paper.id
            }
        )
        let record = try #require(
            try CloudKitRecordMapper.makeRecord(for: change, store: store)
        )
        let pdfAsset = try #require(record[.sourcePDFAsset] as? CKAsset)
        let thumbnailAsset = try #require(record[.paperThumbnailAsset] as? CKAsset)
        let pdfAssetURL = try #require(pdfAsset.fileURL)
        let thumbnailAssetURL = try #require(thumbnailAsset.fileURL)

        #expect(FileManager.default.fileExists(atPath: pdfAssetURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbnailAssetURL.path))
        #expect((try Data(contentsOf: thumbnailAssetURL)).count > 0)
    }

    @Test("Outbound paper sync separates raw extraction from canonical content")
    func outboundPaperSeparatesRawAndCanonicalAssets() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let raw = "Publisher furniture\n\nExtracted paper text"
        var paper = StudioArticle(
            url: "https://example.com/pending-paper",
            title: "Pending Paper",
            sourceType: .paper,
            id: "pending-paper-sync"
        )
        paper.content = raw
        paper.prepareForPaperMetadataExtraction()
        try store.saveSource(paper)

        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let rawAsset = try #require(record[.sourceRawContentAsset] as? CKAsset)
        let rawAssetURL = try #require(rawAsset.fileURL)
        let payloadData = try #require(record.encryptedValues[.payload] as? NSData) as Data
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)

        #expect(try String(contentsOf: rawAssetURL, encoding: .utf8) == raw)
        #expect(record[.sourceContentAsset] == nil)
        #expect(payload.paperContentPreparation?.cleanerVersion == 0)
        #expect(payload.paperContentPreparation?.rawSHA256 == PaperContentPreparationService.sha256(raw))
    }

    @Test("Outbound article sync separates raw extraction from canonical content")
    func outboundArticleSeparatesRawAndCanonicalAssets() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let raw = "Site header\n\nArticle body\n\nRelated stories"
        let clean = "Article body"
        var article = StudioArticle(
            url: "https://example.com/prepared-article-sync",
            title: "Prepared Article",
            sourceType: .article,
            id: "prepared-article-sync"
        )
        article.installPreparedArticleContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.state = .ready
        try store.saveSource(article)

        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == article.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let cleanAsset = try #require(record[.sourceContentAsset] as? CKAsset)
        let rawAsset = try #require(record[.sourceRawContentAsset] as? CKAsset)
        let cleanURL = try #require(cleanAsset.fileURL)
        let rawURL = try #require(rawAsset.fileURL)
        let payloadData = try #require(record.encryptedValues[.payload] as? NSData) as Data
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)

        #expect(try String(contentsOf: cleanURL, encoding: .utf8) == clean)
        #expect(try String(contentsOf: rawURL, encoding: .utf8) == raw)
        #expect(payload.articleContentPreparation?.cleanerVersion == PaperContentPreparationMetadata.currentVersion)
        #expect(payload.paperContentPreparation == nil)
    }

    @Test("Outbound archived articles carry self-contained reader HTML")
    func outboundArchivedArticleCarriesReaderHTML() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "foreverlm-article-outbound-\(UUID().uuidString)/Articles/archive-reader",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let articleURL = root.appendingPathComponent("article.html")
        try """
        <html><body><script>alert(1)</script><h1>Archive</h1>
        <img src="data:image/png;base64,AAAA"><p>Illustrated text.</p></body></html>
        """.write(to: articleURL, atomically: true, encoding: .utf8)

        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/archive-reader",
            title: "Archive",
            sourceType: .article,
            id: "archive-reader"
        )
        article.localFilePath = articleURL.path
        article.content = "Archive\n\nIllustrated text."
        article.state = .ready
        try store.saveSource(article)

        let record = try makeSourceRecord(store: store, sourceID: article.id)
        let asset = try #require(record[.sourceReaderHTMLAsset] as? CKAsset)
        let assetURL = try #require(asset.fileURL)
        let html = try String(contentsOf: assetURL, encoding: .utf8)
        #expect(html.contains("Illustrated text."))
        #expect(html.contains("data:image/png;base64,AAAA"))
        #expect(!html.contains("<script"))
    }

    @Test("Archived article backfill is bounded to the local-storage cutover")
    func archivedArticleBackfillIsBoundedToCutover() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let cutover = Date(timeIntervalSinceReferenceDate: 808_718_400)
        var historical = StudioArticle(
            url: "https://example.com/historical-archive",
            title: "Historical archive",
            sourceType: .article,
            id: "historical-archive"
        )
        historical.dateAdded = cutover.addingTimeInterval(-1)
        historical.localFilePath = "Articles/historical-archive/article.html"
        try store.saveSource(historical)

        var localEra = StudioArticle(
            url: "https://example.com/local-era-archive",
            title: "Local-era archive",
            sourceType: .article,
            id: "local-era-archive"
        )
        localEra.dateAdded = cutover
        localEra.localFilePath = "/Users/peer/Library/Application Support/ForeverLM/Content/Articles/local-era-archive/article.HTML"
        try store.saveSource(localEra)

        #expect(try store.loadLocalStorageCutoverArchivedArticleSourceIDs() == [
            localEra.id,
        ])
    }

    @Test("Outbound source sync carries source-bound listenable content")
    func outboundSourceCarriesListenableContent() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        // A clean-up commit queues Listen only for an automatic-audio kind
        // (2026-09-24); this test is about what the prepared narration syncs.
        store.automaticAudioSourceTypes = { ["article"] }
        var source = StudioArticle(
            url: "https://example.com/listenable-article",
            title: "Listenable Article",
            sourceType: .article,
            id: "listenable-source-sync"
        )
        source.content = "Listenable Article\n\nCanonical source body."
        source.state = .ready
        try store.saveSource(source)
        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        let clean = "Listenable Article\n\nCanonical source body."
        try store.applyCanonicalContentCleanup(
            candidate: cleanup,
            prepared: PreparedPaperContent(
                raw: cleanup.raw,
                clean: clean,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: cleanup.rawSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )
        let candidate = try #require(try store.nextSourceListenableContentCandidate())
        try store.applySourceListenableContent(
            candidate: candidate,
            text: "Listenable Article. Canonical source body.",
            preparationSignature: "configured-route"
        )

        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == source.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let asset = try #require(record[.sourceListenableContentAsset] as? CKAsset)
        let assetURL = try #require(asset.fileURL)
        let payloadData = try #require(record.encryptedValues[.payload] as? NSData) as Data
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)

        #expect(
            try String(contentsOf: assetURL, encoding: .utf8)
                == "Listenable Article. Canonical source body."
        )
        #expect(payload.listenableContentMetadata?.sourceSHA256 == candidate.sourceSHA256)
        #expect(payload.listenableContentMetadata?.preparationSignature == "configured-route")
    }

    /// Builds the record for a source and, if `acknowledged`, promotes the
    /// digests it staged the way a successful CloudKit save would.
    private func makeSourceRecord(
        store: KnowledgeStore,
        sourceID: String,
        acknowledged: Bool = true
    ) throws -> CKRecord {
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == sourceID
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        if acknowledged {
            try store.commitStagedAssetDigests(recordName: change.recordName)
        } else {
            try store.clearStagedAssetDigests(recordName: change.recordName)
        }
        return record
    }

    @Test("Unchanged content assets are not re-uploaded on a later save")
    func unchangedAssetsAreOmittedFromLaterSaves() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/asset-gating",
            title: "Asset Gating",
            sourceType: .article,
            id: "asset-gating"
        )
        article.content = "Body text that does not change"
        article.state = .ready
        try store.saveSource(article)

        let first = try makeSourceRecord(store: store, sourceID: article.id)
        #expect(first[.sourceContentAsset] as? CKAsset != nil)

        // A save triggered by something unrelated to the content.
        article.title = "Asset Gating (renamed)"
        try store.saveSource(article)
        let second = try makeSourceRecord(store: store, sourceID: article.id)

        // Omitted, not nil: CloudKit keeps the asset it already holds.
        #expect(second[.sourceContentAsset] == nil)
        let payloadData = try #require(second.encryptedValues[.payload] as? NSData) as Data
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)
        #expect(payload.article.title == "Asset Gating (renamed)")
    }

    @Test("Edited content re-uploads its asset")
    func editedContentReuploadsAsset() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/asset-edit",
            title: "Asset Edit",
            sourceType: .article,
            id: "asset-edit"
        )
        article.content = "First body"
        article.state = .ready
        try store.saveSource(article)
        _ = try makeSourceRecord(store: store, sourceID: article.id)

        article.content = "Second body"
        try store.saveSource(article)
        let record = try makeSourceRecord(store: store, sourceID: article.id)

        let asset = try #require(record[.sourceContentAsset] as? CKAsset)
        let url = try #require(asset.fileURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Second body")
    }

    @Test("A failed save re-uploads its assets on the next attempt")
    func failedSaveReuploadsAssets() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/asset-retry",
            title: "Asset Retry",
            sourceType: .article,
            id: "asset-retry"
        )
        article.content = "Body that never landed"
        article.state = .ready
        try store.saveSource(article)

        // Built, sent, rejected — nothing reached the server.
        _ = try makeSourceRecord(store: store, sourceID: article.id, acknowledged: false)

        let retry = try makeSourceRecord(store: store, sourceID: article.id)
        let asset = try #require(retry[.sourceContentAsset] as? CKAsset)
        let url = try #require(asset.fileURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Body that never landed")
    }

    @Test("Removed content clears the asset the server still holds")
    func removedContentClearsServerAsset() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/asset-cleared",
            title: "Asset Cleared",
            sourceType: .article,
            id: "asset-cleared"
        )
        article.content = "Body that is later dropped"
        article.state = .ready
        try store.saveSource(article)
        _ = try makeSourceRecord(store: store, sourceID: article.id)

        try store.clearSourceDerivedData(article.id)
        let record = try makeSourceRecord(store: store, sourceID: article.id)

        #expect(record[.sourceContentAsset] == nil)

        // The absence is now the acknowledged baseline, so re-adding the same
        // body uploads again rather than being mistaken for unchanged.
        article.content = "Body that is later dropped"
        article.state = .ready
        try store.saveSource(article)
        let restored = try makeSourceRecord(store: store, sourceID: article.id)
        #expect(restored[.sourceContentAsset] as? CKAsset != nil)
    }

    @Test("Sent CloudKit snapshots do not clear newer pending edits")
    func sentSnapshotPreservesNewerPendingEdit() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let sentAt = Date(timeIntervalSinceReferenceDate: 100)
        let editedAt = Date(timeIntervalSinceReferenceDate: 200)

        try store.requeueSyncChange(
            entity: .course,
            logicalKey: "course-1",
            operation: .save,
            at: sentAt
        )
        try store.requeueSyncChange(
            entity: .course,
            logicalKey: "course-1",
            operation: .save,
            at: editedAt
        )

        try store.clearPendingSyncChange(
            entity: .course,
            logicalKey: "course-1",
            changedAt: sentAt
        )

        let pending = try #require(store.pendingSyncChanges().first)
        #expect(pending.changedAt == editedAt)

        try store.clearPendingSyncChange(
            entity: .course,
            logicalKey: "course-1",
            changedAt: editedAt
        )
        #expect(try store.pendingSyncChanges().isEmpty)
    }

    @Test("Recent CloudKit changes are prioritized ahead of migration backlog")
    func recentPendingChangesComeFirst() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.requeueSyncChange(
            entity: .source,
            logicalKey: "old-migration-source",
            operation: .save,
            at: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.requeueSyncChange(
            entity: .source,
            logicalKey: "completed-paper-metadata",
            operation: .save,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        #expect(try store.pendingSyncChanges().map(\.logicalKey) == [
            "completed-paper-metadata",
            "old-migration-source",
        ])
    }

    @Test("enqueueMissingSyncableRecords backfills existing rows once")
    func enqueueMissingSyncableRecordsBackfillsExistingRows() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = makeCloudKitArticle(url: "https://example.com/source", title: "Source")
        _ = try store.insertSourceIfNew(&article)
        try store.saveBookMetadata(
            groupName: "Book A",
            title: "Book A",
            author: "Author",
            coverPath: "Books/BookA/cover.jpg"
        )
        try store.saveCourseGroup(
            name: "Course A",
            metadata: CourseMetadata(
                courseCode: "6.001",
                title: "Intro",
                institution: "MIT",
                instructors: "Prof",
                playlistURL: "https://example.com/playlist"
            )
        )
        try store.dismissSource(url: "https://example.com/dismissed", title: "Dismissed")
        try store.saveContextSourceIds([article.id])
        try store.createReviewSession(id: "session-1", topic: "Topic", sourceIDs: [article.id])
        _ = try store.createLearningGoal(
            title: "This Week",
            startAt: Date(timeIntervalSinceReferenceDate: 1_000),
            endAt: Date(timeIntervalSinceReferenceDate: 1_000 + 7 * 24 * 60 * 60),
            sourceIDs: [article.id]
        )

        try store.clearAllPendingSyncChanges()
        try store.clearAllSyncMetadata()

        let enqueued = try store.enqueueMissingSyncableRecords(at: Date(timeIntervalSinceReferenceDate: 1234))
        let pending = try store.pendingSyncChanges()

        #expect(enqueued == 7)
        #expect(pending.count == 7)
        #expect(Set(pending.map(\.entity)) == [
            .source,
            .book,
            .course,
            .dismissedSource,
            .chatContext,
            .reviewSession,
            .learningGoal,
        ])

        let secondPass = try store.enqueueMissingSyncableRecords(at: Date(timeIntervalSinceReferenceDate: 5678))
        #expect(secondPass == 0)
        #expect(try store.pendingSyncChanges().count == 7)
    }

    @Test("A review session too large for one record ships its payload as an asset")
    func oversizedReviewSessionPayloadTravelsAsAsset() throws {
        CloudKitRecordMapper.resetStagedAssetCacheForTesting()
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let sessionID = "memory-2026-09-08"
        // 2026-09-08: a briefing over 166 sources plus the day's exchanges made
        // an encoded payload past CloudKit's 1 MB record cap.
        let briefing = String(repeating: "mitochondria ", count: 60_000)
        #expect(briefing.utf8.count > CloudKitRecordMapper.inlinePayloadByteLimit)
        try store.createReviewSession(
            id: sessionID,
            topic: "Memory review",
            sourceIDs: [],
            kind: .memory,
            briefing: briefing
        )
        let change = try #require(store.pendingSyncChanges().first {
            $0.entity == .reviewSession && $0.logicalKey == sessionID
        })

        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        #expect(record.encryptedValues[.payload] == nil)
        let asset = try #require(record[.payloadAsset] as? CKAsset)
        let assetData = try Data(contentsOf: try #require(asset.fileURL))
        let shipped = try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: assetData)
        #expect(shipped.id == sessionID)
        #expect(shipped.briefing == briefing)
        // A receiver reads the asset as the payload, same as an inline record.
        let descriptor = try CloudKitRecordMapper.descriptor(for: record)
        #expect(descriptor.entity == .reviewSession)
        #expect(descriptor.logicalKey == sessionID)
        #expect(try store.pendingAssetDigests(recordName: change.recordName)[CKRecord.FieldKey.payloadAsset] != nil)

        // Trimmed back under the limit, the next save goes inline again and
        // clears the asset, so no receiver keeps preferring a stale copy.
        try store.setReviewSessionBriefing(sessionID: sessionID, briefing: "short")
        let trimmed = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: store))
        let inline = try #require(trimmed.encryptedValues[.payload] as? Data)
        #expect(try JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: inline).briefing == "short")
        #expect(trimmed[.payloadAsset] == nil)
        #expect(try CloudKitRecordMapper.descriptor(for: trimmed).logicalKey == sessionID)

        // A small session was never touched by any of this.
        try store.createReviewSession(id: "chat-1", topic: "Chat", sourceIDs: [])
        let small = try #require(store.pendingSyncChanges().first {
            $0.entity == .reviewSession && $0.logicalKey == "chat-1"
        })
        let smallRecord = try #require(try CloudKitRecordMapper.makeRecord(for: small, store: store))
        #expect(smallRecord.encryptedValues[.payload] != nil)
        #expect(smallRecord[.payloadAsset] == nil)
    }

    @Test("enqueueMissingSyncableRecords preserves source record age")
    func enqueueMissingSyncableRecordsPreservesSourceRecordAge() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let sourceDate = Date(timeIntervalSinceReferenceDate: 42)
        let fallbackDate = Date(timeIntervalSinceReferenceDate: 9_999)
        var article = makeCloudKitArticle(url: "https://example.com/old-source", title: "Old Source")
        article.dateAdded = sourceDate

        try store.saveSource(article)
        try store.clearAllPendingSyncChanges()
        try store.clearAllSyncMetadata()

        _ = try store.enqueueMissingSyncableRecords(at: fallbackDate)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == article.id
        }

        #expect(change?.changedAt == sourceDate)
    }

    @Test("A hidden doc and a hidden chat travel as records of their own")
    func hiddenDocAndChatRoundTrip() throws {
        let sender = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let receiver = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let doc = ArtifactRecord(
            id: "doc-1", title: "Mito notes", homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(), updatedAt: Date()
        )
        try sender.saveArtifactRecord(doc)
        try receiver.saveArtifactRecord(doc)
        try sender.createReviewSession(id: "chat-1", topic: "Uncouplers", sourceIDs: [])
        try receiver.createReviewSession(id: "chat-1", topic: "Uncouplers", sourceIDs: [])
        try sender.clearAllPendingSyncChanges()
        try receiver.clearAllPendingSyncChanges()

        let docHiddenAt = try #require(try sender.setArtifactHidden("doc-1", hidden: true))
        let chatHiddenAt = try #require(try sender.setReviewSessionHidden("chat-1", hidden: true))
        let changes = try sender.pendingSyncChanges()
        // The hides travel; the doc and the chat themselves are not republished.
        #expect(Set(changes.map(\.entity)) == [.hiddenArtifact, .hiddenReviewSession])
        #expect(changes.allSatisfy { $0.operation == .save })
        for change in changes {
            let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
            #expect(record.recordType == change.entity.recordType)
            let descriptor = try CloudKitRecordMapper.descriptor(for: record)
            #expect(descriptor.entity == change.entity)
            #expect(descriptor.logicalKey == change.logicalKey)
            _ = try CloudKitRecordMapper.apply(record: record, to: receiver)
        }
        #expect(try receiver.loadArtifacts().first { $0.id == "doc-1" }?.hiddenAt == docHiddenAt)
        #expect(try receiver.loadReviewSessionLinks().first { $0.id == "chat-1" }?.hiddenAt == chatHiddenAt)
        // Applied under suppression: the receiver echoes nothing back.
        #expect(try receiver.pendingSyncChanges().isEmpty)
        // The pending list names them for the learner.
        let items = try sender.pendingSyncItemSummaries()
        #expect(items.contains { $0.title == "Mito notes" && $0.kind == "Hidden page" })
        #expect(items.contains { $0.title == "Uncouplers" && $0.kind == "Hidden chat" })

        // Shown again on the sender: a tombstone each, which the receiver applies
        // as its own delete.
        try sender.clearAllPendingSyncChanges()
        #expect(try sender.setArtifactHidden("doc-1", hidden: false) == nil)
        #expect(try sender.setReviewSessionHidden("chat-1", hidden: false) == nil)
        let tombstones = try sender.pendingSyncChanges()
        #expect(Set(tombstones.map(\.entity)) == [.hiddenArtifact, .hiddenReviewSession])
        #expect(tombstones.allSatisfy { $0.operation == .delete })
        try receiver.withoutSyncTracking {
            try receiver.deleteHiddenArtifactRecord(artifactID: "doc-1")
            try receiver.deleteHiddenReviewSessionRecord(sessionID: "chat-1")
        }
        #expect(try receiver.loadArtifacts().first { $0.id == "doc-1" }?.isHidden == false)
        #expect(try receiver.loadReviewSessionLinks().first { $0.id == "chat-1" }?.isHidden == false)
        #expect(try receiver.pendingSyncChanges().isEmpty)
    }

    @Test("A hidden chat's hide leaves with the chat, tombstone included")
    func hiddenChatDeleteTakesTheHide() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        try store.createReviewSession(id: "chat-1", topic: "Uncouplers", sourceIDs: [])
        try store.setReviewSessionHidden("chat-1", hidden: true)
        try store.clearAllPendingSyncChanges()
        try store.deleteReviewSession("chat-1")
        #expect(try store.loadHiddenReviewSessionForSync("chat-1") == nil)
        let tombstones = try store.pendingSyncChanges().filter { $0.operation == .delete }.map(\.entity)
        #expect(Set(tombstones) == [.reviewSession, .hiddenReviewSession])
        // A hide that arrives before its chat waits for it.
        let hiddenAt = Date(timeIntervalSinceReferenceDate: 2_000)
        try store.saveHiddenReviewSessionRecord(CloudKitHiddenReviewSessionPayload(sessionID: "chat-late", hiddenAt: hiddenAt))
        try store.createReviewSession(id: "chat-late", topic: "Late chat", sourceIDs: [])
        #expect(try store.loadReviewSessionLinks().first { $0.id == "chat-late" }?.hiddenAt == hiddenAt)
        #expect(try store.syncBackfillDate(for: .hiddenReviewSession, logicalKey: "chat-late") == hiddenAt)
    }

    @Test("enqueueMissingSyncableRecords preserves visibility record age")
    func enqueueMissingSyncableRecordsPreservesVisibilityRecordAge() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let hiddenDate = Date(timeIntervalSinceReferenceDate: 123)
        let fallbackDate = Date(timeIntervalSinceReferenceDate: 9_999)
        let article = makeCloudKitArticle(url: "https://example.com/hidden-source", title: "Hidden Source")

        try store.saveSource(article)
        try store.saveHiddenSourceRecord(
            CloudKitHiddenSourcePayload(sourceID: article.id, hiddenAt: hiddenDate)
        )
        try store.clearAllPendingSyncChanges()
        try store.clearAllSyncMetadata()

        _ = try store.enqueueMissingSyncableRecords(at: fallbackDate)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .hiddenSource && $0.logicalKey == article.id
        }

        #expect(change?.changedAt == hiddenDate)
    }

    @Test("CloudKit environment rebase queues live records and carries deletions over")
    func cloudKitEnvironmentRebaseQueuesLiveRecords() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let article = makeCloudKitArticle(
            url: "https://example.com/production-publish",
            title: "Publish me"
        )
        try store.saveSource(article)

        let originalDate = Date(timeIntervalSinceReferenceDate: 321)
        try store.saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: .source,
                logicalKey: article.id,
                recordName: CloudKitRecordMapper.recordName(for: .source, logicalKey: article.id),
                systemFieldsData: Data("development-system-fields".utf8),
                userModificationDate: originalDate,
                isDeleted: false
            )
        )
        try store.saveSyncMetadata(
            CloudKitSyncMetadata(
                entity: .dismissedSource,
                logicalKey: "https://example.com/deleted",
                recordName: CloudKitRecordMapper.recordName(
                    for: .dismissedSource,
                    logicalKey: "https://example.com/deleted"
                ),
                systemFieldsData: Data("deleted-development-fields".utf8),
                userModificationDate: originalDate,
                isDeleted: true
            )
        )
        try store.execForTesting("""
            INSERT INTO sync_asset_digests (record_name, field, digest, pending_digest)
            VALUES ('old-record', 'sourcePDFAsset', 'old-digest', NULL);
            INSERT OR REPLACE INTO sync_engine_states (scope, state_serialization)
            VALUES ('private', X'01');
        """)

        let queued = try store.rebaseCloudKitStateForContainerEnvironment()

        // Both records move: the live source as a save, the deleted one as a
        // delete. Dropping the deletion here is what let a record the learner
        // had already removed come back from the other environment's database.
        #expect(queued == 2)
        let pending = try store.pendingSyncChanges()
        let change = try #require(pending.first { $0.entity == .source })
        #expect(change.logicalKey == article.id)
        #expect(change.operation == .save)
        #expect(change.changedAt == originalDate)

        let deletion = try #require(pending.first { $0.entity == .dismissedSource })
        #expect(deletion.logicalKey == "https://example.com/deleted")
        #expect(deletion.operation == .delete)
        #expect(deletion.changedAt == originalDate)

        let loadedMetadata = try store.loadSyncMetadata(entity: .source, logicalKey: article.id)
        let metadata = try #require(loadedMetadata)
        #expect(metadata.systemFieldsData == nil)
        #expect(!metadata.isDeleted)

        // The tombstone survives with only its environment-specific system
        // fields forgotten, so a fetched copy of that record is still refused.
        let loadedTombstone = try store.loadSyncMetadata(
            entity: .dismissedSource,
            logicalKey: "https://example.com/deleted"
        )
        let tombstone = try #require(loadedTombstone)
        #expect(tombstone.isDeleted)
        #expect(tombstone.systemFieldsData == nil)

        var assetDigestCount = -1
        var engineStateCount = -1
        try store.query("SELECT COUNT(*) FROM sync_asset_digests") { statement in
            assetDigestCount = Int(sqlite3_column_int64(statement, 0))
        }
        try store.query("SELECT COUNT(*) FROM sync_engine_states") { statement in
            engineStateCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(assetDigestCount == 0)
        #expect(engineStateCount == 0)

        // A crash after the database commit but before the UserDefaults marker
        // is harmless: retrying the transaction reconstructs the same queue.
        #expect(try store.rebaseCloudKitStateForContainerEnvironment() == 2)
        #expect(try store.pendingSyncChanges().count == 2)
    }

    @Test("A rename from another Mac survives a local reading-progress save")
    func inboundSourceRenameSurvivesLocalReadingProgress() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://research.contrary.com/report/progress-conflict",
            title: "Reading Time",
            sourceType: .article,
            id: "progress-conflict"
        )
        article.content = "Body text."
        article.state = .ready
        try store.saveSource(article)
        try store.clearPendingSyncChange(entity: .source, logicalKey: article.id)

        // This Mac only opened the article: a scroll offset, not an edit.
        try store.updateSourceReadingLocator(
            sourceID: article.id,
            locator: "{\"webScrollFraction\":0.42}"
        )
        #expect(try store.hasPendingTutorOnlySyncChange(
            entity: .source,
            logicalKey: article.id
        ))

        // The other Mac renamed it and published first.
        var renamed = article
        renamed.title = "The Anti-Aging Therapeutics Boom"
        let record = try makeInboundRecord(
            entity: .source,
            logicalKey: article.id,
            payload: CloudKitSourcePayload(article: renamed)
        )

        let applied = try #require(
            try CloudKitRecordMapper.mergeSourceProgressServerConflict(
                record: record,
                to: store
            )
        )
        let merged = try #require(try store.loadSourceForSync(article.id))
        #expect(merged.title == "The Anti-Aging Therapeutics Boom")
        #expect(merged.readingPositionLocator == "{\"webScrollFraction\":0.42}")
        // The merged row differs from the snapshot just adopted, so it has to
        // go back up — otherwise the other Mac never learns this position.
        #expect(applied.requiresRepublish)
    }

    @Test("A local edit still outranks an inbound source record")
    func pendingSourceEditKeepsEditorialScope() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        var article = StudioArticle(
            url: "https://example.com/editorial-scope",
            title: "Original title",
            sourceType: .article,
            id: "editorial-scope"
        )
        article.content = "Body text."
        article.state = .ready
        try store.saveSource(article)

        // A rename made here, then an incidental scroll on top of it. The
        // combined row stays editorial, so the engine keeps the existing skip
        // and this Mac's own rename is not thrown away.
        article.title = "Renamed here"
        try store.saveSource(article)
        try store.updateSourceReadingLocator(
            sourceID: article.id,
            locator: "{\"webScrollFraction\":0.1}"
        )
        #expect(try !store.hasPendingTutorOnlySyncChange(
            entity: .source,
            logicalKey: article.id
        ))
    }

}

private func makeInboundRecord<Payload: Encodable>(
    entity: CloudKitSyncEntity,
    logicalKey: String,
    payload: Payload
) throws -> CKRecord {
    let record = CKRecord(
        recordType: entity.recordType,
        recordID: CloudKitRecordMapper.recordID(for: entity, logicalKey: logicalKey)
    )
    record.encryptedValues[.payload] = try JSONEncoder().encode(payload) as NSData
    record.encryptedValues[.userModificationDate] = Date() as NSDate
    return record
}

private func makeLegacyInboundSourceRecord(article: StudioArticle) throws -> CKRecord {
    let current = try JSONEncoder().encode(CloudKitSourcePayload(article: article))
    var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
    object.removeValue(forKey: "payloadVersion")
    let record = CKRecord(
        recordType: CloudKitSyncEntity.source.recordType,
        recordID: CloudKitRecordMapper.recordID(for: .source, logicalKey: article.id)
    )
    record.encryptedValues[.payload] = try JSONSerialization.data(withJSONObject: object) as NSData
    record.encryptedValues[.userModificationDate] = Date() as NSDate
    return record
}
