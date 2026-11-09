import CloudKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

private func makeMemoryItem(
    id: String = "memory-item-1",
    sourceID: String = "source-1",
    additionalSourceIDs: [String] = [],
    learnerContext: String? = "Previously confused fluency with durable learning.",
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    status: MemoryItemStatus = .active
) -> MemoryItem {
    let anchoredSourceIDs = [sourceID] + additionalSourceIDs
    return MemoryItem(
        id: id,
        kind: .concept,
        target: "Explain why retrieval strengthens future recall.",
        rubricJSON: #"{"criteria":["distinguishes retrieval from rereading","explains effort"]}"#,
        learnerContext: learnerContext,
        goalID: "goal-1",
        status: status,
        sources: anchoredSourceIDs.enumerated().map { index, anchoredSourceID in
            MemoryItemSource(
                id: index == 0 ? "anchor-\(id)" : "anchor-\(id)-\(index)",
                memoryItemID: id,
                sourceID: anchoredSourceID,
                locatorJSON: #"{"kind":"text","start":120,"end":208}"#,
                excerpt: "Effortful retrieval changes the probability of later recall.",
                sourceSHA256: String(repeating: "a", count: 64),
                sortIndex: index
            )
        },
        createdAt: createdAt,
        updatedAt: createdAt
    )
}

private func makeMemoryAttempt(
    id: String = "attempt-1",
    itemID: String = "memory-item-1",
    attemptedAt: Date = Date(timeIntervalSinceReferenceDate: 2_000),
    rating: MemoryScheduleRating = .good
) -> MemoryAttempt {
    MemoryAttempt(
        id: id,
        memoryItemID: itemID,
        attemptType: .review,
        prompt: "Teach the retrieval effect without using the phrase itself.",
        learnerAnswer: "Recall is productive effort that makes another recall more likely.",
        feedback: "You explained the mechanism and distinguished it from rereading.",
        score: 0.86,
        scheduleRating: rating,
        gradeState: .graded,
        evidenceJSON: #"{"sourceAnchorIDs":["anchor-memory-item-1"]}"#,
        attemptedAt: attemptedAt,
        modelProvider: "openrouter",
        modelID: "configured-model",
        modelMetadataJSON: #"{"responseID":"response-1"}"#
    )
}

/// One `.good` review that leaves `item` due again at `dueAt`. An item no graded
/// review has reached is new and never due (scheduler version 2), so a due-query
/// fixture needs one; a first `.good` sets 2 days × 2.1, so it is dated 4.2 days
/// before.
private func recordReview(_ store: KnowledgeStore, of item: MemoryItem, dueAt: Date) throws {
    try store.recordMemoryAttempt(makeMemoryAttempt(
        id: "review-\(item.id)",
        itemID: item.id,
        attemptedAt: dueAt.addingTimeInterval(-4.2 * MemoryTutorScheduler.secondsPerDay)
    ))
}

private func memoryPayloadData(from record: CKRecord) throws -> Data {
    if let data = record.encryptedValues[.payload] as? Data { return data }
    if let data = record.encryptedValues[.payload] as? NSData { return data as Data }
    throw KnowledgeStoreError.invalidData("CloudKit test record has no payload data.")
}

@Suite("Memory Tutor Persistence")
struct MemoryTutorPersistenceTests {

    @Test("Memory item persists every relationship and starts new, eligible the next local day")
    func itemRoundTripAndInitialSchedule() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()

        try store.saveMemoryItem(item)

        #expect(try store.loadMemoryItem(item.id) == item)
        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(schedule.isNew)
        #expect(schedule.dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: item.createdAt))
        #expect(schedule.repetitionCount == 0)
        #expect(schedule.algorithmVersion == MemoryTutorScheduler.algorithmVersion)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .memoryItem && $0.logicalKey == item.id && $0.operation == .save
        })
    }

    @Test("Memory items require object rubrics and at least one grounded anchor")
    func itemValidationFailsClosed() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let arrayRubric = MemoryItem(
            id: item.id,
            kind: item.kind,
            target: item.target,
            rubricJSON: #"["criterion"]"#,
            sources: item.sources,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
        #expect(throws: (any Error).self) {
            try store.saveMemoryItem(arrayRubric)
        }

        let anchorless = MemoryItem(
            id: "anchorless",
            kind: .concept,
            target: "A target",
            rubricJSON: #"{"criteria":[]}"#,
            sources: []
        )
        #expect(throws: (any Error).self) {
            try store.saveMemoryItem(anchorless)
        }
        #expect(try store.loadAllMemoryItemIDs().isEmpty)
    }

    @Test("Attempts are immutable and identical replay is idempotent")
    func immutableAttemptReplay() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let attempt = makeMemoryAttempt()
        try store.saveMemoryItem(item)

        #expect(try store.recordMemoryAttempt(attempt))
        #expect(try store.recordMemoryAttempt(attempt) == false)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id) == [attempt])

        let conflicting = MemoryAttempt(
            id: attempt.id,
            memoryItemID: attempt.memoryItemID,
            prompt: attempt.prompt,
            learnerAnswer: attempt.learnerAnswer,
            feedback: "Different immutable feedback",
            score: attempt.score,
            scheduleRating: attempt.scheduleRating,
            gradeState: .graded,
            attemptedAt: attempt.attemptedAt
        )
        #expect(throws: (any Error).self) {
            try store.recordMemoryAttempt(conflicting)
        }
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id) == [attempt])
    }

    @Test("Prior struggle projection is structured, deterministic, and bounded")
    func structuredPriorStruggleProjection() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        try store.saveMemoryItem(item)

        let hard = MemoryAttempt(
            id: "hard-struggle",
            memoryItemID: item.id,
            prompt: "Explain the mechanism.",
            learnerAnswer: "It feels more fluent.",
            feedback: "You described familiarity, not retrieval.",
            score: 0.45,
            scheduleRating: .hard,
            gradeState: .graded,
            evidenceJSON: #"{"retrieval_quality":"hinted","missing_rubric_elements":["retrieval changes later recall"],"misconception":"fluency equals learning"}"#,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        let again = MemoryAttempt(
            id: "again-struggle",
            memoryItemID: item.id,
            prompt: "Contrast testing and rereading.",
            learnerAnswer: "They are equivalent.",
            feedback: "The contrast is still missing.",
            score: 0.2,
            scheduleRating: .again,
            gradeState: .graded,
            evidenceJSON: #"{"retrieval_quality":"not_recalled","missing_rubric_elements":["effortful recall"],"misconception":"rereading is retrieval"}"#,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 3_000)
        )
        let failed = MemoryAttempt(
            id: "grader-failed",
            memoryItemID: item.id,
            prompt: "Explain the mechanism again.",
            learnerAnswer: "An answer the model could not grade.",
            gradeState: .failed,
            gradingError: "Structured grading response was invalid.",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 4_000)
        )
        let successful = makeMemoryAttempt(
            id: "successful-later",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 5_000),
            rating: .good
        )
        for attempt in [hard, again, failed, successful] {
            try store.recordMemoryAttempt(attempt)
        }

        let projection = try #require(
            try store.memoryStruggleProjection(memoryItemID: item.id, limit: 2)
        )
        #expect(projection == MemoryTutorStruggleProjector.project(
            item: item,
            attempts: [successful, hard, failed, again],
            limit: 2
        ))
        #expect(projection.evidence.map(\.attemptID) == [failed.id, again.id])
        #expect(projection.evidence.last?.retrievalQuality == "not_recalled")
        #expect(projection.evidence.last?.missingRubricElements == ["effortful recall"])
        #expect(projection.evidence.last?.misconception == "rereading is retrieval")
        #expect(!projection.evidence.contains { $0.attemptID == successful.id })
    }

    @Test("Failed and pending attempts cannot carry a score or rating")
    func ungradedAttemptsCannotAdvance() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        try store.saveMemoryItem(item)

        let invalidFailed = MemoryAttempt(
            id: "failed",
            memoryItemID: item.id,
            prompt: "Prompt",
            learnerAnswer: "Answer",
            score: 0.4,
            gradeState: .failed,
            gradingError: "Structured grade decoding failed"
        )
        #expect(throws: (any Error).self) {
            try store.recordMemoryAttempt(invalidFailed)
        }

        let pending = MemoryAttempt(
            id: "pending",
            memoryItemID: item.id,
            prompt: "Prompt",
            learnerAnswer: "Answer",
            gradeState: .pending,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 1_500)
        )
        #expect(try store.recordMemoryAttempt(pending))
        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(schedule.dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: item.createdAt))
        #expect(schedule.lastAttemptAt == pending.attemptedAt)
        #expect(schedule.repetitionCount == 0)
    }

    @Test("Attempt delivered before item is retained and projected when item arrives")
    func outOfOrderAttemptThenItem() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let attempt = makeMemoryAttempt()

        #expect(try store.recordMemoryAttempt(attempt))
        #expect(try store.loadMemoryAttempt(attempt.id) == attempt)
        #expect(try store.loadMemorySchedule(memoryItemID: item.id) == nil)

        try store.saveMemoryItem(item)
        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(schedule.repetitionCount == 1)
        #expect(schedule.lastAttemptAt == attempt.attemptedAt)
        #expect(schedule.dueAt > attempt.attemptedAt)
    }

    @Test("Due plan is bounded, source scoped, and uses the due index")
    func duePlanAndQueryPlan() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        for sourceID in ["source-a", "source-b"] {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Durable canonical text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let first = makeMemoryItem(id: "first", sourceID: "source-a", createdAt: now.addingTimeInterval(-2_000))
        let second = makeMemoryItem(id: "second", sourceID: "source-b", createdAt: now.addingTimeInterval(-1_000))
        let retired = makeMemoryItem(
            id: "retired",
            sourceID: "source-a",
            createdAt: now.addingTimeInterval(-3_000),
            status: .retired
        )
        // Kept long ago and never reviewed: new, so never in the due plan.
        let unreviewed = makeMemoryItem(
            id: "unreviewed",
            sourceID: "source-a",
            createdAt: now.addingTimeInterval(-10 * MemoryTutorScheduler.secondsPerDay)
        )
        for item in [first, second, retired, unreviewed] {
            try store.saveMemoryItem(item)
        }
        for item in [first, second, retired] {
            try recordReview(store, of: item, dueAt: item.createdAt)
        }

        let due = try store.dueMemoryItems(
            now: now,
            limit: 10,
            restrictToSourceIDs: ["source-a"]
        )
        #expect(due.map(\.id) == [first.id])

        var planDetails: [String] = []
        try store.query("""
            EXPLAIN QUERY PLAN
            SELECT ms.memory_item_id
            FROM memory_schedules ms INDEXED BY idx_memory_schedules_due
            JOIN memory_items mi ON mi.id = ms.memory_item_id
            WHERE ms.due_at <= 10000
              AND mi.status = 'active'
            ORDER BY ms.due_at, ms.memory_item_id
            LIMIT 10
        """) { statement in
            if let detail = store.string(statement, 3) {
                planDetails.append(detail)
            }
        }
        #expect(planDetails.contains { $0.contains("idx_memory_schedules_due") })
    }

    @Test("Due storage prioritizes a known struggle before applying its limit")
    func dueStoragePrioritizesStruggleBeforeLimit() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        for sourceID in ["source-old", "source-struggle"] {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Durable canonical text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let oldestBacklog = makeMemoryItem(
            id: "oldest-backlog",
            sourceID: "source-old",
            learnerContext: nil,
            createdAt: now.addingTimeInterval(-10_000)
        )
        let newerStruggle = makeMemoryItem(
            id: "newer-struggle",
            sourceID: "source-struggle",
            learnerContext: "Previously missed the mechanism.",
            createdAt: now.addingTimeInterval(-1_000)
        )
        for item in [oldestBacklog, newerStruggle] {
            try store.saveMemoryItem(item)
            try recordReview(store, of: item, dueAt: item.createdAt)
        }

        let due = try store.dueMemoryItems(now: now, limit: 1)

        #expect(due.map(\.id) == [newerStruggle.id])
    }

    @Test("Global due storage excludes dangling anchors, and only those, before applying its limit")
    func dueStorageExcludesDanglingAnchorsBeforeLimit() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 25_000)
        let dangling = makeMemoryItem(
            id: "dangling-top",
            sourceID: "missing-source",
            learnerContext: "This would rank first if its source still existed.",
            createdAt: now.addingTimeInterval(-10_000)
        )
        try store.saveMemoryItem(dangling)
        try recordReview(store, of: dangling, dueAt: dangling.createdAt)

        var hiddenSource = StudioArticle(
            url: "https://example.com/hidden-due-source",
            title: "Hidden due source",
            id: "hidden-due-source"
        )
        hiddenSource.content = "Canonical text for a hidden source."
        hiddenSource.state = .ready
        try store.saveSource(hiddenSource)
        // Hidden is a list state, not a knowledge state (product owner, 2026-09-11):
        // a struggle anchored on a hidden source is still due, and ranks by
        // age like any other.
        let hiddenStruggle = makeMemoryItem(
            id: "hidden-struggle-top",
            sourceID: hiddenSource.id,
            learnerContext: "A hidden struggle stays in the queue.",
            createdAt: now.addingTimeInterval(-9_000)
        )
        try store.saveMemoryItem(hiddenStruggle)
        try recordReview(store, of: hiddenStruggle, dueAt: hiddenStruggle.createdAt)
        try store.execBind(
            "INSERT INTO hidden_sources (source_id, hidden_at) VALUES (?, ?)",
            { statement in
                store.bind(statement, 1, hiddenSource.id)
                sqlite3_bind_double(statement, 2, now.timeIntervalSinceReferenceDate)
            }
        )

        var expectedIDs: [String] = ["hidden-struggle-top"]
        for index in 0..<5 {
            let sourceID = "available-source-\(index)"
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Durable canonical text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
            let item = makeMemoryItem(
                id: "available-item-\(index)",
                sourceID: sourceID,
                learnerContext: "A known struggle remains available.",
                createdAt: now.addingTimeInterval(Double(-5_000 + index))
            )
            try store.saveMemoryItem(item)
            try recordReview(store, of: item, dueAt: item.createdAt)
            expectedIDs.append(item.id)
        }

        let due = try store.dueMemoryItems(now: now, limit: 5)

        // Five slots: the hidden struggle and the four oldest available items.
        // The dangling item never enters, so it cannot use up a slot either.
        #expect(due.map(\.id) == Array(expectedIDs.prefix(5)))
        #expect(!due.contains { $0.id == dangling.id })
        #expect(due.contains { $0.id == "hidden-struggle-top" })
    }

    @Test("Due storage requires every anchor to be inside source scope before limiting")
    func dueStorageRequiresCompleteAnchorScopeBeforeLimit() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        for sourceID in ["source-a", "source-b"] {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Durable canonical text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let olderMixedScope = makeMemoryItem(
            id: "older-mixed-scope",
            sourceID: "source-a",
            additionalSourceIDs: ["source-b"],
            learnerContext: nil,
            createdAt: now.addingTimeInterval(-10_000)
        )
        let newerFullyScoped = makeMemoryItem(
            id: "newer-fully-scoped",
            sourceID: "source-a",
            learnerContext: nil,
            createdAt: now.addingTimeInterval(-1_000)
        )
        for item in [olderMixedScope, newerFullyScoped] {
            try store.saveMemoryItem(item)
            try recordReview(store, of: item, dueAt: item.createdAt)
        }

        let sourceAOnly = try store.dueMemoryItems(
            now: now,
            limit: 1,
            restrictToSourceIDs: ["source-a"]
        )
        #expect(sourceAOnly.map(\.id) == [newerFullyScoped.id])

        let bothSources = try store.dueMemoryItems(
            now: now,
            limit: 1,
            restrictToSourceIDs: ["source-a", "source-b"]
        )
        #expect(bothSources.map(\.id) == [olderMixedScope.id])
    }

    @Test("Schedules an older scheduler wrote are rebuilt in batches, once")
    func staleSchedulesRebuildOnce() throws {
        let store = try KnowledgeStore(inMemory: true)
        let reviewed = makeMemoryItem(id: "reviewed", sourceID: "source-reviewed")
        let unreviewed = makeMemoryItem(id: "unreviewed", sourceID: "source-unreviewed")
        let pendingOnly = makeMemoryItem(id: "pending-only", sourceID: "source-pending")
        let items = [reviewed, unreviewed, pendingOnly]
        for item in items {
            try store.saveMemoryItem(item)
        }
        try store.recordMemoryAttempt(makeMemoryAttempt(id: "reviewed-attempt", itemID: reviewed.id))
        try store.recordMemoryAttempt(MemoryAttempt(
            id: "pending-attempt",
            memoryItemID: pendingOnly.id,
            prompt: "Prompt",
            learnerAnswer: "Answer",
            gradeState: .pending,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 1_500)
        ))
        let current = try items.map { try #require(try store.loadMemorySchedule(memoryItemID: $0.id)) }

        // What version 1 left behind: an unreviewed item due the moment it was kept.
        try store.exec("UPDATE memory_schedules SET algorithm_version = 1")
        try store.execBind(
            "UPDATE memory_schedules SET due_at = ? WHERE memory_item_id IN ('unreviewed', 'pending-only')"
        ) { statement in
            sqlite3_bind_double(statement, 1, unreviewed.createdAt.timeIntervalSinceReferenceDate)
        }
        #expect(try store.loadMemorySchedule(memoryItemID: unreviewed.id)?.dueAt == unreviewed.createdAt)

        // Ids in order: pending-only, reviewed | unreviewed.
        let first = try store.rebuildStaleMemorySchedules(limit: 2)
        #expect(first == .init(rebuilt: 2, skippedIDs: [], nextAfterID: "reviewed"))
        let second = try store.rebuildStaleMemorySchedules(after: first.nextAfterID, limit: 2)
        #expect(second == .init(rebuilt: 1, skippedIDs: [], nextAfterID: nil))
        #expect(try store.rebuildStaleMemorySchedules(limit: 2) == .init())

        let rebuilt = try items.map { try #require(try store.loadMemorySchedule(memoryItemID: $0.id)) }
        #expect(rebuilt == current)
        #expect(rebuilt.allSatisfy { $0.algorithmVersion == MemoryTutorScheduler.algorithmVersion })
        #expect(rebuilt[1].isNew)
        #expect(rebuilt[1].dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: unreviewed.createdAt))
        #expect(!rebuilt[0].isNew)
    }

    @Test("An item that cannot be read is skipped and named, and the rest of its batch is rebuilt around it")
    func staleScheduleRebuildSkipsUnreadableItems() throws {
        let store = try KnowledgeStore(inMemory: true)
        let items = ["a-item", "b-unreadable", "c-item", "d-item"].map { id in
            makeMemoryItem(id: id, sourceID: "source-\(id)")
        }
        for item in items {
            try store.saveMemoryItem(item)
        }
        try store.exec("UPDATE memory_schedules SET algorithm_version = 1")
        // A kind a newer build might write: this build cannot read the item.
        try store.exec("UPDATE memory_items SET kind = 'lecture' WHERE id = 'b-unreadable'")
        #expect(throws: KnowledgeStoreError.self) { try store.loadMemoryItem("b-unreadable") }

        var batches: [KnowledgeStore.MemoryScheduleRebuildBatch] = []
        var after: String?
        repeat {
            let batch = try store.rebuildStaleMemorySchedules(after: after, limit: 2)
            batches.append(batch)
            after = batch.nextAfterID
        } while after != nil && batches.count < 10

        #expect(batches == [
            .init(rebuilt: 1, skippedIDs: ["b-unreadable"], nextAfterID: "b-unreadable"),
            .init(rebuilt: 2, skippedIDs: [], nextAfterID: "d-item"),
            .init(rebuilt: 0, skippedIDs: [], nextAfterID: nil),
        ])
        for id in ["a-item", "c-item", "d-item"] {
            #expect(try store.loadMemorySchedule(memoryItemID: id)?.algorithmVersion == MemoryTutorScheduler.algorithmVersion)
        }
        // Left as it was for a build that can read it.
        #expect(try store.loadMemorySchedule(memoryItemID: "b-unreadable")?.algorithmVersion == 1)
    }

    @Test("The store deals today's cards through the shared queue, over the items the library may ask")
    func storeDealsTodaysCards() throws {
        let store = try KnowledgeStore(inMemory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10)))
        let day = MemoryTutorScheduler.secondsPerDay
        for sourceID in ["source-a", "source-b"] {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Durable canonical text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let due = makeMemoryItem(id: "due", sourceID: "source-a", createdAt: now.addingTimeInterval(-10 * day))
        let new = makeMemoryItem(id: "new", sourceID: "source-b", createdAt: now.addingTimeInterval(-2 * day))
        let keptToday = makeMemoryItem(id: "kept-today", sourceID: "source-a", createdAt: now.addingTimeInterval(-3_600))
        let dangling = makeMemoryItem(id: "dangling", sourceID: "missing-source", createdAt: now.addingTimeInterval(-3 * day))
        let retired = makeMemoryItem(
            id: "retired",
            sourceID: "source-a",
            createdAt: now.addingTimeInterval(-3 * day),
            status: .retired
        )
        for item in [due, new, keptToday, dangling, retired] {
            try store.saveMemoryItem(item)
        }
        try recordReview(store, of: due, dueAt: now.addingTimeInterval(-day))

        let today = try store.memoryCardQueueToday(
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )
        #expect(today.entries.map(\.id) == ["due", "new"])
        #expect(today.entries.map(\.bucket) == [.due, .new])
        #expect(today == MemoryCardQueue.today(
            items: [due, new],
            attempts: try store.loadMemoryAttempts(),
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        ))

        let scoped = try store.memoryCardQueueToday(
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            restrictToSourceIDs: ["source-b"],
            calendar: calendar
        )
        #expect(scoped.entries.map(\.id) == ["new"])

        let beforeABlock = try store.memoryCardQueueToday(
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [MemoryCardDeadline(
                notebookID: "notebook-b",
                at: now.addingTimeInterval(4 * 3_600),
                sourceIDs: ["source-b"]
            )],
            calendar: calendar
        )
        #expect(beforeABlock.entries.map(\.id) == ["new", "due"])
        #expect(beforeABlock.entries.first?.notebookID == "notebook-b")
    }

    @Test("First concept intake bootstraps due legacy reviews and excludes retired identities")
    func firstConceptIntakeIncludesLegacyHistory() async throws {
        let service = try StorageService(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        func source(_ suffix: String, readAt: Date? = nil) -> StudioArticle {
            var article = StudioArticle(
                url: "https://example.com/memory-intake-\(suffix)",
                title: suffix
            )
            article.content = "Canonical text for \(suffix)."
            article.readAt = readAt
            article.state = .ready
            return article
        }

        let weak = source("weak")
        let strong = source("strong")
        let represented = source("represented")
        let unreadByTutor = source("new", readAt: now.addingTimeInterval(-5 * 86_400))
        for article in [weak, strong, represented, unreadByTutor] {
            try await service.saveSource(article)
        }

        for (index, review) in [(weak, 0.3), (strong, 0.95), (represented, 0.2)].enumerated() {
            let sessionID = "legacy-review-\(index)"
            let reviewedAt = now.addingTimeInterval(-20 * 86_400)
            try await service.createReviewSession(
                id: sessionID,
                topic: "Legacy review",
                sourceIDs: [review.0.id],
                startedAt: reviewedAt
            )
            try await service.completeReviewSession(
                sessionID: sessionID,
                overallScore: review.1,
                summary: "Stored legacy review",
                endedAt: reviewedAt
            )
        }
        try await service.saveMemoryItem(
            makeMemoryItem(
                id: "already-represented",
                sourceID: represented.id,
                createdAt: now.addingTimeInterval(-100),
                status: .retired
            )
        )

        let intake = try await service.firstReviewMemoryItems(now: now, limit: 3)
        // Both intake buckets are present, and the source consumed five days ago
        // leads the two reviewed twenty days ago. Ordering by how long something
        // has been waiting is the backlog's own reading of itself; a daily queue
        // opens on what the learner most recently went through.
        #expect(intake.map(\.sourceID) == [unreadByTutor.id, weak.id, strong.id])
        #expect(!intake.map(\.sourceID).contains(represented.id))
    }

    @Test("Legacy memory stats keep hidden sources; hiding is visual only")
    func legacyMemoryStatsKeepHiddenSources() throws {
        let store = try KnowledgeStore(inMemory: true)
        var hidden = StudioArticle(
            url: "https://example.com/hidden-legacy-memory",
            title: "Hidden legacy memory",
            id: "hidden-legacy-memory"
        )
        hidden.content = "Canonical text for a hidden historical review."
        hidden.state = .ready
        try store.saveSource(hidden)
        try store.createReviewSession(
            id: "hidden-legacy-session",
            topic: "Hidden review",
            sourceIDs: [hidden.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.completeReviewSession(
            sessionID: "hidden-legacy-session",
            overallScore: 0.1,
            summary: "A weak review that would otherwise rank first.",
            endedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try store.execBind(
            "INSERT INTO hidden_sources (source_id, hidden_at) VALUES (?, ?)",
            { statement in
                store.bind(statement, 1, hidden.id)
                sqlite3_bind_double(statement, 2, 300)
            }
        )

        let stats = try store.memoryReviewStats()
        #expect(stats.map(\.sourceID) == [hidden.id])
        #expect(stats.first?.reviewCount == 1)
    }

    @Test("Atomic chat completion rejects transcript disagreement and commits exact linkage")
    func atomicChatAttemptLinkage() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "session-1", topic: "Memory", sourceIDs: [])
        // Typed chat persists the learner message before the UI has stored a
        // separate assistant prompt, leaving an intentionally blank question.
        _ = try store.recordPendingReviewUserMessage(
            sessionID: "session-1",
            answer: "Persisted answer",
            sourceRefs: ["source-1"]
        )
        let item = makeMemoryItem()
        let mismatch = MemoryAttempt(
            id: "atomic-attempt",
            memoryItemID: item.id,
            prompt: "Explain the retrieval effect.",
            learnerAnswer: "Different answer",
            feedback: "Feedback",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded
        )
        #expect(throws: (any Error).self) {
            try store.completePendingReviewExchangeAndRecordMemoryAttempt(
                sessionID: "session-1",
                answer: mismatch.learnerAnswer,
                evaluation: "Feedback",
                knowledgeNote: nil,
                sourceRefs: ["source-1"],
                item: item,
                attempt: mismatch
            )
        }
        #expect(try store.loadMemoryItem(item.id) == nil)
        #expect(try store.loadMemoryAttempt(mismatch.id) == nil)

        let exact = MemoryAttempt(
            id: "atomic-attempt",
            memoryItemID: item.id,
            prompt: "Explain the retrieval effect.",
            learnerAnswer: "Persisted answer",
            feedback: "Feedback",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded
        )
        let linked = try store.completePendingReviewExchangeAndRecordMemoryAttempt(
            sessionID: "session-1",
            answer: exact.learnerAnswer,
            evaluation: "Feedback",
            knowledgeNote: "Retrieval is productive effort.",
            sourceRefs: ["source-1"],
            item: item,
            attempt: exact
        )
        #expect(linked.sessionID == "session-1")
        #expect(linked.exchangeID?.isEmpty == false)
        #expect(try store.loadMemoryAttempt(linked.id) == linked)
        #expect(try store.loadMemoryItemsForSession("session-1") == [item])
        let linkedExchange = try #require(
            try store.loadReviewSessionExchanges(sessionID: "session-1").first
        )
        #expect(linkedExchange.question == exact.prompt)
        #expect(linkedExchange.userAnswer == exact.learnerAnswer)
        #expect(linkedExchange.evaluation == exact.feedback)
    }

    @Test("Recent chat activity excludes memory launch queues")
    func recentChatActivityExcludesMemoryLaunchQueues() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let ordinarySource = StudioArticle(
            url: "https://example.com/recent-ordinary",
            title: "Recent ordinary",
            id: "recent-ordinary"
        )
        let memorySource = StudioArticle(
            url: "https://example.com/recent-memory-launch",
            title: "Recent memory launch",
            id: "recent-memory-launch"
        )
        try store.saveSource(ordinarySource)
        try store.saveSource(memorySource)

        try store.createReviewSession(
            id: "ordinary-chat",
            topic: "Ordinary review",
            sourceIDs: [ordinarySource.id],
            startedAt: now.addingTimeInterval(-120)
        )
        _ = try store.addReviewPrompt(
            sessionID: "ordinary-chat",
            question: "Explain the recent idea.",
            sourceRefs: [ordinarySource.id]
        )
        try store.createReviewSession(
            id: "memory-launch",
            topic: "Daily memory check",
            sourceIDs: [memorySource.id],
            cardIDs: ["memory-item:portable-key"],
            startedAt: now.addingTimeInterval(-60)
        )
        _ = try store.addReviewPrompt(
            sessionID: "memory-launch",
            question: "A planned memory question.",
            sourceRefs: [memorySource.id]
        )

        let activity = try store.recentReviewSourceActivity(now: now)

        #expect(activity.map(\.sourceID) == [ordinarySource.id])
    }

    @Test("Typed chat cannot overwrite a concurrently created first-review curriculum")
    func atomicChatIntakeRejectsConcurrentCurriculumConflict() throws {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(
            url: "https://example.com/source-1",
            title: "Source 1",
            id: "source-1"
        )
        source.content = "Durable canonical text for the retrieval-practice source."
        source.state = .ready
        try store.saveSource(source)
        let canonicalItem = makeMemoryItem(id: "source-global-first-review")
        try store.saveMemoryItem(canonicalItem)
        try store.createReviewSession(
            id: "stale-chat-session",
            topic: "Stale first-review plan",
            sourceIDs: ["source-1"]
        )
        _ = try store.recordPendingReviewUserMessage(
            sessionID: "stale-chat-session",
            answer: "Retrieval reveals what I can produce without the text.",
            sourceRefs: ["source-1"]
        )
        let staleCandidate = MemoryItem(
            id: canonicalItem.id,
            kind: canonicalItem.kind,
            target: "A stale surface generated a different learning target.",
            rubricJSON: #"{"criteria":["Different curriculum"]}"#,
            learnerContext: canonicalItem.learnerContext,
            goalID: canonicalItem.goalID,
            status: canonicalItem.status,
            sources: canonicalItem.sources,
            createdAt: canonicalItem.createdAt,
            updatedAt: canonicalItem.updatedAt
        )
        let attempt = MemoryAttempt(
            id: "stale-chat-attempt",
            memoryItemID: canonicalItem.id,
            prompt: "Explain retrieval before feedback.",
            learnerAnswer: "Retrieval reveals what I can produce without the text.",
            feedback: "Correct.",
            score: 0.9,
            scheduleRating: .easy,
            gradeState: .graded
        )

        #expect(throws: (any Error).self) {
            try store.completePendingReviewExchangeAndRecordMemoryAttempt(
                sessionID: "stale-chat-session",
                answer: attempt.learnerAnswer,
                evaluation: attempt.feedback ?? "",
                knowledgeNote: nil,
                sourceRefs: ["source-1"],
                item: staleCandidate,
                attempt: attempt
            )
        }
        #expect(try store.loadMemoryItem(canonicalItem.id) == canonicalItem)
        #expect(try store.loadMemoryAttempt(attempt.id) == nil)

        let timestampVariant = MemoryItem(
            id: canonicalItem.id,
            kind: canonicalItem.kind,
            target: canonicalItem.target,
            rubricJSON: canonicalItem.rubricJSON,
            learnerContext: "A different device observed a later misconception.",
            goalID: canonicalItem.goalID,
            status: canonicalItem.status,
            sources: canonicalItem.sources,
            createdAt: canonicalItem.createdAt.addingTimeInterval(500),
            updatedAt: canonicalItem.updatedAt.addingTimeInterval(500)
        )
        #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(canonicalItem, timestampVariant))
        #expect(!MemoryTutorIdentity.hasSameImmutableCurriculum(canonicalItem, staleCandidate))
        let linked = try store.completePendingReviewExchangeAndRecordMemoryAttempt(
            sessionID: "stale-chat-session",
            answer: attempt.learnerAnswer,
            evaluation: attempt.feedback ?? "",
            knowledgeNote: nil,
            sourceRefs: ["source-1"],
            item: timestampVariant,
            attempt: attempt
        )
        #expect(try store.loadMemoryItem(canonicalItem.id) == canonicalItem)
        #expect(try store.loadMemoryAttempt(linked.id) == linked)
    }

    @Test("Attempt writers reject a curriculum swap after the prompt was prepared")
    func attemptWritersOptimisticallyLockCurriculum() throws {
        let store = try KnowledgeStore(inMemory: true)
        let plannedItem = makeMemoryItem(id: "optimistic-curriculum")
        try store.saveMemoryItem(plannedItem)
        let plannedFingerprint = MemoryTutorIdentity.immutableCurriculumFingerprint(
            plannedItem
        )
        let remappedSourceSnapshot = plannedItem.replacingSources(
            plannedItem.sources.map { source in
                MemoryItemSource(
                    id: source.id,
                    memoryItemID: source.memoryItemID,
                    sourceID: "same-portable-source-on-another-device",
                    locatorJSON: source.locatorJSON,
                    excerpt: source.excerpt,
                    sourceSHA256: source.sourceSHA256,
                    sortIndex: source.sortIndex
                )
            }
        )
        #expect(
            MemoryTutorIdentity.immutableCurriculumFingerprint(remappedSourceSnapshot)
                == plannedFingerprint
        )

        try store.createReviewSession(
            id: "optimistic-chat",
            topic: "Prepared typed review",
            sourceIDs: []
        )
        _ = try store.recordPendingReviewUserMessage(
            sessionID: "optimistic-chat",
            answer: "The prepared answer.",
            sourceRefs: []
        )
        try store.createReviewSession(
            id: "optimistic-voice",
            topic: "Prepared voice review",
            sourceIDs: []
        )
        try store.createReviewSession(
            id: "optimistic-batch",
            topic: "Prepared MCP review",
            sourceIDs: []
        )

        let replacement = MemoryItem(
            id: plannedItem.id,
            kind: plannedItem.kind,
            target: "A server winner asks about a different concept.",
            rubricJSON: #"{"criteria":["different criterion"]}"#,
            learnerContext: plannedItem.learnerContext,
            goalID: plannedItem.goalID,
            status: plannedItem.status,
            sources: plannedItem.sources,
            createdAt: plannedItem.createdAt,
            updatedAt: plannedItem.updatedAt.addingTimeInterval(1)
        )
        try store.saveMemoryItem(replacement)
        #expect(
            MemoryTutorIdentity.immutableCurriculumFingerprint(replacement)
                != plannedFingerprint
        )

        let typedAttempt = MemoryAttempt(
            id: "optimistic-chat-attempt",
            memoryItemID: plannedItem.id,
            prompt: "Explain the prepared curriculum.",
            learnerAnswer: "The prepared answer.",
            feedback: "Feedback for the prepared curriculum.",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded
        )
        #expect(throws: (any Error).self) {
            try store.completePendingReviewExchangeAndRecordMemoryAttempt(
                sessionID: "optimistic-chat",
                answer: typedAttempt.learnerAnswer,
                evaluation: typedAttempt.feedback ?? "",
                knowledgeNote: nil,
                sourceRefs: [],
                expectedExistingItem: plannedItem,
                attempt: typedAttempt
            )
        }
        #expect(try store.loadMemoryAttempt(typedAttempt.id) == nil)
        let pendingExchange = try #require(
            try store.loadReviewSessionExchanges(sessionID: "optimistic-chat").first
        )
        #expect(pendingExchange.question.isEmpty)
        #expect(pendingExchange.evaluation == nil)

        let voiceAttempt = MemoryAttempt(
            id: "optimistic-voice-attempt",
            memoryItemID: plannedItem.id,
            prompt: typedAttempt.prompt,
            learnerAnswer: typedAttempt.learnerAnswer,
            feedback: typedAttempt.feedback,
            score: typedAttempt.score,
            scheduleRating: typedAttempt.scheduleRating,
            gradeState: .graded
        )
        #expect(throws: (any Error).self) {
            try store.recordMemoryAttemptCreatingReviewExchange(
                sessionID: "optimistic-voice",
                sourceRefs: [],
                expectedExistingItem: plannedItem,
                attempt: voiceAttempt
            )
        }
        #expect(try store.loadMemoryAttempt(voiceAttempt.id) == nil)
        #expect(try store.loadReviewSessionExchanges(sessionID: "optimistic-voice").isEmpty)

        let batchAttempt = MemoryAttempt(
            id: "optimistic-batch-attempt",
            memoryItemID: plannedItem.id,
            prompt: typedAttempt.prompt,
            learnerAnswer: typedAttempt.learnerAnswer,
            feedback: typedAttempt.feedback,
            score: typedAttempt.score,
            scheduleRating: typedAttempt.scheduleRating,
            gradeState: .graded
        )
        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: "optimistic-batch",
                overallScore: 0.8,
                summary: "Should roll back.",
                endedAt: Date(timeIntervalSinceReferenceDate: 5_000),
                expectedCurriculumFingerprints: [
                    plannedItem.id: plannedFingerprint,
                ],
                attempts: [batchAttempt]
            )
        }
        #expect(try store.loadMemoryAttempt(batchAttempt.id) == nil)
        #expect(try store.loadReviewSessionForSync("optimistic-batch")?.status == "active")
        #expect(try store.loadReviewSessionExchanges(sessionID: "optimistic-batch").isEmpty)
    }

    @Test("Batch review creates deterministic exchanges and transcript retry is idempotent")
    func batchReviewCreatesExchangesAndRetries() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        try store.createReviewSession(
            id: "mcp-session",
            topic: "External memory review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 4_000)
        )
        let attempt = MemoryAttempt(
            id: "mcp-attempt",
            memoryItemID: item.id,
            attemptType: .imported,
            prompt: "Explain retrieval practice.",
            learnerAnswer: "Recall without looking.",
            feedback: "Correct.",
            score: 0.82,
            scheduleRating: .good,
            gradeState: .graded,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 4_050)
        )
        let transcript = "Tutor: Explain retrieval practice.\nLearner: Recall without looking."

        try store.completeReviewSessionAndRecordMemoryAttempts(
            sessionID: "mcp-session",
            overallScore: 0.82,
            summary: "Good recall.",
            endedAt: Date(timeIntervalSinceReferenceDate: 4_100),
            exportedTranscript: transcript,
            transcriptKnowledgeNote: "Imported by MCP.",
            items: [item],
            attempts: [attempt]
        )
        let retryItem = MemoryItem(
            id: item.id,
            kind: item.kind,
            target: item.target,
            rubricJSON: item.rubricJSON,
            learnerContext: item.learnerContext,
            goalID: item.goalID,
            status: item.status,
            sources: item.sources,
            createdAt: item.createdAt.addingTimeInterval(1_000),
            updatedAt: item.updatedAt.addingTimeInterval(1_000)
        )
        try store.completeReviewSessionAndRecordMemoryAttempts(
            sessionID: "mcp-session",
            overallScore: 0.82,
            summary: "Good recall.",
            endedAt: Date(timeIntervalSinceReferenceDate: 4_100),
            exportedTranscript: transcript,
            transcriptKnowledgeNote: "Imported by MCP.",
            items: [retryItem],
            attempts: [attempt]
        )
        #expect(try store.loadMemoryItem(item.id) == item)
        let storedAttempts = try store.loadMemoryAttempts(sessionID: "mcp-session")
        #expect(storedAttempts.count == 1)
        #expect(storedAttempts.first?.exchangeID == "mcp-session::memory-attempt::mcp-attempt")
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "mcp-session")
        #expect(exchanges.count == 2)
        let exported = exchanges.first { $0.id == "mcp-session::memory-export::1" }
        #expect(exported?.question == "Explain retrieval practice.")
        #expect(exported?.userAnswer == "Recall without looking.")
    }

    @Test("Atomic MCP completion rolls back every side effect and exact retry advances once")
    func atomicMCPCompletionRollbackAndRetry() throws {
        let store = try KnowledgeStore(inMemory: true)
        let source = StudioArticle(
            url: "https://example.com/atomic-review",
            title: "Atomic review",
            sourceType: .article,
            id: "atomic-source"
        )
        try store.saveSource(source)
        let startedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        let endedAt = Date(timeIntervalSinceReferenceDate: 5_100)
        let goal = try store.createCompanionGoal(
            title: "Atomic learning",
            topic: "retrieval",
            startAt: startedAt,
            endAt: startedAt.addingTimeInterval(7 * 86_400),
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [source.id]
        )
        try store.createReviewSession(
            id: "atomic-session",
            topic: "Atomic review",
            sourceIDs: [source.id],
            startedAt: startedAt,
            goalID: goal.id
        )
        let item = MemoryItem(
            id: "atomic-item",
            kind: .concept,
            target: "Explain why effortful retrieval improves later recall.",
            rubricJSON: #"{"criteria":["distinguishes retrieval from rereading"]}"#,
            learnerContext: nil,
            goalID: nil,
            sources: [
                MemoryItemSource(
                    id: "atomic-anchor",
                    memoryItemID: "atomic-item",
                    sourceID: source.id,
                    excerpt: "Effortful retrieval changes the probability of later recall.",
                    sourceSHA256: String(repeating: "b", count: 64),
                    sortIndex: 0
                )
            ],
            createdAt: startedAt,
            updatedAt: startedAt
        )
        let attempt = MemoryAttempt(
            id: "atomic-attempt",
            memoryItemID: item.id,
            attemptType: .imported,
            prompt: "Why does retrieval help?",
            learnerAnswer: "The effort changes the odds of recalling it later.",
            feedback: "Correct.",
            score: 0.9,
            scheduleRating: .easy,
            gradeState: .graded,
            attemptedAt: endedAt
        )
        let gap = LearningGoalGap(
            id: "atomic-session::gap::0",
            goalID: goal.id,
            summary: "Transfer the retrieval principle to unfamiliar examples.",
            sourceID: source.id,
            status: "open",
            severity: 0.4,
            firstSeenAt: endedAt,
            lastSeenAt: endedAt,
            resolvedAt: nil,
            sessionID: "atomic-session"
        )
        let secondGap = LearningGoalGap(
            id: "atomic-session::gap::1",
            goalID: goal.id,
            summary: "Explain when retrieval effort becomes unproductive.",
            sourceID: source.id,
            status: "open",
            severity: 0.3,
            firstSeenAt: endedAt,
            lastSeenAt: endedAt,
            resolvedAt: nil,
            sessionID: "atomic-session"
        )
        let transcript = "Tutor: Why does retrieval help?\nLearner: Effort changes later recall."

        // Fail on the final session-completion write, after every other row has
        // been staged. BEGIN IMMEDIATE must roll back the entire boundary.
        try store.exec("""
            CREATE TRIGGER fail_atomic_review_completion
            BEFORE UPDATE OF status ON review_sessions
            WHEN OLD.id = 'atomic-session' AND NEW.status = 'completed'
            BEGIN
                SELECT RAISE(ABORT, 'injected completion failure');
            END
        """)
        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: "atomic-session",
                overallScore: 0.9,
                summary: "Strong recall.",
                endedAt: endedAt,
                exportedTranscript: transcript,
                transcriptKnowledgeNote: "Imported by MCP.",
                sessionSourceIDs: [source.id],
                scheduleReviewDate: endedAt,
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [gap, secondGap],
                items: [item],
                attempts: [attempt]
            )
        }
        #expect(try store.loadMemoryItem(item.id) == nil)
        #expect(try store.loadMemoryAttempts(sessionID: "atomic-session").isEmpty)
        #expect(try store.scheduledPlacement(forSource: source.id) == nil)
        #expect(try store.loadLearningGoal(goal.id)?.items.first?.quizCount == nil)
        #expect(try store.loadLearningGoalGaps(goalID: goal.id).isEmpty)
        #expect(try store.loadReviewSessionForSync("atomic-session")?.status == "active")
        #expect(try store.loadReviewSessionExchanges(sessionID: "atomic-session").isEmpty)

        try store.exec("DROP TRIGGER fail_atomic_review_completion")
        try store.completeReviewSessionAndRecordMemoryAttempts(
            sessionID: "atomic-session",
            overallScore: 0.9,
            summary: "Strong recall.",
            endedAt: endedAt,
            exportedTranscript: transcript,
            transcriptKnowledgeNote: "Imported by MCP.",
            sessionSourceIDs: [source.id],
            scheduleReviewDate: endedAt,
            companionGoalID: goal.id,
            companionQuizDate: "2026-08-10",
            companionGaps: [gap, secondGap],
            items: [item],
            attempts: [attempt]
        )
        // Exact replay is idempotent and no counter/schedule is advanced twice.
        try store.completeReviewSessionAndRecordMemoryAttempts(
            sessionID: "atomic-session",
            overallScore: 0.9,
            summary: "Strong recall.",
            endedAt: endedAt,
            exportedTranscript: transcript,
            transcriptKnowledgeNote: "Imported by MCP.",
            sessionSourceIDs: [source.id],
            scheduleReviewDate: endedAt,
            companionGoalID: goal.id,
            companionQuizDate: "2026-08-10",
            companionGaps: [gap, secondGap],
            items: [item],
            attempts: [attempt]
        )
        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: "atomic-session",
                overallScore: 0.9,
                summary: "Strong recall.",
                endedAt: endedAt.addingTimeInterval(1_000),
                exportedTranscript: transcript,
                transcriptKnowledgeNote: "Imported by MCP.",
                sessionSourceIDs: [source.id],
                scheduleReviewDate: endedAt,
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [gap, secondGap],
                items: [item],
                attempts: [attempt]
            )
        }
        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: "atomic-session",
                overallScore: 0.9,
                summary: "Strong recall.",
                endedAt: endedAt,
                exportedTranscript: transcript,
                transcriptKnowledgeNote: "Imported by MCP.",
                sessionSourceIDs: [source.id],
                scheduleReviewDate: endedAt,
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [gap],
                items: [item],
                attempts: [attempt]
            )
        }
        let changedGapTimestamp = LearningGoalGap(
            id: gap.id,
            goalID: gap.goalID,
            summary: gap.summary,
            sourceID: gap.sourceID,
            status: gap.status,
            severity: gap.severity,
            firstSeenAt: gap.firstSeenAt,
            lastSeenAt: gap.lastSeenAt.addingTimeInterval(1),
            resolvedAt: gap.resolvedAt,
            sessionID: gap.sessionID
        )
        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: "atomic-session",
                overallScore: 0.9,
                summary: "Strong recall.",
                endedAt: endedAt,
                exportedTranscript: transcript,
                transcriptKnowledgeNote: "Imported by MCP.",
                sessionSourceIDs: [source.id],
                scheduleReviewDate: endedAt,
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [changedGapTimestamp, secondGap],
                items: [item],
                attempts: [attempt]
            )
        }

        #expect(try store.loadMemoryItem(item.id) == item)
        #expect(try store.loadMemoryAttempts(sessionID: "atomic-session").count == 1)
        #expect(try store.scheduledPlacement(forSource: source.id)?.completedAt == endedAt)
        #expect(try store.loadLearningGoal(goal.id)?.items.first?.quizCount == 1)
        #expect(Set(try store.loadLearningGoalGaps(goalID: goal.id).map(\.id)) == Set([gap.id, secondGap.id]))
        let completed = try #require(try store.loadReviewSessionForSync("atomic-session"))
        #expect(completed.status == "completed")
        #expect(completed.endedAt == endedAt)
        #expect(completed.exchanges.count == 2)
    }

    @Test("Memory completion advances only sources grounded by attempts")
    func memoryCompletionLeavesUntouchedQueueSourcesDue() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 5_500)
        var reviewedSource = StudioArticle(
            url: "https://example.com/reviewed-queue-source",
            title: "Reviewed queue source",
            id: "reviewed-queue-source"
        )
        reviewedSource.content = "The concept the learner actually attempted."
        reviewedSource.state = .ready
        var untouchedSource = StudioArticle(
            url: "https://example.com/untouched-queue-source",
            title: "Untouched queue source",
            id: "untouched-queue-source"
        )
        untouchedSource.content = "A later queue concept that was never prompted."
        untouchedSource.state = .ready
        try store.saveSource(reviewedSource)
        try store.saveSource(untouchedSource)
        let goal = try store.createCompanionGoal(
            title: "Partial queue review",
            topic: "bounded memory review",
            startAt: now,
            endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 2,
            discoveryEnabled: false,
            seedSourceIDs: [reviewedSource.id, untouchedSource.id]
        )
        let sessionID = "partial-queue-session"
        try store.createReviewSession(
            id: sessionID,
            topic: "Two queued concepts",
            sourceIDs: [reviewedSource.id, untouchedSource.id],
            startedAt: now,
            goalID: goal.id
        )
        let item = makeMemoryItem(
            id: "partial-queue-item",
            sourceID: reviewedSource.id,
            learnerContext: nil,
            createdAt: now
        )
        let attempt = MemoryAttempt(
            id: "partial-queue-attempt",
            memoryItemID: item.id,
            prompt: "Explain the attempted concept.",
            learnerAnswer: "I retrieved the attempted concept.",
            feedback: "Correct.",
            score: 0.85,
            scheduleRating: .good,
            gradeState: .graded,
            attemptedAt: now.addingTimeInterval(30)
        )
        let endedAt = now.addingTimeInterval(60)

        try store.completeReviewSessionAndRecordMemoryAttempts(
            sessionID: sessionID,
            overallScore: 0.85,
            summary: "Stopped after the first concept.",
            endedAt: endedAt,
            sessionSourceIDs: [reviewedSource.id, untouchedSource.id],
            reviewedSourceIDs: [reviewedSource.id],
            scheduleReviewDate: endedAt,
            companionGoalID: goal.id,
            companionQuizDate: "2026-08-11",
            items: [item],
            attempts: [attempt]
        )

        let syncedSession = try #require(try store.loadReviewSessionForSync(sessionID))
        #expect(Set(syncedSession.sourceIDs) == [reviewedSource.id, untouchedSource.id])
        #expect(try store.scheduledPlacement(forSource: reviewedSource.id)?.completedAt == endedAt)
        #expect(try store.scheduledPlacement(forSource: untouchedSource.id) == nil)
        let refreshedGoal = try #require(try store.loadLearningGoal(goal.id))
        #expect(refreshedGoal.items.first { $0.sourceID == reviewedSource.id }?.quizCount == 1)
        #expect(refreshedGoal.items.first { $0.sourceID == untouchedSource.id }?.quizCount == nil)
        #expect(try store.memoryReviewStats().map(\.sourceID) == [reviewedSource.id])
        #expect(try store.sourceReviewDates()[reviewedSource.id] == endedAt)
        #expect(try store.sourceReviewDates()[untouchedSource.id] == nil)

        #expect(throws: (any Error).self) {
            try store.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: sessionID,
                overallScore: 0.85,
                summary: "Stopped after the first concept.",
                endedAt: endedAt.addingTimeInterval(500),
                sessionSourceIDs: [reviewedSource.id, untouchedSource.id],
                reviewedSourceIDs: [untouchedSource.id],
                scheduleReviewDate: endedAt.addingTimeInterval(500),
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-11",
                items: [item],
                attempts: [attempt]
            )
        }
    }

    @Test("Inbound session deletion cascades server tombstones for linked attempts")
    func inboundSessionDeletionCannotResurrectAttempt() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        try store.saveMemoryItem(item)
        try store.createReviewSession(
            id: "deleted-remote-session",
            topic: "Deleted on an older Mac",
            sourceIDs: []
        )
        let linked = try store.recordMemoryAttemptCreatingReviewExchange(
            sessionID: "deleted-remote-session",
            sourceRefs: item.sources.map(\.sourceID),
            attempt: makeMemoryAttempt(id: "remote-linked-attempt")
        )
        try store.clearAllPendingSyncChanges()

        try store.withoutSyncTracking {
            try store.deleteReviewSession("deleted-remote-session")
        }

        #expect(try store.loadMemoryAttempt(linked.id) == nil)
        #expect(try store.loadReviewSessionForSync("deleted-remote-session") == nil)
        let changes = try store.pendingSyncChanges()
        #expect(changes.count == 1)
        #expect(changes.first?.entity == .memoryAttempt)
        #expect(changes.first?.logicalKey == linked.id)
        #expect(changes.first?.operation == .delete)
        #expect(try store.loadMemorySchedule(memoryItemID: item.id)?.repetitionCount == 0)
    }

    @Test("Inbound attempt deletion rolls back row and schedule when projection rebuild fails")
    func inboundAttemptDeletionIsTransactional() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let first = makeMemoryAttempt(
            id: "delete-first",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 6_000)
        )
        let second = makeMemoryAttempt(
            id: "delete-second",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 7_000),
            rating: .easy
        )
        try store.saveMemoryItem(item)
        try store.recordMemoryAttempt(first)
        try store.recordMemoryAttempt(second)
        try store.clearAllPendingSyncChanges()
        #expect(try store.loadMemorySchedule(memoryItemID: item.id)?.repetitionCount == 2)

        try store.exec("""
            CREATE TRIGGER fail_memory_schedule_rebuild
            BEFORE UPDATE ON memory_schedules
            WHEN OLD.memory_item_id = 'memory-item-1'
            BEGIN
                SELECT RAISE(ABORT, 'injected schedule rebuild failure');
            END
        """)
        #expect(throws: (any Error).self) {
            try store.deleteMemoryAttemptRecord(id: second.id)
        }
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id) == [first, second])
        #expect(try store.loadMemorySchedule(memoryItemID: item.id)?.repetitionCount == 2)
        #expect(try store.pendingSyncChanges().isEmpty)

        try store.exec("DROP TRIGGER fail_memory_schedule_rebuild")
        try store.deleteMemoryAttemptRecord(id: second.id)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id) == [first])
        #expect(try store.loadMemorySchedule(memoryItemID: item.id)?.repetitionCount == 1)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt && $0.logicalKey == second.id && $0.operation == .delete
        })
    }

    @Test("Canonical intake snapshot hashes the complete stored source")
    func canonicalSourceSnapshot() throws {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(url: "https://example.com/retrieval", title: "Retrieval")
        source.content = "Complete canonical source text, not merely the selected excerpt."
        source.state = .ready
        try store.saveSource(source)

        let snapshot = try store.canonicalMemorySourceSnapshot(sourceID: source.id)
        #expect(snapshot.sourceID == source.id)
        #expect(snapshot.content == source.content)
        #expect(snapshot.sourceSHA256 == PaperContentPreparationService.sha256(snapshot.content))
    }
}

@Suite("Memory Tutor CloudKit")
struct MemoryTutorCloudKitTests {

    @Test("Source payload carries canonical published DOI identity for Mac and phone")
    func sourcePayloadCarriesPublishedDOIIdentity() throws {
        let sender = try KnowledgeStore(inMemory: true)
        var paper = StudioArticle(
            url: "https://doi.org/10.1000/publisher-version",
            title: "Publisher identity",
            sourceType: .paper,
            id: "published-doi-source"
        )
        paper.doi = "10.1000/preprint-version"
        try sender.saveSource(paper)
        try sender.execBind(
            "UPDATE papers SET published_doi = ? WHERE source_id = ?",
            { statement in
                sender.bind(statement, 1, "10.1000/publisher-version")
                sender.bind(statement, 2, paper.id)
            }
        )
        let change = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == paper.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        let data = try memoryPayloadData(from: record)
        let payload = try JSONDecoder().decode(CloudKitSourcePayload.self, from: data)
        #expect(payload.sourceIdentity?.sourceID == paper.id)
        #expect(payload.sourceIdentity?.doi == "10.1000/preprint-version")
        #expect(payload.sourceIdentity?.publishedDOI == "10.1000/publisher-version")

        // The iPhone decoder reads this optional root sibling without requiring
        // StudioArticle to duplicate the papers-table-only identity field.
        let raw = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let phoneReadableIdentity = try #require(raw["sourceIdentity"] as? [String: Any])
        #expect(phoneReadableIdentity["publishedDOI"] as? String == "10.1000/publisher-version")

        let receiver = try KnowledgeStore(inMemory: true)
        _ = try CloudKitRecordMapper.apply(record: record, to: receiver)
        var receivedPublishedDOI: String?
        try receiver.queryBind(
            "SELECT published_doi FROM papers WHERE source_id = ?",
            bind: { statement in receiver.bind(statement, 1, paper.id) }
        ) { statement in
            receivedPublishedDOI = receiver.string(statement, 0)
        }
        #expect(receivedPublishedDOI == "10.1000/publisher-version")
    }

    @Test("Memory item payload preserves fields, anchors, and remaps source identity")
    func itemRoundTripRemapsSource() throws {
        let sender = try KnowledgeStore(inMemory: true)
        var senderSource = StudioArticle(url: "https://example.com/portable", title: "Portable")
        senderSource.normalizedURL = URLNormalizer.normalize(senderSource.url)
        try sender.saveSource(senderSource)
        let item = makeMemoryItem(sourceID: senderSource.id)
        try sender.saveMemoryItem(item)

        let change = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .memoryItem && $0.logicalKey == item.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))
        #expect(record.recordType == "MemoryItem")
        let outbound = try JSONDecoder().decode(
            CloudKitMemoryItemPayload.self,
            from: memoryPayloadData(from: record)
        )
        #expect(outbound.item == item)
        #expect(outbound.sourceIdentities.map(\.sourceID) == [senderSource.id])

        let receiver = try KnowledgeStore(inMemory: true)
        var receiverSource = StudioArticle(url: senderSource.url, title: "Portable local copy")
        receiverSource.normalizedURL = senderSource.normalizedURL
        try receiver.saveSource(receiverSource)
        _ = try CloudKitRecordMapper.apply(record: record, to: receiver)

        let received = try #require(try receiver.loadMemoryItem(item.id))
        #expect(received.sources.map(\.sourceID) == [receiverSource.id])
        #expect(received.sources.first?.excerpt == item.sources.first?.excerpt)
        #expect(received.goalID == item.goalID)
        #expect(received.rubricJSON == item.rubricJSON)
    }

    @Test("Inbound deterministic Schedule placement replaces and tombstones a legacy random ID")
    func deterministicSchedulePlacementConvergesLegacyRandomID() throws {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(
            url: "https://example.com/legacy-schedule-placement",
            title: "Legacy Schedule placement",
            id: "legacy-placement-source"
        )
        source.normalizedURL = URLNormalizer.normalize(source.url)
        try store.saveSource(source)
        let oldID = "pre-v2-random-placement"
        let oldDate = Date(timeIntervalSinceReferenceDate: 100)
        try store.execBind("""
            INSERT INTO scheduled_sources (
                id, source_id, planned_at, added_at, completed_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, NULL, ?, ?)
        """) { statement in
            store.bind(statement, 1, oldID)
            store.bind(statement, 2, source.id)
            sqlite3_bind_double(statement, 3, oldDate.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 4, oldDate.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 5, oldDate.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 6, oldDate.timeIntervalSinceReferenceDate)
        }
        try store.markRecordChanged(entity: .scheduledSource, logicalKey: oldID, at: oldDate)

        let portableKey = try store.portableMemorySourceKey(sourceID: source.id)
        let deterministicID = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableKey
        )
        let newDate = Date(timeIntervalSinceReferenceDate: 200)
        let merge = try store.saveScheduledSourceRecord(
            CloudKitScheduledSourcePayload(
                placement: ScheduledSource(
                    id: deterministicID,
                    sourceID: "remote-source-alias",
                    plannedAt: newDate,
                    addedAt: newDate,
                    completedAt: newDate,
                    createdAt: newDate,
                    updatedAt: newDate
                ),
                sourceIdentity: CloudKitSourceIdentityPayload(
                    sourceID: "remote-source-alias",
                    url: source.url,
                    normalizedURL: source.normalizedURL,
                    doi: nil,
                    publishedDOI: nil
                )
            )
        )

        #expect(merge.logicalKey == deterministicID)
        #expect(merge.requiresRepublish)
        #expect(try store.scheduledPlacement(forSource: source.id)?.id == deterministicID)
        #expect(try store.hasScheduledSource(oldID) == false)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .scheduledSource
                && $0.logicalKey == oldID
                && $0.operation == .delete
        })
    }

    @Test("Schedule conflict keeps explicit membership edits and monotonic completion in both orders")
    func scheduleConflictSeparatesEditorialAndTutorState() throws {
        func installBase(_ store: KnowledgeStore, sourceID: String) throws -> CloudKitScheduledSourcePayload {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.normalizedURL = URLNormalizer.normalize(source.url)
            try store.saveSource(source)
            let key = try store.portableMemorySourceKey(sourceID: sourceID)
            let date = Date(timeIntervalSinceReferenceDate: 1_000)
            let payload = CloudKitScheduledSourcePayload(
                placement: ScheduledSource(
                    id: MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: key),
                    sourceID: sourceID,
                    plannedAt: date,
                    addedAt: date,
                    completedAt: nil,
                    createdAt: date,
                    updatedAt: date
                ),
                goalIDs: ["keep-goal", "remove-goal"],
                sourceIdentity: try store.sourceIdentities(for: [sourceID]).first
            )
            _ = try store.withoutSyncTracking {
                try store.saveScheduledSourceRecord(payload)
            }
            try store.clearAllPendingSyncChanges()
            return payload
        }

        let removalStore = try KnowledgeStore(inMemory: true)
        let stalePhone = try installBase(removalStore, sourceID: "schedule-removal-source")
        try removalStore.removeSourceFromGoal(
            sourceID: stalePhone.placement.sourceID,
            goalID: "remove-goal"
        )
        #expect(try removalStore.hasPendingTutorOnlySyncChange(
            entity: .scheduledSource,
            logicalKey: stalePhone.placement.id
        ) == false)
        let phoneCompletion = CloudKitScheduledSourcePayload(
            placement: ScheduledSource(
                id: stalePhone.placement.id,
                sourceID: stalePhone.placement.sourceID,
                plannedAt: stalePhone.placement.plannedAt,
                addedAt: stalePhone.placement.addedAt,
                completedAt: Date(timeIntervalSinceReferenceDate: 2_000),
                createdAt: stalePhone.placement.createdAt,
                updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
            ),
            goalIDs: stalePhone.goalIDs,
            sourceIdentity: stalePhone.sourceIdentity
        )
        _ = try removalStore.mergeScheduledSourceServerConflict(
            phoneCompletion,
            preferLocalEditorial: true
        )
        #expect(try removalStore.scheduledSourceGoalIDs(
            sourceID: stalePhone.placement.sourceID
        ) == ["keep-goal"])
        #expect(try removalStore.scheduledPlacement(
            forSource: stalePhone.placement.sourceID
        )?.completedAt == phoneCompletion.placement.completedAt)

        let reviewStore = try KnowledgeStore(inMemory: true)
        let staleLocal = try installBase(reviewStore, sourceID: "schedule-review-source")
        let reviewedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        try reviewStore.recordScheduledSourceReview(
            sourceID: staleLocal.placement.sourceID,
            on: reviewedAt
        )
        #expect(try reviewStore.hasPendingTutorOnlySyncChange(
            entity: .scheduledSource,
            logicalKey: staleLocal.placement.id
        ))
        let serverRemoval = CloudKitScheduledSourcePayload(
            placement: ScheduledSource(
                id: staleLocal.placement.id,
                sourceID: staleLocal.placement.sourceID,
                plannedAt: staleLocal.placement.plannedAt,
                addedAt: staleLocal.placement.addedAt,
                completedAt: nil,
                createdAt: staleLocal.placement.createdAt,
                updatedAt: reviewedAt.addingTimeInterval(1)
            ),
            goalIDs: ["keep-goal"],
            sourceIdentity: staleLocal.sourceIdentity
        )
        _ = try reviewStore.mergeScheduledSourceServerConflict(
            serverRemoval,
            preferLocalEditorial: false
        )
        #expect(try reviewStore.scheduledSourceGoalIDs(
            sourceID: staleLocal.placement.sourceID
        ) == ["keep-goal"])
        #expect(try reviewStore.scheduledPlacement(
            forSource: staleLocal.placement.sourceID
        )?.completedAt != nil)
    }

    @Test("Listening depth crosses devices and keeps the furthest point reached")
    func scheduleSyncPreservesListeningDepth() throws {
        let sender = try KnowledgeStore(inMemory: true)
        let receiver = try KnowledgeStore(inMemory: true)
        var remoteSource = StudioArticle(
            url: "https://example.com/depth-sync",
            title: "Remote depth source",
            id: "remote-depth-source"
        )
        remoteSource.normalizedURL = URLNormalizer.normalize(remoteSource.url)
        var localSource = StudioArticle(
            url: remoteSource.url,
            title: "Local depth source",
            id: "local-depth-source"
        )
        localSource.normalizedURL = remoteSource.normalizedURL
        try sender.saveSource(remoteSource)
        try receiver.saveSource(localSource)

        let day = Date(timeIntervalSinceReferenceDate: 10_000)
        // The phone gets three quarters of the way through an episode.
        _ = try sender.recordScheduledSourceActivity(
            sourceID: remoteSource.id,
            on: day,
            kind: .listening,
            fraction: 0.75
        )
        let senderPlacement = try #require(
            try sender.scheduledPlacement(forSource: remoteSource.id)
        )
        let payload = try #require(
            try sender.loadScheduledSourceForSync(senderPlacement.id)
        )
        _ = try receiver.saveScheduledSourceRecord(payload)

        var received = try #require(
            try receiver.loadScheduledSources().first { $0.placement.sourceID == localSource.id }
        )
        #expect(received.activityDays.count == 1)
        #expect(received.activityDays[0].maxFraction == 0.75)

        // The Mac then replays an earlier stretch of the same episode. A shallower
        // sample from the second device must not retract the furthest point.
        _ = try receiver.recordScheduledSourceActivity(
            sourceID: localSource.id,
            on: day.addingTimeInterval(60),
            kind: .listening,
            fraction: 0.2
        )
        let conflict = try receiver.mergeScheduledSourceServerConflict(
            payload,
            preferLocalEditorial: false
        )
        #expect(conflict.requiresRepublish)
        received = try #require(
            try receiver.loadScheduledSources().first { $0.placement.sourceID == localSource.id }
        )
        #expect(received.activityDays[0].maxFraction == 0.75)
    }

    @Test("Notebook conflict keeps explicit source removal without losing phone quiz evidence")
    func learningGoalConflictSeparatesEditorialAndTutorState() throws {
        func installGoal(
            _ store: KnowledgeStore,
            prefix: String
        ) throws -> (LearningGoalRecord, StudioArticle, StudioArticle) {
            let first = StudioArticle(
                url: "https://example.com/\(prefix)-first",
                title: "First",
                id: "\(prefix)-first"
            )
            let removed = StudioArticle(
                url: "https://example.com/\(prefix)-removed",
                title: "Removed",
                id: "\(prefix)-removed"
            )
            try store.saveSource(first)
            try store.saveSource(removed)
            let goal = try store.createCompanionGoal(
                title: "Conflict notebook",
                topic: "retrieval",
                startAt: Date(timeIntervalSinceReferenceDate: 1_000),
                endAt: Date(timeIntervalSinceReferenceDate: 9_000),
                dailyTarget: 2,
                discoveryEnabled: false,
                seedSourceIDs: [first.id, removed.id]
            )
            try store.clearAllPendingSyncChanges()
            return (try #require(try store.loadLearningGoal(goal.id)), first, removed)
        }

        let removalStore = try KnowledgeStore(inMemory: true)
        let (stalePhoneGoal, first, removed) = try installGoal(
            removalStore,
            prefix: "goal-removal"
        )
        try removalStore.removeCompanionSources(
            goalID: stalePhoneGoal.id,
            sourceIDs: [removed.id]
        )
        #expect(try removalStore.hasPendingTutorOnlySyncChange(
            entity: .learningGoal,
            logicalKey: stalePhoneGoal.id
        ) == false)
        var phoneCompletion = stalePhoneGoal
        phoneCompletion.updatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let firstIndex = try #require(
            phoneCompletion.items.firstIndex { $0.sourceID == first.id }
        )
        phoneCompletion.items[firstIndex].completedAt = phoneCompletion.updatedAt
        phoneCompletion.items[firstIndex].lastQuizzedAt = phoneCompletion.updatedAt
        phoneCompletion.items[firstIndex].quizCount = 1
        phoneCompletion.items[firstIndex].lastScore = 0.9
        _ = try removalStore.mergeLearningGoalServerConflict(
            CloudKitLearningGoalPayload(goal: phoneCompletion, linkedCourseIDs: []),
            preferLocalEditorial: true
        )
        let removalMerged = try #require(try removalStore.loadLearningGoal(stalePhoneGoal.id))
        #expect(removalMerged.items.contains { $0.sourceID == removed.id } == false)
        #expect(removalMerged.items.first { $0.sourceID == first.id }?.quizCount == 1)
        #expect(removalMerged.items.first { $0.sourceID == first.id }?.completedAt != nil)

        let reviewStore = try KnowledgeStore(inMemory: true)
        let (staleServerGoal, reviewed, serverRemoved) = try installGoal(
            reviewStore,
            prefix: "goal-review"
        )
        try reviewStore.recordCompanionQuiz(
            goalID: staleServerGoal.id,
            sourceIDs: [reviewed.id],
            score: 0.8,
            quizDate: "2026-08-11"
        )
        #expect(try reviewStore.hasPendingTutorOnlySyncChange(
            entity: .learningGoal,
            logicalKey: staleServerGoal.id
        ))
        var serverRemoval = staleServerGoal
        serverRemoval.updatedAt = Date(timeIntervalSinceReferenceDate: 11_000)
        serverRemoval.items.removeAll { $0.sourceID == serverRemoved.id }
        _ = try reviewStore.mergeLearningGoalServerConflict(
            CloudKitLearningGoalPayload(goal: serverRemoval, linkedCourseIDs: []),
            preferLocalEditorial: false
        )
        let reviewMerged = try #require(try reviewStore.loadLearningGoal(staleServerGoal.id))
        #expect(reviewMerged.items.contains { $0.sourceID == serverRemoved.id } == false)
        #expect(reviewMerged.items.first { $0.sourceID == reviewed.id }?.quizCount == 1)
        #expect(reviewMerged.items.first { $0.sourceID == reviewed.id }?.lastScore == 0.8)
    }

    @Test("Inbound divergent curriculum archives the local loser and adopts the server winner")
    func inboundMemoryItemArchivesDivergentCurriculum() throws {
        let url = "https://example.com/immutable-memory-sync"
        let sender = try KnowledgeStore(inMemory: true)
        let receiver = try KnowledgeStore(inMemory: true)
        var remoteSource = StudioArticle(url: url, title: "Remote", id: "remote-immutable-source")
        remoteSource.normalizedURL = URLNormalizer.normalize(url)
        var localSource = StudioArticle(url: url, title: "Local", id: "local-immutable-source")
        localSource.normalizedURL = URLNormalizer.normalize(url)
        try sender.saveSource(remoteSource)
        try receiver.saveSource(localSource)
        let canonical = makeMemoryItem(id: "immutable-sync-item", sourceID: localSource.id)
        try receiver.saveMemoryItem(canonical)
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        try receiver.createReviewSession(
            id: "immutable-local-session",
            topic: "Local curriculum review",
            sourceIDs: [localSource.id]
        )
        _ = try receiver.addReviewExchange(
            sessionID: "immutable-local-session",
            question: "Teach the retrieval effect without using the phrase itself.",
            answer: "Recall is productive effort that makes another recall more likely.",
            evaluation: "You explained the mechanism and distinguished it from rereading.",
            score: 0.86,
            knowledgeNote: nil,
            sourceRefs: [localSource.id],
            answeredAt: attemptedAt
        )
        let exchange = try #require(
            try receiver.loadReviewSessionExchanges(
                sessionID: "immutable-local-session"
            ).first
        )
        let exchangeAnswer = try #require(exchange.userAnswer)
        let localAttempt = MemoryAttempt(
            id: "immutable-local-attempt",
            memoryItemID: canonical.id,
            sessionID: "immutable-local-session",
            exchangeID: exchange.id,
            attemptType: .review,
            prompt: exchange.question,
            learnerAnswer: exchangeAnswer,
            feedback: exchange.evaluation,
            score: exchange.score,
            scheduleRating: .good,
            gradeState: .graded,
            evidenceJSON: #"{"sourceAnchorIDs":["anchor-immutable-sync-item"]}"#,
            attemptedAt: attemptedAt,
            modelProvider: "openrouter",
            modelID: "configured-model",
            modelMetadataJSON: #"{"responseID":"response-1"}"#
        )
        try receiver.recordMemoryAttempt(localAttempt)
        let divergent = MemoryItem(
            id: canonical.id,
            kind: canonical.kind,
            target: "A conflicting semantic target from another device.",
            rubricJSON: canonical.rubricJSON,
            learnerContext: canonical.learnerContext,
            goalID: canonical.goalID,
            status: canonical.status,
            sources: canonical.sources.map {
                MemoryItemSource(
                    id: $0.id,
                    memoryItemID: $0.memoryItemID,
                    sourceID: remoteSource.id,
                    locatorJSON: $0.locatorJSON,
                    excerpt: $0.excerpt,
                    sourceSHA256: $0.sourceSHA256,
                    sortIndex: $0.sortIndex
                )
            },
            createdAt: canonical.createdAt,
            updatedAt: canonical.updatedAt.addingTimeInterval(1)
        )
        try sender.saveMemoryItem(divergent)
        let change = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .memoryItem && $0.logicalKey == divergent.id
        })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))

        // A canonical server attempt can be quarantined in an earlier page and
        // then deleted before the divergent parent arrives. Its retained payload
        // must be consumed by the tombstone, not replayed during parent adoption.
        let deletedServerAttempt = makeMemoryAttempt(
            id: "deleted-server-attempt",
            itemID: canonical.id,
            attemptedAt: attemptedAt.addingTimeInterval(1)
        )
        let deletedAttemptRecordName = CloudKitRecordMapper.recordName(
            for: .memoryAttempt,
            logicalKey: deletedServerAttempt.id
        )
        try receiver.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .memoryAttempt,
            logicalKey: deletedServerAttempt.id,
            recordName: deletedAttemptRecordName,
            reason: "Server child arrived before its divergent parent.",
            localModificationDate: deletedServerAttempt.attemptedAt,
            serverModificationDate: deletedServerAttempt.attemptedAt,
            detectedAt: deletedServerAttempt.attemptedAt,
            serverPayload: try JSONEncoder().encode(
                CloudKitMemoryAttemptPayload(attempt: deletedServerAttempt)
            ),
            serverSystemFields: Data("deleted-server-attempt-fields".utf8)
        ))
        #expect(try receiver.resolveQuarantinedMemoryAttemptServerDeletion(
            recordName: deletedAttemptRecordName,
            deletedAt: attemptedAt.addingTimeInterval(2)
        ))

        _ = try CloudKitRecordMapper.apply(record: record, to: receiver)

        let serverWinner = try #require(try receiver.loadMemoryItem(canonical.id))
        #expect(serverWinner.target == divergent.target)
        #expect(serverWinner.sources.map(\.sourceID) == [localSource.id])
        let archiveID = MemoryTutorIdentity.conflictArchiveItemID(for: canonical)
        let archive = try #require(try receiver.loadMemoryItem(archiveID))
        #expect(archive.target == canonical.target)
        #expect(archive.status == .retired)
        #expect(archive.sources.allSatisfy { $0.memoryItemID == archiveID })
        let archivedAttempts = try receiver.loadMemoryAttempts(memoryItemID: archiveID)
        #expect(archivedAttempts.count == 1)
        #expect(archivedAttempts.first?.id == MemoryTutorIdentity.conflictArchiveAttemptID(
            originalAttemptID: localAttempt.id,
            archiveItemID: archiveID
        ))
        #expect(archivedAttempts.first?.prompt == localAttempt.prompt)
        #expect(archivedAttempts.first?.sessionID == localAttempt.sessionID)
        #expect(archivedAttempts.first?.exchangeID == localAttempt.exchangeID)
        #expect(try receiver.loadReviewSessionExchanges(
            sessionID: "immutable-local-session"
        ).first?.id == exchange.id)
        #expect(try receiver.loadMemoryAttempts(memoryItemID: canonical.id).isEmpty)
        #expect(try receiver.loadMemoryAttempt(deletedServerAttempt.id) == nil)
        #expect(try receiver.hasSyncConflict(
            entity: .memoryAttempt,
            logicalKey: deletedServerAttempt.id
        ) == false)
        #expect(try receiver.loadSyncMetadata(
            entity: .memoryAttempt,
            logicalKey: deletedServerAttempt.id
        )?.isDeleted == true)
        #expect(try receiver.pendingSyncChanges().contains {
            $0.entity == .memoryItem && $0.logicalKey == archiveID
        })
        #expect(try receiver.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt && $0.logicalKey == archivedAttempts[0].id
        } == false)
        try receiver.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .memoryItem,
            logicalKey: archiveID,
            recordName: CloudKitRecordMapper.recordName(
                for: .memoryItem,
                logicalKey: archiveID
            ),
            systemFieldsData: Data("archive-parent-ack".utf8),
            userModificationDate: archive.updatedAt,
            isDeleted: false
        ))
        #expect(try receiver.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt && $0.logicalKey == archivedAttempts[0].id
        })
    }

    @Test("Inbound curriculum adoption locks before reading local item and linked evidence")
    func inboundMemoryItemAdoptionIncludesPreLockLinkedAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-item-adoption-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let inboundStore = try KnowledgeStore(storeDirectory: directory)
        let localStore = try KnowledgeStore(storeDirectory: directory)
        var source = StudioArticle(
            url: "https://example.com/memory-adoption-lock",
            title: "Memory adoption lock",
            id: "memory-adoption-lock-source"
        )
        source.normalizedURL = URLNormalizer.normalize(source.url)
        try localStore.saveSource(source)

        let localItem = makeMemoryItem(
            id: "memory-adoption-lock-item",
            sourceID: source.id
        )
        let serverItem = MemoryItem(
            id: localItem.id,
            kind: localItem.kind,
            target: "Explain how desirable difficulty changes later transfer.",
            rubricJSON: #"{"criteria":["connects effort to transfer","distinguishes immediate fluency"]}"#,
            learnerContext: nil,
            goalID: localItem.goalID,
            status: localItem.status,
            sources: localItem.sources,
            createdAt: localItem.createdAt,
            updatedAt: localItem.updatedAt.addingTimeInterval(60)
        )
        let sessionID = "memory-adoption-lock-session"
        let attemptID = "memory-adoption-lock-attempt"
        let attemptedAt = localItem.createdAt.addingTimeInterval(30)

        // This hook is immediately before BEGIN IMMEDIATE. It reproduces the old
        // read-before-lock window by committing both the deterministic curriculum
        // and linked evidence from another connection before inbound takes its lock.
        inboundStore.beforeInboundMemoryItemWriteTransactionForTesting = {
            inboundStore.beforeInboundMemoryItemWriteTransactionForTesting = nil
            try localStore.saveMemoryItem(localItem)
            try localStore.createReviewSession(
                id: sessionID,
                topic: "Curriculum conflict interleaving",
                sourceIDs: [source.id],
                startedAt: attemptedAt
            )
            _ = try localStore.addReviewExchange(
                sessionID: sessionID,
                question: "Explain why effort during retrieval can help later transfer.",
                answer: "The effort reconstructs the idea in a form usable in new contexts.",
                evaluation: "The answer connects reconstruction effort to transfer.",
                score: 0.84,
                knowledgeNote: nil,
                sourceRefs: [source.id],
                answeredAt: attemptedAt
            )
            let exchange = try #require(
                try localStore.loadReviewSessionExchanges(sessionID: sessionID).first
            )
            try localStore.recordMemoryAttempt(MemoryAttempt(
                id: attemptID,
                memoryItemID: localItem.id,
                sessionID: sessionID,
                exchangeID: exchange.id,
                attemptType: .review,
                prompt: exchange.question,
                learnerAnswer: try #require(exchange.userAnswer),
                feedback: exchange.evaluation,
                score: exchange.score,
                scheduleRating: .good,
                gradeState: .graded,
                evidenceJSON: #"{"sourceAnchorIDs":["anchor-memory-adoption-lock-item"]}"#,
                attemptedAt: attemptedAt,
                modelProvider: "openrouter",
                modelID: "configured-model",
                modelMetadataJSON: #"{"responseID":"adoption-lock-response"}"#
            ))
        }

        try inboundStore.saveMemoryItemRecord(CloudKitMemoryItemPayload(item: serverItem))

        let canonical = try #require(try inboundStore.loadMemoryItem(serverItem.id))
        #expect(canonical.target == serverItem.target)
        let archiveID = MemoryTutorIdentity.conflictArchiveItemID(for: localItem)
        let archive = try #require(try inboundStore.loadMemoryItem(archiveID))
        #expect(archive.target == localItem.target)
        #expect(archive.status == .retired)
        let archivedAttemptID = MemoryTutorIdentity.conflictArchiveAttemptID(
            originalAttemptID: attemptID,
            archiveItemID: archiveID
        )
        let archivedAttempt = try #require(try inboundStore.loadMemoryAttempt(archivedAttemptID))
        #expect(archivedAttempt.memoryItemID == archiveID)
        #expect(archivedAttempt.sessionID == sessionID)
        #expect(archivedAttempt.exchangeID != nil)
        #expect(try inboundStore.loadMemoryAttempt(attemptID) == nil)
        #expect(try inboundStore.loadMemoryAttemptParentCurriculumFingerprint(
            id: archivedAttemptID
        ) == MemoryTutorIdentity.immutableCurriculumFingerprint(archive))
        let exchangeIDs = try inboundStore.loadReviewSessionExchanges(
            sessionID: sessionID
        ).map(\.id)
        #expect(exchangeIDs == [archivedAttempt.exchangeID])
    }

    @Test("Learning goal gap-only source relationships remap and round trip")
    func learningGoalGapSourceIdentityRoundTrip() throws {
        let store = try KnowledgeStore(inMemory: true)
        let url = "https://example.com/gap-only-source"
        var localSource = StudioArticle(
            url: url,
            title: "Gap-only local source",
            id: "local-gap-source"
        )
        localSource.normalizedURL = URLNormalizer.normalize(url)
        try store.saveSource(localSource)
        let now = Date(timeIntervalSinceReferenceDate: 7_500)
        let remoteGap = LearningGoalGap(
            id: "gap-only-relationship",
            goalID: "goal-gap-only",
            summary: "Revisit the source-specific distinction.",
            sourceID: "remote-gap-source",
            status: "open",
            severity: 0.4,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: nil
        )
        let remoteGoal = LearningGoalRecord(
            id: "goal-gap-only",
            title: "Gap relationship",
            startAt: now,
            endAt: now.addingTimeInterval(86_400),
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: [],
            gaps: [remoteGap]
        )
        try store.saveLearningGoalRecord(CloudKitLearningGoalPayload(
            goal: remoteGoal,
            sourceIdentities: [
                CloudKitSourceIdentityPayload(
                    sourceID: "remote-gap-source",
                    url: url,
                    normalizedURL: URLNormalizer.normalize(url),
                    doi: nil,
                    publishedDOI: nil
                )
            ]
        ))

        let stored = try #require(try store.loadLearningGoal(remoteGoal.id))
        #expect(stored.gaps?.first?.sourceID == localSource.id)
        let outbound = try #require(try store.loadLearningGoalForSync(remoteGoal.id))
        #expect(outbound.sourceIdentities.map(\.sourceID) == [localSource.id])
        #expect(outbound.goal.gaps?.first?.sourceID == localSource.id)
    }

    @Test("Item arriving before Source retains identity and reconciles when Source appears")
    func itemBeforeSourceReconcilesLater() throws {
        let sender = try KnowledgeStore(inMemory: true)
        var remoteSource = StudioArticle(url: "https://example.com/later-source", title: "Later")
        remoteSource.normalizedURL = URLNormalizer.normalize(remoteSource.url)
        try sender.saveSource(remoteSource)
        let item = makeMemoryItem(sourceID: remoteSource.id)
        try sender.saveMemoryItem(item)
        let change = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .memoryItem && $0.logicalKey == item.id
        })
        let itemRecord = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: sender))

        let receiver = try KnowledgeStore(inMemory: true)
        _ = try CloudKitRecordMapper.apply(record: itemRecord, to: receiver)
        #expect(try receiver.loadMemoryItem(item.id)?.sources.first?.sourceID == remoteSource.id)

        var localSource = StudioArticle(
            url: remoteSource.url,
            title: "Local later copy",
            id: "receiver-local-source"
        )
        localSource.normalizedURL = remoteSource.normalizedURL
        #expect(localSource.id != remoteSource.id)
        try receiver.saveSource(localSource)

        let reconciled = try #require(try receiver.loadMemoryItem(item.id))
        #expect(reconciled.sources.first?.sourceID == localSource.id)
        let republished = try #require(try receiver.loadMemoryItemForSync(item.id))
        #expect(republished.sourceIdentities.first?.sourceID == localSource.id)
        #expect(republished.sourceIdentities.first?.normalizedURL == remoteSource.normalizedURL)
    }

    @Test("Item arriving before Source reconciles by published DOI alone")
    func itemBeforeSourceReconcilesByPublishedDOI() throws {
        let publishedDOI = "10.1000/published-only"
        let itemSender = try KnowledgeStore(inMemory: true)
        let remotePaper = StudioArticle(
            url: "https://remote.example/preprint",
            title: "Remote paper",
            sourceType: .paper,
            id: "remote-paper-id"
        )
        try itemSender.saveSource(remotePaper)
        try itemSender.execBind(
            "UPDATE papers SET published_doi = ? WHERE source_id = ?",
            { statement in
                itemSender.bind(statement, 1, publishedDOI)
                itemSender.bind(statement, 2, remotePaper.id)
            }
        )
        let item = makeMemoryItem(id: "published-only-item", sourceID: remotePaper.id)
        try itemSender.saveMemoryItem(item)
        let itemChange = try #require(try itemSender.pendingSyncChanges().first {
            $0.entity == .memoryItem && $0.logicalKey == item.id
        })
        let itemRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: itemChange, store: itemSender)
        )

        // Another device independently holds the same published work under a
        // different source ID and URL. publishedDOI is the only shared identity.
        let sourceSender = try KnowledgeStore(inMemory: true)
        let localPaper = StudioArticle(
            url: "https://publisher.example/final",
            title: "Local publisher copy",
            sourceType: .paper,
            id: "local-paper-id"
        )
        try sourceSender.saveSource(localPaper)
        try sourceSender.execBind(
            "UPDATE papers SET published_doi = ? WHERE source_id = ?",
            { statement in
                sourceSender.bind(statement, 1, publishedDOI.uppercased())
                sourceSender.bind(statement, 2, localPaper.id)
            }
        )
        let sourceChange = try #require(try sourceSender.pendingSyncChanges().first {
            $0.entity == .source && $0.logicalKey == localPaper.id
        })
        let sourceRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: sourceChange, store: sourceSender)
        )

        let receiver = try KnowledgeStore(inMemory: true)
        _ = try CloudKitRecordMapper.apply(record: itemRecord, to: receiver)
        #expect(try receiver.loadMemoryItem(item.id)?.sources.first?.sourceID == remotePaper.id)

        _ = try CloudKitRecordMapper.apply(record: sourceRecord, to: receiver)
        let reconciled = try #require(try receiver.loadMemoryItem(item.id))
        #expect(reconciled.sources.first?.sourceID == localPaper.id)
        #expect(try receiver.sourceIDByDOI(publishedDOI) == localPaper.id)
    }

    @Test("Duplicate portable identity never steals an existing exact memory or Schedule relationship")
    func exactSourceRelationshipSurvivesDuplicateIdentityResave() throws {
        let store = try KnowledgeStore(inMemory: true)
        let url = "https://example.com/shared-portable-identity"
        let normalizedURL = URLNormalizer.normalize(url)
        var original = StudioArticle(
            url: url,
            title: "Original exact source",
            id: "exact-relationship-original"
        )
        original.normalizedURL = normalizedURL
        var duplicate = StudioArticle(
            url: url,
            title: "Later duplicate source",
            id: "exact-relationship-duplicate"
        )
        duplicate.normalizedURL = normalizedURL
        try store.saveSource(original)
        try store.saveSource(duplicate)

        let item = makeMemoryItem(
            id: "exact-relationship-memory",
            sourceID: original.id
        )
        try store.saveMemoryItem(item)
        let reviewedAt = Date(timeIntervalSinceReferenceDate: 8_000)
        try store.recordScheduledSourceReview(sourceID: original.id, on: reviewedAt)
        let originalPlacement = try #require(
            try store.scheduledPlacement(forSource: original.id)
        )

        // Source sync/import may upsert the duplicate again later. Portable
        // identity is only an orphan-repair key; the already-valid exact IDs win.
        duplicate.title = "Duplicate source resaved later"
        try store.saveSource(duplicate)

        #expect(try store.loadMemoryItem(item.id)?.sources.map(\.sourceID) == [original.id])
        #expect(try store.scheduledPlacement(forSource: original.id) == originalPlacement)
        #expect(try store.scheduledPlacement(forSource: duplicate.id) == nil)
    }

    @Test("Repeated Source arrival reconciles anchors through portable identity indexes")
    func sourceReconciliationIsIndexedAtScale() throws {
        let store = try KnowledgeStore(inMemory: true)
        let anchorCount = 10_000
        let arrivingSourceCount = 250
        try store.exec("BEGIN IMMEDIATE")
        do {
            try store.execBind("""
                INSERT INTO memory_items (
                    id, kind, target, rubric_json, learner_context, goal_id,
                    status, created_at, updated_at
                ) VALUES ('scale-memory', 'concept', 'Scale target', '{"criteria":[]}',
                          NULL, NULL, 'active', 1, 1)
            """) { _ in }
            for index in 0..<anchorCount {
                let url = "https://example.com/deferred-source-\(index)"
                try store.execBind("""
                    INSERT INTO memory_item_sources (
                        id, memory_item_id, source_id, locator_json, excerpt,
                        source_sha256, source_url, source_normalized_url,
                        source_doi, source_published_doi, sort_index
                    ) VALUES (?, 'scale-memory', ?, NULL, 'Excerpt', ?, ?, ?, ?, NULL, ?)
                """) { statement in
                    store.bind(statement, 1, "scale-anchor-\(index)")
                    store.bind(statement, 2, "remote-source-\(index)")
                    store.bind(statement, 3, String(repeating: "a", count: 64))
                    store.bind(statement, 4, url)
                    store.bind(statement, 5, URLNormalizer.normalize(url))
                    store.bind(statement, 6, "10.1000/deferred-\(index)")
                    sqlite3_bind_int64(statement, 7, Int64(index))
                }
            }
            try store.exec("COMMIT")
        } catch {
            try? store.exec("ROLLBACK")
            throw error
        }

        let indexedQueries = [
            ("idx_memory_item_sources_identity_url", "source_normalized_url"),
            ("idx_memory_item_sources_identity_doi", "source_doi"),
            ("idx_memory_item_sources_identity_published_doi", "source_published_doi"),
        ]
        for (indexName, column) in indexedQueries {
            var details: [String] = []
            try store.query("""
                EXPLAIN QUERY PLAN
                SELECT id, source_id
                FROM memory_item_sources INDEXED BY \(indexName)
                WHERE \(column) = 'probe' AND source_id <> 'local'
                  AND NOT EXISTS (
                      SELECT 1
                      FROM sources AS exact_source
                      WHERE exact_source.id = memory_item_sources.source_id
                  )
            """) { statement in
                if let detail = store.string(statement, 3) {
                    details.append(detail)
                }
            }
            #expect(details.contains { $0.contains("USING INDEX \(indexName)") })
            #expect(!details.contains { $0.contains("SCAN memory_item_sources") })
            #expect(!details.contains { $0.contains("SCAN exact_source") })
        }
        let paperIdentityQueries = [
            ("idx_papers_doi_nocase", "doi"),
            ("idx_papers_published_doi_nocase", "published_doi"),
        ]
        for (indexName, column) in paperIdentityQueries {
            var details: [String] = []
            try store.query("""
                EXPLAIN QUERY PLAN
                SELECT source_id
                FROM papers INDEXED BY \(indexName)
                WHERE \(column) = 'probe' COLLATE NOCASE
                ORDER BY source_id
                LIMIT 1
            """) { statement in
                if let detail = store.string(statement, 3) { details.append(detail) }
            }
            #expect(details.contains { $0.contains("USING INDEX \(indexName)") })
            #expect(!details.contains { $0.contains("SCAN papers") })
        }

        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<arrivingSourceCount {
            let url = "https://example.com/deferred-source-\(index)"
            let source = StudioArticle(
                url: url,
                title: "Arriving \(index)",
                id: "local-reconcile-\(index)"
            )
            try store.saveSource(source)
        }
        let elapsed = started.duration(to: clock.now)

        var reconciledCount = 0
        try store.query("""
            SELECT COUNT(*)
            FROM memory_item_sources
            WHERE source_id LIKE 'local-reconcile-%'
        """) { statement in
            reconciledCount = Int(sqlite3_column_int64(statement, 0))
        }
        #expect(reconciledCount == arrivingSourceCount)
        #expect(elapsed < .seconds(10))
    }

    @Test("Immutable attempt may arrive before its item and rebuilds schedule later")
    func attemptThenItemRoundTrip() throws {
        let sender = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let attempt = makeMemoryAttempt()
        try sender.saveMemoryItem(item)
        try sender.recordMemoryAttempt(attempt)

        let itemChange = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .memoryItem
        })
        #expect(try sender.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt
        } == false)
        let itemRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: itemChange, store: sender)
        )
        // Child saves remain queued but ineligible until CloudKit has
        // acknowledged the immutable parent. This keeps the 100-record send cap
        // from splitting a new attempt ahead of its curriculum.
        try sender.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .memoryItem,
            logicalKey: item.id,
            recordName: CloudKitRecordMapper.recordName(
                for: .memoryItem,
                logicalKey: item.id
            ),
            systemFieldsData: Data("acknowledged-parent".utf8),
            userModificationDate: item.updatedAt,
            isDeleted: false
        ))
        let attemptChange = try #require(try sender.pendingSyncChanges().first {
            $0.entity == .memoryAttempt
        })
        let attemptRecord = try #require(try CloudKitRecordMapper.makeRecord(for: attemptChange, store: sender))
        #expect(attemptRecord.recordType == "MemoryAttempt")
        let attemptPayload = try JSONDecoder().decode(
            CloudKitMemoryAttemptPayload.self,
            from: memoryPayloadData(from: attemptRecord)
        )
        #expect(attemptPayload.payloadVersion == 2)
        #expect(attemptPayload.parentCurriculumFingerprint == MemoryTutorIdentity
            .immutableCurriculumFingerprint(item))
        #expect(CloudKitRecordMapper.inboundApplicationPriority(for: itemRecord) < CloudKitRecordMapper.inboundApplicationPriority(for: attemptRecord))

        let receiver = try KnowledgeStore(inMemory: true)
        _ = try CloudKitRecordMapper.apply(record: attemptRecord, to: receiver)
        #expect(try receiver.loadMemoryAttempt(attempt.id) == attempt)
        #expect(try receiver.loadMemorySchedule(memoryItemID: item.id) == nil)

        _ = try CloudKitRecordMapper.apply(record: itemRecord, to: receiver)
        #expect(try receiver.loadMemoryItem(item.id) == item)
        #expect(try receiver.loadMemorySchedule(memoryItemID: item.id)?.repetitionCount == 1)
        let descriptor = try CloudKitRecordMapper.descriptor(for: attemptRecord)
        #expect(descriptor.entity == .memoryAttempt)
        #expect(descriptor.logicalKey == attempt.id)
    }

    @Test("Outbound attempts fail closed until their parent curriculum is available")
    func outboundAttemptRequiresParentCurriculumFingerprint() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem(id: "outbound-parent-barrier")
        let attempt = makeMemoryAttempt(
            id: "outbound-parent-barrier-attempt",
            itemID: item.id
        )

        try store.recordMemoryAttempt(attempt)
        #expect(throws: (any Error).self) {
            _ = try store.loadMemoryAttemptForSync(attempt.id)
        }
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt && $0.logicalKey == attempt.id
        } == false)

        try store.saveMemoryItem(item)
        let payload = try #require(try store.loadMemoryAttemptForSync(attempt.id))
        #expect(payload.payloadVersion == 2)
        #expect(payload.parentCurriculumFingerprint == MemoryTutorIdentity
            .immutableCurriculumFingerprint(item))
    }

    @Test("Parent fingerprints quarantine both divergent attempt delivery orders")
    func attemptParentFingerprintCrossOrder() throws {
        let itemA = makeMemoryItem(id: "fingerprint-parent")
        let itemB = MemoryItem(
            id: itemA.id,
            kind: itemA.kind,
            target: "Explain a different server-canonical concept.",
            rubricJSON: #"{"criteria":["server criterion"]}"#,
            learnerContext: nil,
            goalID: itemA.goalID,
            status: .active,
            sources: itemA.sources,
            createdAt: itemA.createdAt,
            updatedAt: itemA.updatedAt.addingTimeInterval(1)
        )
        let fingerprintA = MemoryTutorIdentity.immutableCurriculumFingerprint(itemA)
        let fingerprintB = MemoryTutorIdentity.immutableCurriculumFingerprint(itemB)
        #expect(fingerprintA != fingerprintB)

        let senderB = try KnowledgeStore(inMemory: true)
        let attemptB = makeMemoryAttempt(
            id: "fingerprint-attempt-b",
            itemID: itemB.id,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 12_000)
        )
        try senderB.saveMemoryItem(itemB)
        try senderB.recordMemoryAttempt(attemptB)
        let itemBChange = try #require(try senderB.pendingSyncChanges().first {
            $0.entity == .memoryItem
        })
        let itemBRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: itemBChange, store: senderB)
        )
        try senderB.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .memoryItem,
            logicalKey: itemB.id,
            recordName: itemBChange.recordName,
            systemFieldsData: Data("server-b-item-fields".utf8),
            userModificationDate: itemB.updatedAt,
            isDeleted: false
        ))
        let attemptBChange = try #require(try senderB.pendingSyncChanges().first {
            $0.entity == .memoryAttempt
        })
        let attemptBRecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: attemptBChange, store: senderB)
        )
        let attemptBPayloadData = try memoryPayloadData(from: attemptBRecord)

        // Server B attempt arrives while the local, unacknowledged A parent is
        // present. Direct persistence fails closed; the engine retains the full
        // record in conflict storage until B's parent arrives.
        let localA = try KnowledgeStore(inMemory: true)
        let attemptA = makeMemoryAttempt(
            id: "fingerprint-attempt-a",
            itemID: itemA.id,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 11_000)
        )
        try localA.saveMemoryItem(itemA)
        try localA.recordMemoryAttempt(attemptA)
        let malformedV2 = CloudKitMemoryAttemptPayload(
            payloadVersion: 2,
            attempt: makeMemoryAttempt(
                id: "malformed-v2-attempt",
                itemID: itemA.id
            ),
            parentCurriculumFingerprint: nil
        )
        #expect(throws: (any Error).self) {
            try localA.saveMemoryAttemptRecord(malformedV2)
        }
        #expect(try localA.loadMemoryAttempt(malformedV2.attempt.id) == nil)
        #expect(throws: (any Error).self) {
            try localA.requireMatchingImmutableMemoryAttemptRecord(
                CloudKitMemoryAttemptPayload(
                    payloadVersion: 2,
                    attempt: attemptA,
                    parentCurriculumFingerprint: fingerprintB
                )
            )
        }
        #expect(try localA.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt && $0.logicalKey == attemptA.id
        } == false)
        #expect(throws: (any Error).self) {
            _ = try CloudKitRecordMapper.apply(record: attemptBRecord, to: localA)
        }
        #expect(try localA.loadMemoryAttempt(attemptB.id) == nil)
        try localA.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .memoryAttempt,
            logicalKey: attemptB.id,
            recordName: attemptBRecord.recordID.recordName,
            reason: "Parent fingerprint differs until the server item arrives.",
            localModificationDate: attemptB.attemptedAt,
            serverModificationDate: attemptB.attemptedAt,
            detectedAt: attemptB.attemptedAt,
            serverPayload: attemptBPayloadData,
            serverSystemFields: Data("server-b-attempt-fields".utf8)
        ))
        _ = try CloudKitRecordMapper.apply(record: itemBRecord, to: localA)

        let canonicalB = try #require(try localA.loadMemoryItem(itemB.id))
        #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(canonicalB, itemB))
        #expect(try localA.loadMemoryAttempt(attemptB.id) == attemptB)
        #expect(try localA.loadMemoryAttemptParentCurriculumFingerprint(
            id: attemptB.id
        ) == fingerprintB)
        let archiveID = MemoryTutorIdentity.conflictArchiveItemID(for: itemA)
        let archivedAttemptID = MemoryTutorIdentity.conflictArchiveAttemptID(
            originalAttemptID: attemptA.id,
            archiveItemID: archiveID
        )
        #expect(try localA.loadMemoryAttempt(archivedAttemptID)?.prompt == attemptA.prompt)
        let archivedItem = try #require(try localA.loadMemoryItem(archiveID))
        #expect(try localA.loadMemoryAttemptParentCurriculumFingerprint(
            id: archivedAttemptID
        ) == MemoryTutorIdentity.immutableCurriculumFingerprint(
            archivedItem
        ))

        // B attempt arrives first on a fresh device, then the wrong A parent.
        // The attempt stays inert while parentless and is moved to the durable
        // conflict payload—not B evidence scheduled under A—when A appears.
        let parentless = try KnowledgeStore(inMemory: true)
        _ = try CloudKitRecordMapper.apply(record: attemptBRecord, to: parentless)
        #expect(try parentless.loadMemoryAttempt(attemptB.id) == attemptB)
        #expect(try parentless.loadMemorySchedule(memoryItemID: itemB.id) == nil)

        let senderA = try KnowledgeStore(inMemory: true)
        try senderA.saveMemoryItem(itemA)
        let itemAChange = try #require(try senderA.pendingSyncChanges().first {
            $0.entity == .memoryItem
        })
        let itemARecord = try #require(
            try CloudKitRecordMapper.makeRecord(for: itemAChange, store: senderA)
        )
        _ = try CloudKitRecordMapper.apply(record: itemARecord, to: parentless)
        #expect(try parentless.loadMemoryAttempt(attemptB.id) == nil)
        #expect(try parentless.loadMemorySchedule(memoryItemID: itemA.id)?.repetitionCount == 0)
        let retained = try #require(try parentless.loadSyncConflicts().first {
            $0.entity == .memoryAttempt && $0.logicalKey == attemptB.id
        })
        let retainedPayload = try JSONDecoder().decode(
            CloudKitMemoryAttemptPayload.self,
            from: try #require(retained.serverPayload)
        )
        #expect(retainedPayload.attempt == attemptB)
        #expect(retainedPayload.parentCurriculumFingerprint == fingerprintB)
    }

    @Test("Session and attempt delivery orders both enforce exact exchange parity")
    func attemptExchangeParityInBothDeliveryOrders() throws {
        let item = makeMemoryItem()
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 8_000)

        // Session first: a later attempt must match the already-present exchange.
        let sessionFirst = try KnowledgeStore(inMemory: true)
        try sessionFirst.saveMemoryItem(item)
        try sessionFirst.createReviewSession(
            id: "session-first",
            topic: "Session first",
            sourceIDs: []
        )
        _ = try sessionFirst.addReviewExchange(
            sessionID: "session-first",
            question: "Explain retrieval.",
            answer: "Recall without looking.",
            evaluation: "Correct.",
            score: 0.8,
            knowledgeNote: nil,
            sourceRefs: [],
            answeredAt: attemptedAt
        )
        let existingExchange = try #require(
            try sessionFirst.loadReviewSessionExchanges(sessionID: "session-first").first
        )
        let sessionFirstAttempt = MemoryAttempt(
            id: "session-first-attempt",
            memoryItemID: item.id,
            sessionID: "session-first",
            exchangeID: existingExchange.id,
            attemptType: .imported,
            prompt: "Explain retrieval.",
            learnerAnswer: "Recall without looking.",
            feedback: "Correct.",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded,
            attemptedAt: attemptedAt
        )
        try sessionFirst.saveMemoryAttemptRecord(
            CloudKitMemoryAttemptPayload(attempt: sessionFirstAttempt)
        )
        let conflictingAttempt = MemoryAttempt(
            id: "session-first-conflict",
            memoryItemID: item.id,
            sessionID: "session-first",
            exchangeID: existingExchange.id,
            attemptType: .imported,
            prompt: "A different prompt.",
            learnerAnswer: sessionFirstAttempt.learnerAnswer,
            feedback: sessionFirstAttempt.feedback,
            score: sessionFirstAttempt.score,
            scheduleRating: sessionFirstAttempt.scheduleRating,
            gradeState: .graded,
            attemptedAt: attemptedAt
        )
        #expect(throws: (any Error).self) {
            try sessionFirst.saveMemoryAttemptRecord(
                CloudKitMemoryAttemptPayload(attempt: conflictingAttempt)
            )
        }
        #expect(try sessionFirst.loadMemoryAttempt(conflictingAttempt.id) == nil)

        func sessionPayload(question: String) -> CloudKitReviewSessionPayload {
            CloudKitReviewSessionPayload(
                id: "attempt-first",
                topic: "Attempt first",
                startedAt: Date(timeIntervalSinceReferenceDate: 7_900),
                endedAt: attemptedAt,
                status: "completed",
                overallScore: 0.8,
                summary: "Reviewed retrieval.",
                sourceIDs: [],
                cardIDs: [],
                exchangeCount: 1,
                modelProvider: nil,
                modelID: nil,
                goalID: nil,
                exchanges: [
                    CloudKitReviewExchangePayload(
                        id: "attempt-first-exchange",
                        sessionID: "attempt-first",
                        sequenceNumber: 1,
                        question: question,
                        userAnswer: "Recall without looking.",
                        evaluation: "Correct.",
                        score: 0.8,
                        sourceRefs: [],
                        knowledgeNote: nil,
                        answeredAt: attemptedAt
                    )
                ]
            )
        }
        let attemptFirstValue = MemoryAttempt(
            id: "attempt-first-attempt",
            memoryItemID: item.id,
            sessionID: "attempt-first",
            exchangeID: "attempt-first-exchange",
            attemptType: .imported,
            prompt: "Explain retrieval.",
            learnerAnswer: "Recall without looking.",
            feedback: "Correct.",
            score: 0.8,
            scheduleRating: .good,
            gradeState: .graded,
            attemptedAt: attemptedAt
        )

        // Attempt first: absence is permitted; the later aggregate performs the
        // same parity check before either session or exchange commits.
        let attemptFirst = try KnowledgeStore(inMemory: true)
        try attemptFirst.saveMemoryItem(item)
        try attemptFirst.saveMemoryAttemptRecord(
            CloudKitMemoryAttemptPayload(attempt: attemptFirstValue)
        )
        try attemptFirst.saveReviewSessionRecord(sessionPayload(question: "Explain retrieval."))
        #expect(try attemptFirst.loadMemoryAttempt(attemptFirstValue.id) == attemptFirstValue)
        #expect(try attemptFirst.loadReviewSessionForSync("attempt-first")?.exchanges.count == 1)

        let attemptFirstMismatch = try KnowledgeStore(inMemory: true)
        try attemptFirstMismatch.saveMemoryItem(item)
        try attemptFirstMismatch.saveMemoryAttemptRecord(
            CloudKitMemoryAttemptPayload(attempt: attemptFirstValue)
        )
        #expect(throws: (any Error).self) {
            try attemptFirstMismatch.saveReviewSessionRecord(
                sessionPayload(question: "A conflicting transcript prompt.")
            )
        }
        #expect(try attemptFirstMismatch.loadMemoryAttempt(attemptFirstValue.id) == attemptFirstValue)
        #expect(try attemptFirstMismatch.loadReviewSessionForSync("attempt-first") == nil)
    }

    @Test("Attempt arriving after an item or session tombstone is re-tombstoned")
    func lateAttemptCannotResurrectDeletedParent() throws {
        func installParentTombstone(
            _ store: KnowledgeStore,
            entity: CloudKitSyncEntity,
            key: String
        ) throws {
            try store.saveSyncMetadata(
                CloudKitSyncMetadata(
                    entity: entity,
                    logicalKey: key,
                    recordName: CloudKitRecordMapper.recordName(for: entity, logicalKey: key),
                    systemFieldsData: nil,
                    userModificationDate: Date(timeIntervalSinceReferenceDate: 9_000),
                    isDeleted: true
                )
            )
        }

        let itemDeleted = try KnowledgeStore(inMemory: true)
        try installParentTombstone(itemDeleted, entity: .memoryItem, key: "memory-item-1")
        let orphanItemAttempt = makeMemoryAttempt(id: "late-after-item")
        #expect(throws: (any Error).self) {
            try itemDeleted.withoutSyncTracking {
                try itemDeleted.saveMemoryAttemptRecord(
                    CloudKitMemoryAttemptPayload(attempt: orphanItemAttempt)
                )
            }
        }
        #expect(try itemDeleted.loadMemoryAttempt(orphanItemAttempt.id) == nil)
        #expect(try itemDeleted.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt
                && $0.logicalKey == orphanItemAttempt.id
                && $0.operation == .delete
        })
        #expect(try itemDeleted.loadSyncMetadata(
            entity: .memoryAttempt,
            logicalKey: orphanItemAttempt.id
        )?.isDeleted == true)

        let sessionDeleted = try KnowledgeStore(inMemory: true)
        let liveItem = makeMemoryItem()
        try sessionDeleted.saveMemoryItem(liveItem)
        try sessionDeleted.clearAllPendingSyncChanges()
        try installParentTombstone(
            sessionDeleted,
            entity: .reviewSession,
            key: "deleted-before-attempt"
        )
        let orphanSessionAttempt = MemoryAttempt(
            id: "late-after-session",
            memoryItemID: liveItem.id,
            sessionID: "deleted-before-attempt",
            exchangeID: "deleted-before-attempt::exchange",
            attemptType: .imported,
            prompt: "Explain it.",
            learnerAnswer: "An answer.",
            feedback: "Feedback.",
            score: 0.7,
            scheduleRating: .good,
            gradeState: .graded,
            attemptedAt: Date(timeIntervalSinceReferenceDate: 9_100)
        )
        #expect(throws: (any Error).self) {
            try sessionDeleted.withoutSyncTracking {
                try sessionDeleted.saveMemoryAttemptRecord(
                    CloudKitMemoryAttemptPayload(attempt: orphanSessionAttempt)
                )
            }
        }
        #expect(try sessionDeleted.loadMemoryAttempt(orphanSessionAttempt.id) == nil)
        #expect(try sessionDeleted.pendingSyncChanges().contains {
            $0.entity == .memoryAttempt
                && $0.logicalKey == orphanSessionAttempt.id
                && $0.operation == .delete
        })
    }

    @Test("A conflicted curriculum quarantines existing evidence and rejects future attempts")
    func curriculumConflictSuppressesDependentAttempts() throws {
        let store = try KnowledgeStore(inMemory: true)
        let source = StudioArticle(
            url: "https://example.com/conflicted-item-source",
            title: "Conflicted item source",
            id: "source-1"
        )
        try store.saveSource(source)
        let item = makeMemoryItem(id: "conflicted-item")
        let existingAttempt = makeMemoryAttempt(
            id: "conflicted-existing-attempt",
            itemID: item.id
        )
        try store.saveMemoryItem(item)
        try store.recordMemoryAttempt(existingAttempt)

        let detectedAt = Date(timeIntervalSinceReferenceDate: 8_000)
        let earlierServerAttemptPayload = try JSONEncoder().encode(
            CloudKitMemoryAttemptPayload(attempt: existingAttempt)
        )
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .memoryAttempt,
            logicalKey: existingAttempt.id,
            recordName: CloudKitRecordMapper.recordName(
                for: .memoryAttempt,
                logicalKey: existingAttempt.id
            ),
            reason: "Server attempt conflict arrived first.",
            localModificationDate: existingAttempt.attemptedAt,
            serverModificationDate: detectedAt.addingTimeInterval(-1),
            detectedAt: detectedAt.addingTimeInterval(-1),
            serverPayload: earlierServerAttemptPayload,
            serverSystemFields: Data("earlier-attempt-fields".utf8)
        ))
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .memoryItem,
            logicalKey: item.id,
            recordName: CloudKitRecordMapper.recordName(for: .memoryItem, logicalKey: item.id),
            reason: "Divergent deterministic curriculum.",
            localModificationDate: item.updatedAt,
            serverModificationDate: detectedAt,
            detectedAt: detectedAt,
            serverPayload: Data("server-item".utf8),
            serverSystemFields: Data("server-fields".utf8)
        ))

        let conflicts = try store.loadSyncConflicts()
        #expect(conflicts.contains { $0.entity == .memoryItem && $0.logicalKey == item.id })
        #expect(conflicts.contains {
            $0.entity == .memoryAttempt
                && $0.logicalKey == existingAttempt.id
                && $0.serverPayload == earlierServerAttemptPayload
        })
        #expect(try store.pendingSyncChanges().contains {
            ($0.entity == .memoryItem && $0.logicalKey == item.id)
                || ($0.entity == .memoryAttempt && $0.logicalKey == existingAttempt.id)
        } == false)
        #expect(try store.dueMemoryItems(
            now: detectedAt,
            limit: 5,
            restrictToSourceIDs: [source.id]
        ).isEmpty)

        let futureAttempt = makeMemoryAttempt(
            id: "conflicted-future-attempt",
            itemID: item.id,
            attemptedAt: detectedAt.addingTimeInterval(1)
        )
        #expect(throws: (any Error).self) {
            try store.recordMemoryAttempt(futureAttempt)
        }
        #expect(try store.loadMemoryAttempt(futureAttempt.id) == nil)
        #expect(throws: (any Error).self) {
            try store.saveMemoryAttemptRecord(
                CloudKitMemoryAttemptPayload(attempt: futureAttempt)
            )
        }
        #expect(try store.loadMemoryAttempt(futureAttempt.id) == nil)

        let serverAttemptPayload = try JSONEncoder().encode(
            CloudKitMemoryAttemptPayload(attempt: futureAttempt)
        )
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .memoryAttempt,
            logicalKey: futureAttempt.id,
            recordName: CloudKitRecordMapper.recordName(
                for: .memoryAttempt,
                logicalKey: futureAttempt.id
            ),
            reason: "Blocked by parent curriculum conflict.",
            localModificationDate: futureAttempt.attemptedAt,
            serverModificationDate: futureAttempt.attemptedAt,
            detectedAt: detectedAt,
            serverPayload: serverAttemptPayload,
            serverSystemFields: Data("attempt-fields".utf8)
        ))
        #expect(try store.loadSyncConflicts().contains {
            $0.entity == .memoryAttempt
                && $0.logicalKey == futureAttempt.id
                && $0.serverPayload == serverAttemptPayload
        })

        try store.deleteMemoryItem(item.id)
        #expect(try store.pendingSyncChanges().contains {
            $0.operation == .delete
                && (($0.entity == .memoryItem && $0.logicalKey == item.id)
                    || $0.entity == .memoryAttempt)
        } == false)
        #expect(try store.hasSyncConflict(entity: .memoryItem, logicalKey: item.id))
    }

    @Test("ScheduledSource arriving before Source reconciles through portable identity")
    func scheduledSourceBeforeSourceReconciles() throws {
        let store = try KnowledgeStore(inMemory: true)
        let url = "https://example.com/schedule-before-source"
        let normalizedURL = URLNormalizer.normalize(url)
        let remoteSourceID = "phone-schedule-source"
        let localSourceID = "mac-schedule-source"
        let portableKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: remoteSourceID,
            normalizedURL: normalizedURL,
            doi: nil,
            publishedDOI: nil
        )
        let placementID = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableKey
        )
        let plannedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        let inbound = CloudKitScheduledSourcePayload(
            placement: ScheduledSource(
                id: placementID,
                sourceID: remoteSourceID,
                plannedAt: plannedAt,
                addedAt: plannedAt,
                completedAt: plannedAt.addingTimeInterval(10),
                createdAt: plannedAt,
                updatedAt: plannedAt.addingTimeInterval(10)
            ),
            goalIDs: ["portable-goal"],
            sourceIdentity: CloudKitSourceIdentityPayload(
                sourceID: remoteSourceID,
                url: url,
                normalizedURL: normalizedURL,
                doi: nil,
                publishedDOI: nil
            )
        )
        _ = try store.saveScheduledSourceRecord(inbound)
        #expect(try store.scheduledPlacement(forSource: remoteSourceID)?.id == placementID)

        var source = StudioArticle(url: url, title: "Portable source", id: localSourceID)
        source.normalizedURL = normalizedURL
        try store.saveSource(source)

        #expect(try store.scheduledPlacement(forSource: remoteSourceID) == nil)
        let reconciled = try #require(try store.scheduledPlacement(forSource: localSourceID))
        #expect(reconciled.id == placementID)
        #expect(reconciled.completedAt == plannedAt.addingTimeInterval(10))
        #expect(try store.scheduledSourceGoalIDs(sourceID: localSourceID) == ["portable-goal"])
        #expect(try store.loadAllScheduledSourceIDs() == [placementID])
        let outbound = try #require(try store.loadScheduledSourceForSync(placementID))
        #expect(outbound.sourceIdentity?.sourceID == localSourceID)
        #expect(outbound.sourceIdentity?.normalizedURL == normalizedURL)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .scheduledSource
                && $0.logicalKey == placementID
                && $0.operation == .save
        })
    }

    @Test("Failed-only memory evidence does not advance reviewed source completion")
    func failedAttemptIsNotReviewedSource() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem(id: "failed-only-item", sourceID: "failed-only-source")
        try store.saveMemoryItem(item)
        let failed = MemoryAttempt(
            id: "failed-only-attempt",
            memoryItemID: item.id,
            sessionID: "failed-only-session",
            exchangeID: "failed-only-exchange",
            attemptType: .review,
            prompt: "Explain the concept.",
            learnerAnswer: "I am not sure.",
            feedback: nil,
            score: nil,
            scheduleRating: nil,
            gradeState: .failed,
            gradingError: "The configured grader failed.",
            attemptedAt: Date(timeIntervalSinceReferenceDate: 10_000)
        )
        try store.recordMemoryAttempt(failed)
        #expect(try store.reviewedMemorySourceIDs(sessionID: "failed-only-session").isEmpty)
        #expect(try store.loadMemorySchedule(memoryItemID: item.id)?.dueAt
            == MemoryTutorScheduler.firstEligibleAt(createdAt: item.createdAt))
    }

    @Test("Legacy review aggregates count only successfully graded memory anchors")
    func legacyReviewAggregatesIgnoreFailedMemoryAttempts() throws {
        let store = try KnowledgeStore(inMemory: true)
        let sourceIDs = ["aggregate-graded", "aggregate-failed", "aggregate-failed-only"]
        for sourceID in sourceIDs {
            var source = StudioArticle(
                url: "https://example.com/\(sourceID)",
                title: sourceID,
                id: sourceID
            )
            source.content = "Canonical content for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let gradedItem = makeMemoryItem(
            id: "aggregate-graded-item",
            sourceID: sourceIDs[0]
        )
        let failedItem = makeMemoryItem(
            id: "aggregate-failed-item",
            sourceID: sourceIDs[1]
        )
        let failedOnlyItem = makeMemoryItem(
            id: "aggregate-failed-only-item",
            sourceID: sourceIDs[2]
        )
        try store.saveMemoryItem(gradedItem)
        try store.saveMemoryItem(failedItem)
        try store.saveMemoryItem(failedOnlyItem)

        let mixedEndedAt = Date(timeIntervalSinceReferenceDate: 13_000)
        try store.createReviewSession(
            id: "aggregate-mixed-session",
            topic: "Mixed memory results",
            sourceIDs: [sourceIDs[0], sourceIDs[1]],
            startedAt: mixedEndedAt.addingTimeInterval(-100)
        )
        try store.recordMemoryAttempt(MemoryAttempt(
            id: "aggregate-graded-attempt",
            memoryItemID: gradedItem.id,
            sessionID: "aggregate-mixed-session",
            exchangeID: "aggregate-graded-exchange",
            attemptType: .review,
            prompt: "Explain the graded concept.",
            learnerAnswer: "A complete answer.",
            feedback: "Correct.",
            score: 0.9,
            scheduleRating: .easy,
            gradeState: .graded,
            attemptedAt: mixedEndedAt
        ))
        try store.recordMemoryAttempt(MemoryAttempt(
            id: "aggregate-failed-attempt",
            memoryItemID: failedItem.id,
            sessionID: "aggregate-mixed-session",
            exchangeID: "aggregate-failed-exchange",
            attemptType: .review,
            prompt: "Explain the failed concept.",
            learnerAnswer: "An answer the grader could not assess.",
            feedback: nil,
            score: nil,
            scheduleRating: nil,
            gradeState: .failed,
            gradingError: "Configured grader failed.",
            attemptedAt: mixedEndedAt
        ))
        try store.completeReviewSession(
            sessionID: "aggregate-mixed-session",
            overallScore: 0.9,
            summary: "One grade succeeded; one failed.",
            endedAt: mixedEndedAt
        )

        let failedOnlyEndedAt = mixedEndedAt.addingTimeInterval(100)
        try store.createReviewSession(
            id: "aggregate-failed-only-session",
            topic: "Failed-only memory result",
            sourceIDs: [sourceIDs[2]],
            startedAt: failedOnlyEndedAt.addingTimeInterval(-50)
        )
        try store.recordMemoryAttempt(MemoryAttempt(
            id: "aggregate-failed-only-attempt",
            memoryItemID: failedOnlyItem.id,
            sessionID: "aggregate-failed-only-session",
            exchangeID: "aggregate-failed-only-exchange",
            attemptType: .review,
            prompt: "Explain the failed-only concept.",
            learnerAnswer: "Another ungraded answer.",
            feedback: nil,
            score: nil,
            scheduleRating: nil,
            gradeState: .failed,
            gradingError: "Configured grader failed.",
            attemptedAt: failedOnlyEndedAt
        ))
        try store.completeReviewSession(
            sessionID: "aggregate-failed-only-session",
            overallScore: nil,
            summary: "No grade was persisted.",
            endedAt: failedOnlyEndedAt
        )

        let reviewDates = try store.sourceReviewDates()
        #expect(reviewDates[sourceIDs[0]] == mixedEndedAt)
        #expect(reviewDates[sourceIDs[1]] == nil)
        #expect(reviewDates[sourceIDs[2]] == nil)
        #expect(try store.memoryReviewStats().map(\.sourceID) == [sourceIDs[0]])
    }

    @Test("Bootstrap and orphan cleanup include both memory record types")
    func bootstrapAndOrphanCleanup() throws {
        let store = try KnowledgeStore(inMemory: true)
        let item = makeMemoryItem()
        let attempt = makeMemoryAttempt()
        try store.saveMemoryItem(item)
        try store.recordMemoryAttempt(attempt)
        try store.clearAllPendingSyncChanges()
        try store.clearAllSyncMetadata()

        #expect(try store.enqueueMissingSyncableRecords(at: Date(timeIntervalSinceReferenceDate: 9_000)) == 2)
        #expect(try store.pendingSyncChanges().map(\.entity) == [.memoryItem])
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .memoryItem,
            logicalKey: item.id,
            recordName: CloudKitRecordMapper.recordName(
                for: .memoryItem,
                logicalKey: item.id
            ),
            systemFieldsData: Data("bootstrap-parent-ack".utf8),
            userModificationDate: item.updatedAt,
            isDeleted: false
        ))
        #expect(Set(try store.pendingSyncChanges().map(\.entity)) == [.memoryItem, .memoryAttempt])

        try store.execForTesting("DELETE FROM memory_attempts WHERE id = '\(attempt.id)'")
        let discarded = try store.discardPendingSavesMissingLocalRecords()
        #expect(discarded.contains {
            $0.entity == .memoryAttempt && $0.logicalKey == attempt.id
        })
        #expect(try store.pendingSyncChanges().map(\.entity) == [.memoryItem])
    }
}

/// `MemoryGroundingText`: a Memory anchor is the source's words, whatever the
/// stored text's typesetting did to them.
@Suite("Memory grounding text")
struct MemoryGroundingTextTests {
    /// Two stretches of the Wolf et al. cristae paper as its text is stored,
    /// and of a lecture transcript.
    private let paper = MemoryGroundingText("""
    Impairment of cristae structure through deletion of MICOS-
    complex components or Opa1 diminished this intramitochondrial
    heterogeneity of DΨm. To overcome this limitation, we developed a novel approach
    for imaging the IMM at high spatiotemporal resolution in living
    cells, using the LSM880 with Airyscan as well as STED micro-
    scopy.
    [page 4]
    Different cristae within a mitochondrion can have different DΨm. The \u{FB01}ssion of cristae comp\u{00AD}letes it.
    """)
    private let transcript = MemoryGroundingText("""
    [10:30] Mitochondria are transported on tracks [10:37] which are the microtubules, and they need motors. \
    You have a lot more control over. [0:34] Mitochondrial microenvironment. You’re doing experiments [1:02:03] Both of a cation and of an anion.
    """)

    @Test("A word broken at a line end reads as printed, hyphen kept or joined")
    func lineEndHyphens() {
        #expect(paper.contains("deletion of MICOS-complex components or Opa1 diminished this intramitochondrial heterogeneity"))
        #expect(paper.contains("using the LSM880 with Airyscan as well as STED microscopy"))
        #expect(paper.contains("as well as STED micro-scopy"))
    }

    @Test("Time and page markers, case, punctuation, apostrophes, ligatures and soft hyphens are not words")
    func typesettingIsNotWords() {
        #expect(transcript.contains("Mitochondria are transported on tracks which are the microtubules"))
        #expect(transcript.contains("you have a lot more control over mitochondrial microenvironment"))
        #expect(transcript.contains("you're doing experiments both of a cation and of an anion"))
        #expect(paper.contains("STED microscopy. Different cristae within a mitochondrion"))
        #expect(paper.contains("The fission of cristae completes it"))
    }

    @Test("A quote must be the text's words: whole words, in order, all of them")
    func onlyTheTextsWords() {
        #expect(!paper.contains("deletion of MICOS components diminished this heterogeneity"), "words left out")
        #expect(!paper.contains("it can happen as a uniport"), "words the text never printed")
        #expect(!paper.contains("ristae structure"), "a quote starting inside a word")
        #expect(!paper.contains("cristae struct"), "a quote ending inside a word")
        #expect(!paper.contains("…"), "no words at all")
        #expect(!MemoryGroundingText("").contains("cristae"))
        #expect(MemoryGroundingText("[0:00] ").isEmpty)
    }

    @Test("A quote's place is counted in the text's letters and digits, from where the search may start")
    func offsets() {
        let text = MemoryGroundingText("[0:00] One two. [0:30] Three, four two.")
        #expect(text.letterCount == 18)
        #expect(text.offset(of: "One two") == 0)
        #expect(text.offset(of: "two three") == 3, "across a time marker")
        #expect(text.offset(of: "two", from: 4) == 15)
        #expect(text.offset(of: "two", from: 16) == nil)
        #expect(text.offset(of: "wo") == nil, "inside a word")
    }

    @Test("The store grounds a Memory item in a quote read off the page")
    func storeValidatesAgainstThePage() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(url: "https://example.com/cristae", title: "Individual cristae", sourceType: .article, discoveryOrigin: .manual, id: "cristae")
        article.normalizedURL = URLNormalizer.normalize(article.url)
        article.content = "Impairment of cristae structure through deletion of MICOS-\ncomplex components or Opa1 diminished this intramitochondrial\nheterogeneity of DΨm."
        article.state = .ready
        try store.saveSource(article)

        let quote = "deletion of MICOS-complex components or Opa1 diminished this intramitochondrial heterogeneity"
        let validation = try store.validatedMemorySourceAnchor(sourceID: "cristae", excerpt: "  \(quote) ")
        #expect(validation.excerpt == quote, "the item keeps the quote as the learner reads it")
        #expect(throws: KnowledgeStoreError.self) {
            try store.validatedMemorySourceAnchor(sourceID: "cristae", excerpt: "deletion of Mic60 diminished this heterogeneity")
        }
    }
}
