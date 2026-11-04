import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Spend control for background AI (2026-09-24): cleaner v19 re-queued about
/// 1,380 sources to fix about 280 and each clean-up queued a paid Listen pass
/// behind it — $27.50 in an afternoon on the learner's own key. What has to
/// hold: a bulk re-queue past the threshold waits for the learner and can be
/// run whole, run for the affected sources only, or skipped; its estimate comes
/// from the ledger or is unknown; the daily cap counts only background tasks,
/// own-key calls included, within one local day; and a clean-up commit queues
/// no Listen preparation the learner has not asked for (the last is in
/// `SourcePersistenceTests.cleanupCommitDoesNotQueueListenPreparation`).
@Suite("Background AI spend control", .cardWordingPasses)
struct BackgroundAISpendTests {

    // MARK: - Needed or optional

    @Test("Activity tells the spend the library needs from the nice-to-haves and what the learner asked for")
    func usageNeedSeparatesNeededFromOptional() {
        #expect(AIUsageTaskNeed.of(taskKey: "embedding") == .needed)
        #expect(AIUsageTaskNeed.of(taskKey: "paper_metadata") == .needed)
        #expect(AIUsageTaskNeed.of(taskKey: "notebook_cover") == .optional)
        #expect(AIUsageTaskNeed.of(taskKey: "card_drafting") == .optional)
        #expect(AIUsageTaskNeed.of(taskKey: "notebook_naming") == .optional)
        // Written ahead of time, and only then: its Activity row has a switch.
        #expect(AIUsageTaskNeed.of(taskKey: "realtime_review_preparation") == .optional)
        #expect(AIUsageTaskNeed.of(taskKey: "chat_title") == .needed)
        #expect(AIUsageTaskNeed.of(taskKey: "chat_history_compaction") == .needed)
        #expect(AIUsageTaskNeed.of(taskKey: "chat") == .requested)
        #expect(AIUsageTaskNeed.of(taskKey: "chat_image") == .requested)
        #expect(AIUsageTaskNeed.of(taskKey: "never_heard_of_it") == .requested)
    }

    @Test("Only background work is ever needed or optional")
    func learnerStartedTasksAreRequested() {
        for task in AITask.allCases where !task.isBackgroundWork {
            #expect(task.usageNeed == .requested || task.usageNeed == .needed, "\(task.rawValue)")
        }
        for task in AITask.allCases where task.usageNeed == .optional {
            #expect(task.isBackgroundWork, "\(task.rawValue) runs on its own, so it counts as background")
        }
    }

    // MARK: - Fixtures

    /// `count` ready articles at an older cleaner version, as a library looks
    /// before a cleaner bump. `saveSource` already queues each once; the
    /// historical re-queue re-arms every row.
    private static func libraryAwaitingReclean(count: Int) throws -> (KnowledgeStore, [String]) {
        let store = try KnowledgeStore(inMemory: true)
        var ids: [String] = []
        for index in 0..<count {
            var article = StudioArticle(
                url: "https://example.com/reclean/\(index)",
                title: "Reclean \(index)",
                sourceType: .article,
                id: "reclean-\(index)"
            )
            article.content = "Reclean \(index)\n\nThe body of article \(index)."
            article.state = .ready
            try store.saveSource(article)
            ids.append(article.id)
        }
        return (store, ids)
    }

    private static func insertUsage(
        _ store: KnowledgeStore,
        id: String,
        task: String,
        subjectID: String? = nil,
        createdAt: Date,
        providerCost: Double?,
        estimatedCost: Double? = nil,
        ownKey: Bool = false,
        serverLedgerID: Int? = nil
    ) throws {
        func sql(_ value: Double?) -> String { value.map { String($0) } ?? "NULL" }
        let subject = subjectID.map { "'\($0)'" } ?? "NULL"
        let ledger = serverLedgerID.map(String.init) ?? "NULL"
        try store.execForTesting("""
            INSERT INTO ai_usage_events (
                id, provider, model, operation, task, subject_id, created_at,
                input_tokens, output_tokens, provider_reported_cost, estimated_cost,
                currency, own_key, server_ledger_id
            ) VALUES (
                '\(id)', 'openrouter', 'openai/gpt-5.6-luna', 'chat_completion', '\(task)', \(subject),
                \(createdAt.timeIntervalSinceReferenceDate), 1000, 500, \(sql(providerCost)), \(sql(estimatedCost)),
                'USD', \(ownKey ? 1 : 0), \(ledger)
            )
        """)
    }

    // MARK: - The threshold gate

    @Test("The threshold is the largest batch one learner action queues")
    func thresholdMatchesTheLargestLearnerBatch() {
        #expect(BackgroundAIBulkQueue.learnerDecisionThreshold == MCPToolRegistry.maxBatchSourceItems)
    }

    @Test("A re-queue at the threshold drains as before; one past it waits for the learner")
    func bulkRequeueAboveThresholdIsHeld() throws {
        let threshold = BackgroundAIBulkQueue.learnerDecisionThreshold

        let (small, _) = try Self.libraryAwaitingReclean(count: threshold)
        _ = try small.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        #expect(try small.pendingBackgroundAIBulkJobs().isEmpty)
        #expect(try small.canonicalContentCleanupCandidates(limit: 500).count == threshold)

        let (large, _) = try Self.libraryAwaitingReclean(count: threshold + 1)
        let queued = try large.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        #expect(queued == threshold + 1, "the rows are queued; only the drain waits")
        let jobs = try large.pendingBackgroundAIBulkJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.queue == .canonicalCleanup)
        #expect(jobs.first?.heldSourceCount == threshold + 1)
        #expect(jobs.first?.affectedSourceCount == nil)
        #expect(jobs.first?.canLimitToAffected == false)
        #expect(try large.canonicalContentCleanupCandidates(limit: 500).isEmpty)
    }

    @Test("A source the learner adds while a re-queue waits is still cleaned")
    func pendingIngestionIsNeverHeld() throws {
        let (store, _) = try Self.libraryAwaitingReclean(count: BackgroundAIBulkQueue.learnerDecisionThreshold + 5)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        var added = StudioArticle(
            url: "https://example.com/just-added",
            title: "Just added",
            sourceType: .article,
            id: "just-added"
        )
        // Staged the way ingestion hands an article to the clean-up: raw text
        // and a version-0 preparation, content still to come. A queued
        // article saved with `content` alone is never queued for clean-up at
        // all, which is what this fixture tested by mistake at first.
        added.stageArticleContentCleanup(raw: "Just added\n\nA new article.")
        added.state = .queued
        try store.saveSource(added)
        let candidates = try store.canonicalContentCleanupCandidates(limit: 500)
        #expect(candidates.map(\.sourceID) == ["just-added"])
    }

    @Test("Run all releases every held source to the drain")
    func runAllReleasesEverything() throws {
        let count = BackgroundAIBulkQueue.learnerDecisionThreshold + 10
        let (store, _) = try Self.libraryAwaitingReclean(count: count)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let job = try #require(try store.pendingBackgroundAIBulkJobs().first)
        #expect(throws: (any Error).self) {
            _ = try store.decideBackgroundAIBulkJob(id: job.id, decision: .runAffected)
        }
        let outcome = try store.decideBackgroundAIBulkJob(id: job.id, decision: .runAll)
        #expect(outcome.releasedCount == count)
        #expect(outcome.droppedCount == 0)
        #expect(try store.pendingBackgroundAIBulkJobs().isEmpty)
        #expect(try store.canonicalContentCleanupCandidates(limit: 500).count == count)
    }

    @Test("Run affected keeps only the sources the change names; skip drops them all")
    func runAffectedAndSkip() throws {
        let count = BackgroundAIBulkQueue.learnerDecisionThreshold + 10
        let (store, ids) = try Self.libraryAwaitingReclean(count: count)
        let affected = Array(ids.prefix(3))
        let list = affected.map { "'\($0)'" }.joined(separator: ", ")
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .matching(sql: "s.id IN (\(list))")
        )
        let job = try #require(try store.pendingBackgroundAIBulkJobs().first)
        #expect(job.heldSourceCount == count)
        #expect(job.affectedSourceCount == 3)
        let outcome = try store.decideBackgroundAIBulkJob(id: job.id, decision: .runAffected)
        #expect(outcome.releasedCount == 3)
        #expect(outcome.droppedCount == count - 3)
        #expect(Set(try store.canonicalContentCleanupCandidates(limit: 500).map(\.sourceID)) == Set(affected))

        let (skipped, _) = try Self.libraryAwaitingReclean(count: count)
        _ = try skipped.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let skippedJob = try #require(try skipped.pendingBackgroundAIBulkJobs().first)
        let skippedOutcome = try skipped.decideBackgroundAIBulkJob(id: skippedJob.id, decision: .skip)
        #expect(skippedOutcome.droppedCount == count)
        #expect(try skipped.canonicalContentCleanupQueueCount() == 0)
        #expect(try skipped.pendingBackgroundAIBulkJobs().isEmpty)
    }

    @Test("Re-fetching one held source releases it without a decision")
    func singleSourceRequeueReleasesItsHold() throws {
        let (store, _) = try Self.libraryAwaitingReclean(count: BackgroundAIBulkQueue.learnerDecisionThreshold + 1)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        #expect(try store.canonicalContentCleanupCandidates(limit: 500).isEmpty)
        var refetched = try #require(try store.loadSourceForSync("reclean-7"))
        refetched.content = "Reclean 7\n\nThe body, fetched again."
        try store.saveSource(refetched)
        #expect(try store.canonicalContentCleanupCandidates(limit: 500).map(\.sourceID) == ["reclean-7"])
        #expect(try store.pendingBackgroundAIBulkJobs().first?.heldSourceCount
            == BackgroundAIBulkQueue.learnerDecisionThreshold)
    }

    // MARK: - Stopping a released run (cancel_ai_work)

    /// The drain finishing a source takes its queue row; this does the same.
    private static func drain(_ store: KnowledgeStore, _ ids: some Sequence<String>) throws {
        let list = ids.map { "'\($0)'" }.joined(separator: ", ")
        try store.execForTesting("DELETE FROM canonical_content_cleanup_queue WHERE source_id IN (\(list))")
    }

    @Test("Stopping a released run holds what the drain has not reached, for the learner to decide again")
    func stoppingARunHoldsWhatIsLeft() throws {
        let count = BackgroundAIBulkQueue.learnerDecisionThreshold + 10
        let (store, ids) = try Self.libraryAwaitingReclean(count: count)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let job = try #require(try store.pendingBackgroundAIBulkJobs().first)
        _ = try store.decideBackgroundAIBulkJob(id: job.id, decision: .runAll)
        #expect(try store.runningBackgroundAIBulkJobs().map(\.remainingSourceCount) == [count])

        try Self.drain(store, ids.prefix(4))
        let running = try #require(try store.runningBackgroundAIBulkJobs().first)
        #expect(running.id == job.id)
        #expect(running.decision == .runAll)
        #expect(running.remainingSourceCount == count - 4)

        let stopped = try store.stopBackgroundAIBulkJob(id: job.id)
        #expect(stopped.heldJobID == job.id)
        #expect(stopped.heldSourceCount == count - 4)
        #expect(try store.runningBackgroundAIBulkJobs().isEmpty)
        #expect(try store.canonicalContentCleanupCandidates(limit: 500).isEmpty, "the rest waits again")
        let held = try #require(try store.pendingBackgroundAIBulkJobs().first)
        #expect(held.id == job.id)
        #expect(held.heldSourceCount == count - 4)

        // Deciding again works as the first time did.
        let skipped = try store.decideBackgroundAIBulkJob(id: job.id, decision: .skip)
        #expect(skipped.droppedCount == count - 4)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("A run the drain finished is no longer listed, and stopping it holds nothing")
    func finishedRunIsRetired() throws {
        let count = BackgroundAIBulkQueue.learnerDecisionThreshold + 3
        let (store, ids) = try Self.libraryAwaitingReclean(count: count)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let job = try #require(try store.pendingBackgroundAIBulkJobs().first)
        _ = try store.decideBackgroundAIBulkJob(id: job.id, decision: .runAll)
        try Self.drain(store, ids)
        #expect(try store.runningBackgroundAIBulkJobs().isEmpty)
        let stopped = try store.stopBackgroundAIBulkJob(id: job.id)
        #expect(stopped.heldJobID == nil)
        #expect(stopped.heldSourceCount == 0)
        #expect(try store.pendingBackgroundAIBulkJobs().isEmpty)

        // Only a run can be stopped: a skipped job has nothing draining.
        let (skipped, _) = try Self.libraryAwaitingReclean(count: count)
        _ = try skipped.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let skippedJob = try #require(try skipped.pendingBackgroundAIBulkJobs().first)
        _ = try skipped.decideBackgroundAIBulkJob(id: skippedJob.id, decision: .skip)
        #expect(throws: (any Error).self) {
            _ = try skipped.stopBackgroundAIBulkJob(id: skippedJob.id)
        }
    }

    @Test("A stopped run joins the queue's newer pending re-queue rather than opening a second")
    func stoppedRunFoldsIntoNewerPendingJob() throws {
        let threshold = BackgroundAIBulkQueue.learnerDecisionThreshold
        let count = 2 * threshold + 10
        let (store, ids) = try Self.libraryAwaitingReclean(count: count)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "first bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let first = try #require(try store.pendingBackgroundAIBulkJobs().first)
        _ = try store.decideBackgroundAIBulkJob(id: first.id, decision: .runAll)

        // A second bulk change re-arms part of the queue while the first run
        // drains: those sources are the new job's, and leave the old run.
        let rearmed = Array(ids.prefix(threshold + 5))
        let list = rearmed.map { "'\($0)'" }.joined(separator: ", ")
        _ = try store.holdingBulkRequeue(
            into: .canonicalCleanup,
            reason: "second bump",
            affectedSources: .unknown(because: "a fixture")
        ) {
            // After the first hold, and before the second one's `held_at`.
            usleep(2_000)
            let now = Date().timeIntervalSinceReferenceDate
            try store.execForTesting("""
                UPDATE canonical_content_cleanup_queue
                SET enqueued_at = \(now)
                WHERE source_id IN (\(list))
            """)
            return rearmed.count
        }
        let second = try #require(try store.pendingBackgroundAIBulkJobs().first)
        #expect(second.id != first.id)
        #expect(second.heldSourceCount == rearmed.count)
        #expect(try store.runningBackgroundAIBulkJobs().first?.remainingSourceCount == count - rearmed.count)

        let stopped = try store.stopBackgroundAIBulkJob(id: first.id)
        #expect(stopped.heldJobID == second.id)
        #expect(stopped.heldSourceCount == count)
        let pending = try store.pendingBackgroundAIBulkJobs()
        #expect(pending.map(\.id) == [second.id])
        #expect(pending.first?.heldSourceCount == count)
        #expect(try store.runningBackgroundAIBulkJobs().isEmpty)
        #expect(try store.canonicalContentCleanupCandidates(limit: 500).isEmpty)
    }

    // MARK: - The estimate

    @Test("The estimate averages the task's recent per-source cost, and is unknown without history")
    func estimateFromTheLedger() throws {
        let (store, _) = try Self.libraryAwaitingReclean(count: BackgroundAIBulkQueue.learnerDecisionThreshold + 1)
        _ = try store.enqueueHistoricalCanonicalContentCleanup(
            reason: "test bump",
            affectedSources: .unknown(because: "a fixture")
        )
        let noHistory = try #require(try store.pendingBackgroundAIBulkJobs().first)
        #expect(noHistory.costSample == .empty)
        #expect(noHistory.estimatedUSD == nil)
        #expect(BackgroundAIBulkJob.costText(noHistory.estimatedUSD) == "cost unknown")

        let now = Date()
        let task = AITask.paperNarrationPreparation.rawValue
        // Source a: two calls, $0.03 in all. Source b: one call, $0.01.
        try Self.insertUsage(store, id: "a1", task: task, subjectID: "a", createdAt: now.addingTimeInterval(-3600), providerCost: 0.02)
        try Self.insertUsage(store, id: "a2", task: task, subjectID: "a", createdAt: now.addingTimeInterval(-3500), providerCost: nil, estimatedCost: 0.01)
        try Self.insertUsage(store, id: "b1", task: task, subjectID: "b", createdAt: now.addingTimeInterval(-3400), providerCost: 0.01, ownKey: true)
        // Left out: an unpriced source, another task, the proxy's mirror of a
        // call already counted, and a call older than the window.
        try Self.insertUsage(store, id: "c1", task: task, subjectID: "c", createdAt: now.addingTimeInterval(-3300), providerCost: nil)
        try Self.insertUsage(store, id: "d1", task: AITask.chat.rawValue, subjectID: "d", createdAt: now.addingTimeInterval(-3200), providerCost: 5)
        try Self.insertUsage(store, id: "a1-mirror", task: task, subjectID: "a", createdAt: now.addingTimeInterval(-3600), providerCost: 0.02, serverLedgerID: 1)
        try Self.insertUsage(store, id: "old", task: task, subjectID: "e", createdAt: now.addingTimeInterval(-40 * 86_400), providerCost: 9)

        let job = try #require(try store.pendingBackgroundAIBulkJobs(now: now).first)
        #expect(job.costSample.pricedSourceCount == 2)
        #expect(job.costSample.unpricedSourceCount == 1)
        let perSource = try #require(job.costSample.perSourceUSD)
        #expect(abs(perSource - 0.02) < 1e-9)
        let estimate = try #require(job.estimatedUSD)
        #expect(abs(estimate - 0.02 * Double(job.heldSourceCount)) < 1e-9)
    }

    // MARK: - The daily cap

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    @Test("Today's spend is the background tasks' own rows of this local day, own key included")
    func dailySpendAcrossALocalDayBoundary() throws {
        let store = try KnowledgeStore(inMemory: true)
        let calendar = Self.calendar("Europe/Amsterdam")
        let lateYesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 23, minute: 30)))
        let earlyToday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 30)))
        let task = AITask.paperTextToSpeechPreparation.rawValue
        try Self.insertUsage(store, id: "yesterday", task: task, createdAt: lateYesterday, providerCost: 4)
        try Self.insertUsage(store, id: "today-own-key", task: task, createdAt: earlyToday, providerCost: 1.25, ownKey: true)
        try Self.insertUsage(store, id: "today-balance", task: AITask.paperMetadata.rawValue, createdAt: earlyToday, providerCost: nil, estimatedCost: 0.5)
        try Self.insertUsage(store, id: "today-chat", task: AITask.chat.rawValue, createdAt: earlyToday, providerCost: 7)
        try Self.insertUsage(store, id: "today-mirror", task: task, createdAt: earlyToday, providerCost: 1.25, serverLedgerID: 42)

        let today = BackgroundAIDailyCap.localDay(containing: earlyToday, calendar: calendar)
        #expect(today.start == calendar.startOfDay(for: earlyToday))
        #expect(abs(try store.backgroundAISpendUSD(from: today.start, to: today.end) - 1.75) < 1e-9)
        let yesterday = BackgroundAIDailyCap.localDay(containing: lateYesterday, calendar: calendar)
        #expect(yesterday.end == today.start)
        #expect(abs(try store.backgroundAISpendUSD(from: yesterday.start, to: yesterday.end) - 4) < 1e-9)
    }

    @Test("A day that loses an hour to daylight saving is still one local day")
    func localDayAcrossDaylightSaving() throws {
        let calendar = Self.calendar("Europe/Amsterdam")
        let springForward = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let day = BackgroundAIDailyCap.localDay(containing: springForward, calendar: calendar)
        #expect(day.duration == 23 * 3600)
    }

    @Test("The cap is off without a setting, and reached at or above it")
    func capStatusArithmetic() {
        #expect(BackgroundAIDailyCap.status(spentUSD: 100, capUSD: nil) == .off)
        #expect(BackgroundAIDailyCap.status(spentUSD: 4.99, capUSD: 5) == .under(spentUSD: 4.99, capUSD: 5))
        #expect(BackgroundAIDailyCap.status(spentUSD: 5, capUSD: 5).isReached)
        #expect(BackgroundAIDailyCap.status(spentUSD: 27.5, capUSD: 5).isReached)
    }

    @Test("The learner is told once per local day, and the next day spends again")
    func budgetNoticeOncePerDay() async throws {
        let suite = "BackgroundAISpendTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Self.calendar("America/Los_Angeles")

        let unset = BackgroundAIBudget(defaults: defaults, calendar: calendar) { _ in 99 }
        let off = await unset.check()
        #expect(off.status == .off)
        #expect(off.allowsBackgroundSpend, "no cap by default")

        defaults.set(5.0, forKey: BackgroundAIDailyCap.preferenceKey)
        let spent = SpendByDay()
        let budget = BackgroundAIBudget(defaults: defaults, calendar: calendar) { day in
            await spent.value(for: day.start)
        }
        let dayOne = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15)))
        let dayTwo = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 0, minute: 5)))
        await spent.set(6, for: calendar.startOfDay(for: dayOne))

        let first = await budget.check(now: dayOne)
        #expect(!first.allowsBackgroundSpend)
        #expect(first.isFirstNoticeToday)
        let second = await budget.check(now: dayOne.addingTimeInterval(600))
        #expect(!second.allowsBackgroundSpend)
        #expect(!second.isFirstNoticeToday, "told once")

        let nextDay = await budget.check(now: dayTwo)
        #expect(nextDay.allowsBackgroundSpend, "a new local day starts from zero")
        #expect(nextDay.day.start == first.day.end)
    }

    @Test("An unreadable ledger keeps the drains paused while a cap is set")
    func unreadableLedgerFailsClosed() async throws {
        let suite = "BackgroundAISpendTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5.0, forKey: BackgroundAIDailyCap.preferenceKey)
        struct Unreadable: Error {}
        let budget = BackgroundAIBudget(defaults: defaults, calendar: Self.calendar("UTC")) { _ in throw Unreadable() }
        let check = await budget.check()
        #expect(!check.allowsBackgroundSpend)
        #expect(check.errorMessage != nil)
    }

    // MARK: - What counts

    @Test("Background card drafting asks the gate before it runs and sends nothing once it says no; the learner's Make Cards is never paused")
    func backgroundCardDraftingAsksTheGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoCardsGate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = StorageService(storeRoot: root)
        let text = "Uncoupling proteins let protons leak back without making ATP, and the energy is released as heat."
        var article = StudioArticle(url: "https://example.com/gate", title: "Gate", sourceType: .article, id: "src-gate")
        article.content = text
        article.state = .ready
        article.readAt = Date().addingTimeInterval(-3_600)
        try await storage.saveSource(article)
        let hash = PaperContentPreparationService.sha256(text)
        try await storage.replaceSourceIdeas(sourceID: "src-gate", contentHash: hash, ideas: [
            SourceIdea(id: SourceIdea.id(sourceID: "src-gate", contentHash: hash, index: 0), sourceID: "src-gate",
                       statement: "Uncoupling releases the energy as heat.", recallNote: "", contentHash: hash, sortIndex: 0),
        ])
        let drafter = GateRecordingDrafter()
        let route = CardDraftingRoute(
            writing: NotebookWritingRoute(
                provider: .openRouter, model: "test/card-drafter", writerInputBudget: nil, condenserInputBudget: nil,
                inputUSDPerMillion: 100, outputUSDPerMillion: 200
            ),
            inputBudget: { _ in nil }
        )
        let pass = AutomaticCardDraftingPass(
            storage: storage,
            backend: drafter,
            route: { route },
            spendAllowed: { false },
            isOn: { true },
            newCardsPerDay: { 10 },
            neededSoonSourceIDs: { [] },
            defaults: defaults
        )
        let report = await pass.run()
        #expect(drafter.calls == 0, "nothing was sent past the cap")
        #expect(report.waiting == 1)
        #expect(report.notes.contains { $0.contains("background AI limit") })

        // The gates themselves: the background one asks, the learner's never pauses.
        #expect(await CardDraftingSpendGate.learnerStarted.allowsSpend())
        #expect(await CardDraftingSpendGate.background({ false }).allowsSpend() == false)
        #expect(AITask.cardDrafting.isBackgroundWork, "the ledger counts both")
    }

    @Test("Chat, reviews and what the learner starts are exempt; clean-up and preparation count")
    func exemptTasks() {
        for task in [AITask.chat, .reviewGrading, .mobileReview, .mobileVoiceAgent, .deepResearch,
                     .cohortSessionPlan, .explainerWriting, .walkthroughWriting,
                     .walkthroughAnimation, .courseCurriculumPlan, .courseLessonWriting,
                     .lectureQuizWriting, .courseQuizWriting, .courseTextbookReadings] {
            #expect(!task.isBackgroundWork, "\(task.rawValue) is exempt")
            #expect(!AITask.backgroundWorkTaskIDs.contains(task.rawValue))
        }
        for task in [AITask.paperNarrationPreparation, .paperTextToSpeechPreparation, .paperMetadata,
                     .articleMetadata, .sourceIdeaExtraction, .sourceClassification, .transcriptFormatting] {
            #expect(task.isBackgroundWork, "\(task.rawValue) counts")
        }
        for queue in BackgroundAIBulkQueue.allCases {
            #expect(queue.task.isBackgroundWork)
        }
    }

    // MARK: - Schema 135

    @Test("Schema 135 adds the two hold tables to a 134 store and holds nothing already queued")
    func version135CreatesTheHoldTables() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundAISpendMigration_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = BackgroundAIBulkQueue.learnerDecisionThreshold + 20
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            for index in 0..<count {
                var article = StudioArticle(
                    url: "https://example.com/v135/\(index)",
                    title: "V135 \(index)",
                    sourceType: .article
                )
                article.content = "V135 \(index)\n\nBody."
                article.state = .ready
                try store.saveSource(article)
            }
            try store.execForTesting("DROP TABLE IF EXISTS background_ai_bulk_job_sources")
            try store.execForTesting("DROP TABLE IF EXISTS background_ai_bulk_jobs")
            try store.execForTesting("PRAGMA user_version = 134")
        }

        let migrated = try KnowledgeStore(storeDirectory: root)
        var version: Int32 = 0
        try migrated.query("PRAGMA user_version") { stmt in version = sqlite3_column_int(stmt, 0) }
        #expect(version == KnowledgeStore.schemaVersion)
        #expect(KnowledgeStore.schemaVersion == 174)
        #expect(try migrated.pendingBackgroundAIBulkJobs().isEmpty, "nothing is backfilled")
        #expect(try migrated.canonicalContentCleanupCandidates(limit: 500).count == count,
                "rows an older re-queue left keep draining")
        #expect(try migrated.loadSources().count == count)
    }

    @Test("A failed schema-135 step leaves the store at 134 with its data")
    func version135RollsBackOnFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundAISpendRollback_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            var article = StudioArticle(url: "https://example.com/v135-rollback", title: "Rollback", sourceType: .article)
            article.content = "Rollback\n\nBody."
            article.state = .ready
            try store.saveSource(article)
        }
        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DROP TABLE IF EXISTS background_ai_bulk_job_sources", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DROP TABLE IF EXISTS background_ai_bulk_jobs", nil, nil, nil) == SQLITE_OK)
        // A same-named table of another shape makes the step fail.
        #expect(sqlite3_exec(database, "CREATE TABLE background_ai_bulk_jobs (incompatible TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 134", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) { _ = try KnowledgeStore(storeDirectory: root) }

        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        var storedVersion: Int32 = 0
        if sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            storedVersion = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        #expect(storedVersion == 134)
        var kept = 0
        if sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM sources", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            kept = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        #expect(kept == 1, "the library survives the failed migration")
    }
}

private actor SpendByDay {
    private var values: [Date: Double] = [:]
    func set(_ value: Double, for day: Date) { values[day] = value }
    func value(for day: Date) -> Double { values[day] ?? 0 }
}

/// Counts the drafting calls that reach it, and answers none.
private final class GateRecordingDrafter: CardDraftingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func draftCards(system: String, user: String, maxTokens: Int, source: AIUsageSource, route: CardDraftingRoute) async throws -> [CardDraftingModelCard] {
        lock.withLock { count += 1 }
        return []
    }
}
