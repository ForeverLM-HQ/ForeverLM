import Foundation
import Testing
@testable import ForeverLM

@Suite("Memory tutor scheduling")
struct MemoryTutorSchedulerTests {
    private let day = MemoryTutorScheduler.secondsPerDay

    @Test("Due items are bounded, stable, and exclude retired memories")
    func dueOrdering() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldest = item(id: "b", createdAt: now.addingTimeInterval(-3 * day))
        let newer = item(id: "a", createdAt: now.addingTimeInterval(-2 * day))
        let retired = item(
            id: "retired",
            status: .retired,
            createdAt: now.addingTimeInterval(-10 * day)
        )

        let due = MemoryTutorScheduler.dueItems(
            items: [newer, retired, oldest],
            schedules: reviewedSchedules([newer, retired, oldest]),
            now: now,
            limit: 2
        )

        #expect(due.map(\.item.id) == ["b", "a"])
        #expect(due.map(\.daysOverdue) == [3, 2])
        #expect(MemoryTutorScheduler.dueItems(
            items: [oldest],
            schedules: reviewedSchedules([oldest]),
            now: now,
            limit: 0
        ).isEmpty)
        // Never reviewed: new, so never due, however long ago it was kept.
        // The card queue introduces it (`MemoryCardQueue`).
        #expect(MemoryTutorScheduler.dueItems(
            items: [newer, oldest],
            schedules: [:],
            now: now,
            limit: 2
        ).isEmpty)
    }

    @Test("Pure due selection prioritizes every durable struggle signal before limiting")
    func dueOrderingPrioritizesStrugglesBeforeLimit() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldestBacklog = item(
            id: "oldest-backlog",
            createdAt: now.addingTimeInterval(-10 * day)
        )
        let contextual = item(
            id: "contextual",
            createdAt: now.addingTimeInterval(-day),
            learnerContext: "Previously missed the causal step."
        )
        let lapsed = item(
            id: "lapsed",
            createdAt: now.addingTimeInterval(-2 * day)
        )
        let difficult = item(
            id: "difficult",
            createdAt: now.addingTimeInterval(-3 * day)
        )
        let schedules = [
            oldestBacklog.id: MemorySchedule(
                memoryItemID: oldestBacklog.id,
                dueAt: now.addingTimeInterval(-10 * day),
                difficulty: 0.4,
                repetitionCount: 1
            ),
            contextual.id: MemorySchedule(
                memoryItemID: contextual.id,
                dueAt: now.addingTimeInterval(-day),
                difficulty: 0.4,
                repetitionCount: 1
            ),
            lapsed.id: MemorySchedule(
                memoryItemID: lapsed.id,
                dueAt: now.addingTimeInterval(-2 * day),
                difficulty: 0.4,
                repetitionCount: 1,
                lapseCount: 1
            ),
            difficult.id: MemorySchedule(
                memoryItemID: difficult.id,
                dueAt: now.addingTimeInterval(-3 * day),
                difficulty: 0.55,
                repetitionCount: 1
            ),
        ]

        let due = MemoryTutorScheduler.dueItems(
            items: [oldestBacklog, contextual, lapsed, difficult],
            schedules: schedules,
            now: now,
            limit: 3
        )

        #expect(due.map(\.id) == [difficult.id, lapsed.id, contextual.id])
    }

    @Test("Attempt delivery order cannot change the derived schedule")
    func outOfOrderReplay() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "concept", createdAt: created)
        let first = attempt(
            id: "first",
            itemID: memory.id,
            rating: .good,
            at: created.addingTimeInterval(day)
        )
        let second = attempt(
            id: "second",
            itemID: memory.id,
            rating: .hard,
            at: created.addingTimeInterval(3 * day)
        )

        let chronological = MemoryTutorScheduler.schedule(item: memory, attempts: [first, second])
        let reverseDelivery = MemoryTutorScheduler.schedule(item: memory, attempts: [second, first])

        #expect(chronological == reverseDelivery)
        #expect(chronological.repetitionCount == 2)
        #expect(chronological.lastAttemptAt == second.attemptedAt)
    }

    @Test("Pending and failed graders never advance due state")
    func ungradedAttemptsDoNotAdvance() throws {
        let calendar = try losAngeles()
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "concept", createdAt: created)
        let pending = attempt(
            id: "pending",
            itemID: memory.id,
            gradeState: .pending,
            rating: nil,
            at: created.addingTimeInterval(day)
        )
        let failed = attempt(
            id: "failed",
            itemID: memory.id,
            gradeState: .failed,
            rating: nil,
            at: created.addingTimeInterval(2 * day)
        )

        let schedule = MemoryTutorScheduler.schedule(
            item: memory,
            attempts: [failed, pending],
            calendar: calendar
        )

        #expect(schedule.isNew)
        #expect(schedule.dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: created, calendar: calendar))
        #expect(schedule.lastAttemptAt == failed.attemptedAt)
        #expect(schedule.lastSuccessAt == nil)
        #expect(schedule.repetitionCount == 0)
        #expect(schedule.lapseCount == 0)
        #expect(schedule.stability == 0)
    }

    @Test("Success expands stability and a later lapse pulls review forward")
    func successAndLapseIntervals() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "concept", createdAt: created)
        let successAt = created.addingTimeInterval(day)
        let success = attempt(id: "success", itemID: memory.id, rating: .good, at: successAt)

        let afterSuccess = MemoryTutorScheduler.schedule(item: memory, attempts: [success])
        #expect(abs(afterSuccess.stability - 4.2) < 0.000_001)
        #expect(afterSuccess.dueAt == successAt.addingTimeInterval(4.2 * day))
        #expect(afterSuccess.lastSuccessAt == successAt)
        #expect(afterSuccess.repetitionCount == 1)
        #expect(afterSuccess.lapseCount == 0)

        let lapseAt = successAt.addingTimeInterval(2 * day)
        let lapse = attempt(id: "lapse", itemID: memory.id, rating: .again, at: lapseAt)
        let afterLapse = MemoryTutorScheduler.schedule(item: memory, attempts: [lapse, success])

        #expect(abs(afterLapse.stability - 2.1) < 0.000_001)
        #expect(afterLapse.dueAt == lapseAt.addingTimeInterval(2.1 * day))
        #expect(afterLapse.lastSuccessAt == successAt)
        #expect(afterLapse.repetitionCount == 2)
        #expect(afterLapse.lapseCount == 1)
        #expect(afterLapse.difficulty > afterSuccess.difficulty)
    }

    @Test("A kept item is new until its first grade, and first eligible at the start of the next local day")
    func newItemsWaitForTheNextLocalDay() throws {
        let calendar = try losAngeles()
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour, minute: minute
            )))
        }

        #expect(MemoryTutorScheduler.algorithmVersion == 2)
        let october1 = try local(10, 1, 0)
        let lateEvening = item(id: "late", createdAt: try local(9, 30, 23, 30))
        let schedule = MemoryTutorScheduler.schedule(item: lateEvening, attempts: [], calendar: calendar)
        #expect(schedule.isNew)
        #expect(schedule.dueAt == october1)
        #expect(schedule.algorithmVersion == MemoryTutorScheduler.algorithmVersion)
        let justAfterMidnight = try local(9, 30, 0, 10)
        #expect(MemoryTutorScheduler.firstEligibleAt(createdAt: justAfterMidnight, calendar: calendar) == october1)

        // The local day, not 24 hours: the day the clocks go back is 25 hours long.
        let november1 = try local(11, 1, 0)
        let november2 = try local(11, 2, 0)
        let keptAtNoon = try local(11, 1, 12)
        #expect(MemoryTutorScheduler.firstEligibleAt(createdAt: keptAtNoon, calendar: calendar) == november2)
        #expect(november2.timeIntervalSince(november1) == 25 * 3_600)
    }

    @Test("The first grade schedules a new item whenever it comes, practice on the day it was kept included")
    func firstGradeSchedulesANewItem() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "kept-today", createdAt: created)
        let practisedAt = created.addingTimeInterval(3_600)
        let schedule = MemoryTutorScheduler.schedule(
            item: memory,
            attempts: [attempt(id: "practice", itemID: memory.id, rating: .good, at: practisedAt)]
        )

        #expect(!schedule.isNew)
        #expect(schedule.repetitionCount == 1)
        #expect(abs(schedule.stability - 4.2) < 0.000_001)
        #expect(schedule.dueAt == practisedAt.addingTimeInterval(4.2 * day))
    }

    @Test("A success before the item is due counts, and leaves its interval where it was")
    func earlySuccessDoesNotStretch() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "concept", createdAt: created)
        let firstAt = created.addingTimeInterval(day)
        let first = attempt(id: "1-first", itemID: memory.id, rating: .good, at: firstAt)
        let afterFirst = MemoryTutorScheduler.schedule(item: memory, attempts: [first])

        // A repeat a minute later inside the same review, and practice two days
        // before it is due: both are counted, neither stretches the interval.
        let repeatInReview = attempt(
            id: "2-repeat",
            itemID: memory.id,
            rating: .easy,
            at: firstAt.addingTimeInterval(60)
        )
        let practice = attempt(
            id: "3-practice",
            itemID: memory.id,
            rating: .good,
            at: firstAt.addingTimeInterval(2 * day)
        )
        let afterEarly = MemoryTutorScheduler.schedule(
            item: memory,
            attempts: [practice, first, repeatInReview]
        )
        #expect(afterEarly.dueAt == afterFirst.dueAt)
        #expect(afterEarly.stability == afterFirst.stability)
        #expect(afterEarly.difficulty == afterFirst.difficulty)
        #expect(afterEarly.repetitionCount == 3)
        #expect(afterEarly.lastSuccessAt == practice.attemptedAt)
        #expect(afterEarly.lastAttemptAt == practice.attemptedAt)

        // Once it is due, a success stretches from where the on-time review left it.
        let onTimeAt = afterFirst.dueAt.addingTimeInterval(3_600)
        let onTime = attempt(id: "4-on-time", itemID: memory.id, rating: .good, at: onTimeAt)
        let afterOnTime = MemoryTutorScheduler.schedule(
            item: memory,
            attempts: [first, repeatInReview, practice, onTime]
        )
        #expect(abs(afterOnTime.stability - 4.2 * 2.1) < 0.000_001)
        #expect(afterOnTime.dueAt == onTimeAt.addingTimeInterval(afterOnTime.stability * day))
        #expect(afterOnTime.repetitionCount == 4)
    }

    @Test("An answer on the day an item was kept never makes it due that day: at the earliest, the next local day")
    func firstDayAnswersWaitForTomorrow() throws {
        let calendar = try losAngeles()
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour, minute: minute
            )))
        }
        let keptAt = try local(9, 30, 9)
        let today = try local(9, 30, 0)
        let tomorrow = try local(10, 1, 0)
        let memory = item(id: "missed", createdAt: keptAt)
        #expect(MemoryTutorScheduler.firstDay(of: memory, calendar: calendar) == today..<tomorrow)

        // A walkthrough Forgot at nine: half a day would be 21:00 the same day.
        let forgot = attempt(id: "forgot", itemID: memory.id, rating: .again, at: keptAt)
        let afterForgot = MemoryTutorScheduler.schedule(item: memory, attempts: [forgot], calendar: calendar)
        #expect(afterForgot.stability == MemoryTutorScheduler.minimumStabilityDays)
        #expect(afterForgot.dueAt == tomorrow)
        #expect(afterForgot.lapseCount == 1)

        // A second miss later that morning still waits for tomorrow, and a
        // success that evening is early: counted, the interval left alone.
        let missedAgain = attempt(id: "missed-again", itemID: memory.id, rating: .again, at: try local(9, 30, 10))
        #expect(MemoryTutorScheduler.schedule(item: memory, attempts: [forgot, missedAgain], calendar: calendar).dueAt == tomorrow)
        let rememberedLater = attempt(id: "remembered", itemID: memory.id, rating: .good, at: try local(9, 30, 19))
        let afterEarly = MemoryTutorScheduler.schedule(item: memory, attempts: [forgot, rememberedLater], calendar: calendar)
        #expect(afterEarly.dueAt == tomorrow)
        #expect(afterEarly.repetitionCount == 2)

        // A longer interval is never cut back to tomorrow.
        let remembered = attempt(id: "good", itemID: memory.id, rating: .good, at: keptAt)
        #expect(MemoryTutorScheduler.schedule(item: memory, attempts: [remembered], calendar: calendar).dueAt
            == keptAt.addingTimeInterval(4.2 * day))

        // From the next day on, an interval is the interval: a miss at nine on
        // the 1st is due at 21:00 on the 1st.
        let nextDayMiss = attempt(id: "next-day-miss", itemID: memory.id, rating: .again, at: try local(10, 1, 9))
        let nextDayEvening = try local(10, 1, 21)
        #expect(MemoryTutorScheduler.schedule(item: memory, attempts: [nextDayMiss], calendar: calendar).dueAt
            == nextDayEvening)
    }

    @Test("A miss before the item is due still counts")
    func earlyMissCounts() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = item(id: "concept", createdAt: created)
        let firstAt = created.addingTimeInterval(day)
        let first = attempt(id: "first", itemID: memory.id, rating: .good, at: firstAt)
        let missAt = firstAt.addingTimeInterval(day)
        let miss = attempt(id: "miss", itemID: memory.id, rating: .again, at: missAt)

        let schedule = MemoryTutorScheduler.schedule(item: memory, attempts: [first, miss])

        #expect(abs(schedule.stability - 2.1) < 0.000_001)
        #expect(schedule.dueAt == missAt.addingTimeInterval(2.1 * day))
        #expect(schedule.lapseCount == 1)
        #expect(schedule.repetitionCount == 2)
        #expect(schedule.lastSuccessAt == firstAt)
    }

    @Test("Structured retrieval quality maps to one cross-device rating contract")
    func gradeMapping() {
        #expect(MemoryTutorGradeMapping.rating(quality: .notRecalled, score: 0.2) == .again)
        #expect(MemoryTutorGradeMapping.rating(quality: .hinted, score: 0.95) == .hard)
        #expect(MemoryTutorGradeMapping.rating(quality: .independent, score: 0.69) == .hard)
        #expect(MemoryTutorGradeMapping.rating(quality: .independent, score: 0.7) == .good)
        #expect(MemoryTutorGradeMapping.rating(quality: .independent, score: 0.9) == .easy)
        #expect(MemoryTutorGradeMapping.shouldAdvance(quality: .independent, score: 0.7))
        #expect(!MemoryTutorGradeMapping.shouldAdvance(quality: .hinted, score: 1))
        #expect(MemoryTutorGradeMapping.rating(quality: .independent, score: -Double.infinity) == nil)
        #expect(MemoryTutorGradeMapping.rating(quality: .independent, score: 1.01) == nil)
    }

    @Test("Memory session source links are ordered and deduplicated by canonical anchors")
    func sourceLinkage() {
        let created = Date(timeIntervalSince1970: 2_000_000_000)
        let memory = MemoryItem(
            id: "relationship",
            kind: .relationship,
            target: "Connect the two mechanisms",
            rubricJSON: "{\"criteria\":[\"connection\"]}",
            sources: [
                MemoryItemSource(
                    id: "anchor-c",
                    memoryItemID: "relationship",
                    sourceID: "source-b",
                    excerpt: "Later evidence",
                    sourceSHA256: String(repeating: "b", count: 64),
                    sortIndex: 2
                ),
                MemoryItemSource(
                    id: "anchor-a",
                    memoryItemID: "relationship",
                    sourceID: "source-a",
                    excerpt: "First evidence",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
                MemoryItemSource(
                    id: "anchor-b",
                    memoryItemID: "relationship",
                    sourceID: "source-a",
                    excerpt: "Second excerpt from the same source",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 1
                ),
            ],
            createdAt: created,
            updatedAt: created
        )

        #expect(MemoryTutorSourceLinkage.orderedSourceIDs(for: memory) == ["source-a", "source-b"])
    }

    @Test("Every surface reserves one of five slots for first review")
    func sharedQueueSelection() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let due = (0..<5).map { index -> DueMemoryItem in
            let memory = item(
                id: "due-\(index)",
                createdAt: now.addingTimeInterval(-Double(index + 1) * day)
            )
            return DueMemoryItem(
                item: memory,
                schedule: MemorySchedule(
                    memoryItemID: memory.id,
                    dueAt: now.addingTimeInterval(-Double(index + 1) * day),
                    difficulty: index == 0 ? 0.8 : 0.4
                ),
                daysOverdue: index + 1
            )
        }
        let firstReviews = (0..<3).map { index in
            MemoryReviewNewItem(
                sourceID: "new-\(index)",
                title: "New \(index)",
                sourceType: "article",
                consumedAt: now.addingTimeInterval(-2 * day),
                dueAt: now.addingTimeInterval(-day),
                daysOverdue: 1
            )
        }
        let available = Set(
            due.flatMap { $0.item.sources.map(\.sourceID) }
                + firstReviews.map(\.sourceID)
        )

        let selected = MemoryTutorQueueSelection.select(
            dueItems: due,
            firstReviews: firstReviews,
            availableSourceIDs: available,
            limit: 5
        )

        #expect(selected.dueItems.count == 4)
        #expect(selected.firstReviews.map(\.sourceID) == ["new-0"])
        #expect(selected.dueItems.first?.item.id == "due-0")
    }

    @Test("Queue excludes a multi-source memory unless every anchor is in scope")
    func queueRequiresCompleteAnchorScope() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let memory = MemoryItem(
            id: "relationship",
            kind: .relationship,
            target: "Contrast two sources",
            rubricJSON: #"{"criteria":["distinguishes both claims"]}"#,
            sources: ["source-a", "source-b"].enumerated().map { index, sourceID in
                MemoryItemSource(
                    id: "anchor-\(index)",
                    memoryItemID: "relationship",
                    sourceID: sourceID,
                    excerpt: "Evidence \(index)",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: index
                )
            }
        )
        let due = DueMemoryItem(
            item: memory,
            schedule: MemorySchedule(memoryItemID: memory.id, dueAt: now.addingTimeInterval(-1)),
            daysOverdue: 1
        )

        #expect(MemoryTutorQueueSelection.select(
            dueItems: [due],
            firstReviews: [],
            availableSourceIDs: ["source-a"],
            limit: 5
        ).dueItems.isEmpty)
        #expect(MemoryTutorQueueSelection.select(
            dueItems: [due],
            firstReviews: [],
            availableSourceIDs: ["source-a", "source-b"],
            limit: 5
        ).dueItems.map(\.id) == ["relationship"])
    }

    @Test("Recent attention leads the queue ahead of an older struggle")
    func recentActivityReordersAcrossDueAndFirstReviewBuckets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let struggling = item(
            id: "struggling",
            createdAt: now.addingTimeInterval(-day),
            learnerContext: "Missed the causal mechanism."
        )
        let ordinary = item(
            id: "ordinary",
            createdAt: now.addingTimeInterval(-10 * day)
        )
        let due = [struggling, ordinary].map { memory in
            DueMemoryItem(
                item: memory,
                schedule: MemorySchedule(
                    memoryItemID: memory.id,
                    dueAt: memory.createdAt,
                    difficulty: memory.id == "struggling" ? 0.7 : 0.4
                ),
                daysOverdue: max(0, Int(now.timeIntervalSince(memory.createdAt) / day))
            )
        }
        let olderIntake = MemoryReviewNewItem(
            sourceID: "older-intake",
            title: "Older intake",
            sourceType: "article",
            consumedAt: now.addingTimeInterval(-20 * day),
            dueAt: now.addingTimeInterval(-19 * day),
            daysOverdue: 19
        )
        let recentIntake = MemoryReviewNewItem(
            sourceID: "recent-intake",
            title: "Recent discussion",
            sourceType: "article",
            consumedAt: now.addingTimeInterval(-2 * day),
            dueAt: now.addingTimeInterval(-day),
            daysOverdue: 1
        )
        let available = Set(
            due.flatMap { $0.item.sources.map(\.sourceID) }
                + [olderIntake.sourceID, recentIntake.sourceID]
        )

        let selected = MemoryTutorQueueSelection.select(
            dueItems: due,
            firstReviews: [olderIntake, recentIntake],
            availableSourceIDs: available,
            recentSourceActivity: [
                MemoryTutorRecentSourceActivity(
                    sourceID: recentIntake.sourceID,
                    discussedAt: now.addingTimeInterval(-60)
                )
            ],
            limit: 3
        )

        #expect(selected.firstReviews.map(\.sourceID) == [recentIntake.sourceID])
        // Recency first, then the struggle, then the plain backlog item. The
        // struggle is still in the session; it just no longer opens it.
        #expect(selected.orderedIDs == [
            MemoryTutorQueueIdentity.firstReview(sourceID: recentIntake.sourceID),
            struggling.id,
            ordinary.id,
        ])
    }

    @Test("A recently consumed source survives a backlog larger than the candidate pool")
    func recentDueItemSurvivesPoolTruncation() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Every backlog item is a struggle and months overdue, so under a pure
        // most-faded-first cap the recent item cannot place at any pool size
        // smaller than the backlog itself.
        let backlog = (0..<20).map { index in
            item(
                id: "backlog-\(index)",
                createdAt: now.addingTimeInterval(-Double(90 + index) * day),
                learnerContext: "Missed the mechanism."
            )
        }
        let listenedThisWeek = item(
            id: "listened-this-week",
            createdAt: now.addingTimeInterval(-2 * day)
        )

        let pool = MemoryTutorScheduler.dueItems(
            items: backlog + [listenedThisWeek],
            schedules: reviewedSchedules(backlog + [listenedThisWeek]),
            now: now,
            limit: 6,
            recentSourceActivity: [
                MemoryTutorRecentSourceActivity(
                    sourceID: "source-listened-this-week",
                    discussedAt: now.addingTimeInterval(-3_600)
                )
            ]
        )

        #expect(pool.count == 6)
        #expect(pool.first?.item.id == listenedThisWeek.id)
        // The recent ranking is offered half the pool but only has one item to
        // put in it, so the rest returns to the faded backlog rather than
        // shrinking the pool.
        #expect(pool.filter { $0.item.id.hasPrefix("backlog-") }.count == 5)

        // With no recency signal the pool is exactly the old ordering.
        let unchanged = MemoryTutorScheduler.dueItems(
            items: backlog + [listenedThisWeek],
            schedules: reviewedSchedules(backlog + [listenedThisWeek]),
            now: now,
            limit: 6
        )
        #expect(unchanged.allSatisfy { $0.item.id.hasPrefix("backlog-") })
    }

    @Test("Half the concept slots are held for recently attended material")
    func selectionReservesHalfTheSlotsForRecentAttention() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let faded = (0..<4).map { index -> DueMemoryItem in
            let memory = item(
                id: "faded-\(index)",
                createdAt: now.addingTimeInterval(-Double(60 + index) * day),
                learnerContext: "Missed the mechanism."
            )
            return DueMemoryItem(
                item: memory,
                schedule: MemorySchedule(
                    memoryItemID: memory.id,
                    dueAt: memory.createdAt,
                    difficulty: 0.8,
                    lapseCount: 2
                ),
                daysOverdue: 60 + index
            )
        }
        let recent = (0..<3).map { index -> DueMemoryItem in
            let memory = item(
                id: "recent-\(index)",
                createdAt: now.addingTimeInterval(-Double(index + 2) * day)
            )
            return DueMemoryItem(
                item: memory,
                schedule: MemorySchedule(memoryItemID: memory.id, dueAt: memory.createdAt),
                daysOverdue: index + 2
            )
        }
        let available = Set((faded + recent).flatMap { $0.item.sources.map(\.sourceID) })

        let selected = MemoryTutorQueueSelection.select(
            dueItems: faded + recent,
            firstReviews: [],
            availableSourceIDs: available,
            recentSourceActivity: recent.enumerated().map { index, due in
                MemoryTutorRecentSourceActivity(
                    sourceID: due.item.sources[0].sourceID,
                    discussedAt: now.addingTimeInterval(-Double(index + 1) * 3_600)
                )
            },
            limit: 4
        )

        // Two of four slots to this week, two to the faded backlog — neither
        // bucket starves the other, and the session opens on this week.
        #expect(selected.dueItems.count == 4)
        #expect(selected.dueItems.filter { $0.item.id.hasPrefix("recent-") }.count == 2)
        #expect(selected.dueItems.filter { $0.item.id.hasPrefix("faded-") }.count == 2)
        #expect(selected.orderedIDs.prefix(2).allSatisfy { $0.hasPrefix("recent-") })
    }

    @Test("First-review intake is never spent entirely on the source-level backlog")
    func firstReviewIntakeSplitsBetweenBuckets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // More long-overdue source-level refreshes than the whole daily cap: the shape
        // that used to consume the budget before intake was even computed.
        let refreshStats = (0..<12).map { index in
            MemoryReviewStat(
                sourceID: "legacy-\(index)",
                title: "Legacy \(index)",
                sourceType: "article",
                lastReviewedAt: now.addingTimeInterval(-Double(120 + index) * day),
                lastScore: 0.5,
                reviewCount: 1
            )
        }
        let fresh = (0..<4).map { index in
            MemoryReviewNewCandidate(
                sourceID: "fresh-\(index)",
                title: "Fresh \(index)",
                sourceType: "podcast",
                consumedAt: now.addingTimeInterval(-Double(index + 2) * day)
            )
        }

        let intake = MemoryReviewScheduler.firstReviewIntake(
            sourceStats: refreshStats,
            freshCandidates: fresh,
            now: now,
            limit: 5
        )

        #expect(intake.count == 5)
        #expect(intake.filter { $0.sourceID.hasPrefix("fresh-") }.count == 2)
        #expect(intake.filter { $0.sourceID.hasPrefix("legacy-") }.count == 3)
        // Most recently consumed leads.
        #expect(intake.first?.sourceID == "fresh-0")
        // A bucket that cannot fill its share hands it to the other.
        let backlogOnly = MemoryReviewScheduler.firstReviewIntake(
            sourceStats: refreshStats,
            freshCandidates: [],
            now: now,
            limit: 5
        )
        #expect(backlogOnly.count == 5)
    }

    @Test("A resumed opening turn is not mistaken for an unrecorded memory answer")
    func resumedOpeningTurnDoesNotRequireGrade() {
        #expect(!MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: false,
            hasMemoryPlan: true,
            previousTutorQuestion: nil
        ))
        #expect(!MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: false,
            hasMemoryPlan: true,
            previousTutorQuestion: "   "
        ))
        #expect(MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: false,
            hasMemoryPlan: true,
            previousTutorQuestion: "Explain the mechanism."
        ))
        #expect(!MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: true,
            hasMemoryPlan: true,
            previousTutorQuestion: "Opening prompt"
        ))
    }

    @Test("First-review durable and transient identities are app-owned and stable")
    func firstReviewIdentity() {
        let doiKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: "source-a",
            doi: "10.1000/PORTABLE"
        )
        let publishedDOIKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: "different-local-id",
            publishedDOI: "10.1000/portable"
        )
        #expect(doiKey == publishedDOIKey)
        let itemID = MemoryTutorIdentity.firstReviewItemID(portableSourceKey: doiKey)
        #expect(itemID == MemoryTutorIdentity.firstReviewItemID(portableSourceKey: publishedDOIKey))
        #expect(itemID != MemoryTutorIdentity.firstReviewItemID(
            portableSourceKey: MemoryTutorIdentity.portableSourceKey(sourceID: "source-b")
        ))
        #expect(
            MemoryTutorIdentity.firstReviewAnchorID(
                memoryItemID: itemID,
                sourceID: "source-a"
            ) == MemoryTutorIdentity.firstReviewAnchorID(
                memoryItemID: itemID,
                sourceID: "different-local-id"
            )
        )
        #expect(MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: doiKey)
            == MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: publishedDOIKey))
    }

    private func losAngeles() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    /// Each item reviewed once and due again from the moment it was kept: the
    /// shape of a backlog. An item with no graded review is new, never due.
    private func reviewedSchedules(_ items: [MemoryItem]) -> [String: MemorySchedule] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, MemorySchedule(memoryItemID: item.id, dueAt: item.createdAt, repetitionCount: 1))
        })
    }

    private func item(
        id: String,
        status: MemoryItemStatus = .active,
        createdAt: Date,
        learnerContext: String? = nil
    ) -> MemoryItem {
        MemoryItem(
            id: id,
            kind: .concept,
            target: "Explain the mechanism behind \(id)",
            rubricJSON: "{\"criteria\":[\"mechanism\",\"constraint\"]}",
            learnerContext: learnerContext,
            status: status,
            sources: [
                MemoryItemSource(
                    id: "anchor-\(id)",
                    memoryItemID: id,
                    sourceID: "source-\(id)",
                    excerpt: "Grounding evidence for \(id)",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                )
            ],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func attempt(
        id: String,
        itemID: String,
        gradeState: MemoryGradeState = .graded,
        rating: MemoryScheduleRating?,
        at: Date
    ) -> MemoryAttempt {
        MemoryAttempt(
            id: id,
            memoryItemID: itemID,
            prompt: "Fresh question \(id)",
            learnerAnswer: "Learner answer \(id)",
            feedback: gradeState == .graded ? "Evaluation \(id)" : nil,
            score: gradeState == .graded ? 0.75 : nil,
            scheduleRating: rating,
            gradeState: gradeState,
            gradingError: gradeState == .failed ? "Provider failed" : nil,
            attemptedAt: at
        )
    }
}
