import Foundation
import Testing
@testable import ForeverLM

/// Today's card review (`MemoryCardQueue.today`): which kept cards are asked,
/// and in what order. One function every surface deals and counts from, so the
/// cases here are the Mac's, the iPhone's and the widget's alike.
@Suite("Memory card queue")
struct MemoryCardQueueTests {
    private let day = MemoryTutorScheduler.secondsPerDay

    @Test("A card kept today waits for tomorrow; one kept last night is new today")
    func keptTodayWaitsForTomorrow() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let keptToday = card("kept-today", keptAt: try local(calendar, 9, 30, 8))
        let keptLastNight = card("kept-last-night", keptAt: try local(calendar, 9, 29, 23, 50))

        let today = MemoryCardQueue.today(
            items: [keptToday, keptLastNight],
            attempts: [],
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )
        #expect(today.entries.map(\.id) == ["kept-last-night"])
        #expect(today.entries.map(\.bucket) == [.new])
        #expect(today.entries.map(\.daysOverdue) == [0])
        #expect(today.newCount == 1)
        #expect(today.dueCount == 0)
        #expect(today.newIntroducedToday == 0)

        let tomorrow = MemoryCardQueue.today(
            items: [keptToday, keptLastNight],
            attempts: [],
            now: try local(calendar, 10, 1, 0),
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )
        #expect(tomorrow.entries.map(\.id) == ["kept-last-night", "kept-today"])
    }

    @Test("Due cards come most overdue first, then new cards oldest kept first")
    func dueBeforeNew() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let (longOverdue, longOverdueReview) = dueCard("long-overdue", dueAt: now.addingTimeInterval(-3 * day - 3_600))
        let (justDue, justDueReview) = dueCard("just-due", dueAt: now.addingTimeInterval(-3_600))
        let (notYet, notYetReview) = dueCard("not-yet", dueAt: now.addingTimeInterval(3_600))
        let olderNew = card("older-new", keptAt: now.addingTimeInterval(-5 * day))
        let youngerNew = card("younger-new", keptAt: now.addingTimeInterval(-2 * day))

        // The helper's review lands each card exactly on the due date it names.
        #expect(MemoryTutorScheduler.schedule(
            item: justDue,
            attempts: [justDueReview],
            calendar: calendar
        ).dueAt == now.addingTimeInterval(-3_600))

        let today = MemoryCardQueue.today(
            items: [youngerNew, notYet, justDue, olderNew, longOverdue],
            attempts: [justDueReview, notYetReview, longOverdueReview],
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )

        #expect(today.entries.map(\.id) == ["long-overdue", "just-due", "older-new", "younger-new"])
        #expect(today.entries.map(\.bucket) == [.due, .due, .new, .new])
        #expect(today.entries.map(\.daysOverdue) == [3, 0, 0, 0])
        #expect(today.entries.allSatisfy { $0.notebookID == nil })
        #expect(today.dueCount == 2)
        #expect(today.newCount == 2)
        #expect(today.dueLeftOver == 0)
        #expect(today.newLeftOver == 0)
    }

    @Test("A notebook needed within 36 hours puts its due and new cards first, the soonest notebook first")
    func deadlineNotebooksLead() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let deadlines = [
            // A Goal's end: the cards it holds by their `goalID`.
            MemoryCardDeadline(notebookID: "nb-later", at: now.addingTimeInterval(30 * 3_600), sourceIDs: []),
            // A calendar block on the notebook: the cards anchored on its sources.
            MemoryCardDeadline(notebookID: "nb-soon", at: now.addingTimeInterval(10 * 3_600), sourceIDs: ["s-soon"]),
            // Beyond the horizon, and already past: neither counts.
            MemoryCardDeadline(notebookID: "nb-far", at: now.addingTimeInterval(40 * 3_600), sourceIDs: ["s-far"]),
            MemoryCardDeadline(notebookID: "nb-past", at: now.addingTimeInterval(-3_600), sourceIDs: ["s-past"]),
        ]
        let (otherDue, otherReview) = dueCard("other-due", dueAt: now.addingTimeInterval(-5 * day), sourceID: "s-other")
        let (soonDue, soonReview) = dueCard("soon-due", dueAt: now.addingTimeInterval(-day), sourceID: "s-soon")
        // In both notebooks: the sooner one claims it.
        let (bothDue, bothReview) = dueCard(
            "both-due",
            dueAt: now.addingTimeInterval(-2 * day),
            sourceID: "s-soon",
            goalID: "nb-later"
        )
        let (farDue, farReview) = dueCard("far-due", dueAt: now.addingTimeInterval(-2 * day), sourceID: "s-far")
        let soonNew = card("soon-new", keptAt: now.addingTimeInterval(-3 * day), sourceID: "s-soon")
        let laterNew = card("later-new", keptAt: now.addingTimeInterval(-2 * day), sourceID: "s-x", goalID: "nb-later")
        let pastNew = card("past-new", keptAt: now.addingTimeInterval(-4 * day), sourceID: "s-past")
        // Still kept today: a deadline does not bring a card forward before its first day.
        let soonKeptToday = card("soon-kept-today", keptAt: now.addingTimeInterval(-3_600), sourceID: "s-soon")

        let today = MemoryCardQueue.today(
            items: [otherDue, soonDue, bothDue, farDue, soonNew, laterNew, pastNew, soonKeptToday],
            attempts: [otherReview, soonReview, bothReview, farReview],
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: deadlines,
            calendar: calendar
        )

        #expect(today.entries.map(\.id) == [
            "both-due", "soon-due", "soon-new",
            "later-new",
            "other-due", "far-due",
            "past-new",
        ])
        #expect(today.entries.map(\.bucket) == [
            .deadline, .deadline, .deadline, .deadline, .due, .due, .new,
        ])
        #expect(today.entries.map(\.notebookID) == [
            "nb-soon", "nb-soon", "nb-soon", "nb-later", nil, nil, nil,
        ])
        // A deadline card keeps its own kind for the counts.
        #expect(today.dueCount == 4)
        #expect(today.newCount == 3)
    }

    @Test("New cards stop at the day's allowance, less the ones introduced today and the deadline's")
    func newCardAllowance() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        // First answered this morning, on another device perhaps: it was today's
        // new card, so it counts against today's allowance.
        let introducedToday = card("introduced-today", keptAt: now.addingTimeInterval(-3 * day))
        let introducedTodayAnswer = graded("introduced-today", .good, at: try local(calendar, 9, 30, 8))
        // First answered yesterday: yesterday's allowance.
        let introducedYesterday = card("introduced-yesterday", keptAt: now.addingTimeInterval(-3 * day))
        let introducedYesterdayAnswer = graded("introduced-yesterday", .good, at: try local(calendar, 9, 29, 9))
        let deadlineNew = card("deadline-new", keptAt: now.addingTimeInterval(-day), sourceID: "s-deadline")
        let deadline = MemoryCardDeadline(
            notebookID: "nb-deadline",
            at: now.addingTimeInterval(5 * 3_600),
            sourceIDs: ["s-deadline"]
        )
        let waiting = (1...5).map { index in
            card("new-\(index)", keptAt: now.addingTimeInterval(-Double(7 - index) * day))
        }
        let items = [introducedToday, introducedYesterday, deadlineNew] + waiting
        let attempts = [introducedTodayAnswer, introducedYesterdayAnswer]

        func queue(newPerDay: Int) -> MemoryCardQueue.Today {
            MemoryCardQueue.today(
                items: items,
                attempts: attempts,
                now: now,
                budgetMinutes: nil,
                newPerDay: newPerDay,
                deadlines: [deadline],
                calendar: calendar
            )
        }

        // 3 a day, 1 introduced this morning, 1 for the deadline: room for 1.
        let three = queue(newPerDay: 3)
        #expect(three.entries.map(\.id) == ["deadline-new", "new-1"])
        #expect(three.newIntroducedToday == 1)
        #expect(three.newCount == 2)
        #expect(three.newLeftOver == 4)
        #expect(three.dueCount == 0)

        // The notebook is needed before tomorrow's allowance comes, so its new
        // cards are asked even when the allowance is spent.
        let none = queue(newPerDay: 0)
        #expect(none.entries.map(\.id) == ["deadline-new"])
        #expect(none.newLeftOver == 5)
        #expect(queue(newPerDay: -3) == none)
    }

    @Test("Misses kept at once, born with their first graded attempt, leave the new-card allowance alone")
    func discoveriesDoNotUseTheAllowance() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 15)
        // Twelve quiz and walkthrough misses this morning: each item was made
        // with its `.discovery`, so none was a new card dealt from today's
        // allowance, and they are due tomorrow.
        let misses = (0..<12).map { index in
            card(String(format: "miss-%02d", index), keptAt: try! local(calendar, 9, 30, 8, index))
        }
        let missAttempts = misses.map { miss in
            discovery(miss.id, at: miss.createdAt)
        }
        let waiting = (1...3).map { index in
            card("new-\(index)", keptAt: now.addingTimeInterval(-Double(5 - index) * day))
        }
        // A new card first answered this morning in a review: it was today's.
        let introduced = card("introduced", keptAt: now.addingTimeInterval(-4 * day))
        let introducedAnswer = graded("introduced", .good, at: try local(calendar, 9, 30, 9))

        let today = MemoryCardQueue.today(
            items: misses + waiting + [introduced],
            attempts: missAttempts + [introducedAnswer],
            now: now,
            budgetMinutes: nil,
            newPerDay: 3,
            deadlines: [],
            calendar: calendar
        )
        #expect(today.newIntroducedToday == 1)
        #expect(today.entries.map(\.id) == ["new-1", "new-2"])
        #expect(today.newLeftOver == 1)
        #expect(today.dueCount == 0, "a miss is not asked again the day it was missed")

        let tomorrow = MemoryCardQueue.today(
            items: misses + waiting + [introduced],
            attempts: missAttempts + [introducedAnswer],
            now: try local(calendar, 10, 1, 8),
            budgetMinutes: nil,
            newPerDay: 3,
            deadlines: [],
            calendar: calendar
        )
        #expect(tomorrow.dueCount == 12)
        #expect(tomorrow.newCount == 3)
    }

    @Test("Every client reads the synced allowance one way: absent is the Mac's default, a value is clamped")
    func allowanceFromTheSyncedRow() {
        #expect(MemoryCardQueue.newPerDay(stored: nil) == MemoryCardQueue.defaultNewPerDay)
        #expect(MemoryCardQueue.newPerDay(stored: 20) == 20)
        #expect(MemoryCardQueue.newPerDay(stored: 0) == 1)
        #expect(MemoryCardQueue.newPerDay(stored: -3) == 1)
        #expect(MemoryCardQueue.newPerDay(stored: 250) == 100)

        // The Mac reads it from its defaults through the same rule.
        let suite = "MemoryCardQueueTests.allowance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MemoryCardSettings.newCardsPerDay(defaults: defaults) == MemoryCardQueue.newPerDay(stored: nil))
        defaults.set(3, forKey: MemoryCardQueue.newPerDayPreferenceKey)
        #expect(MemoryCardSettings.newCardsPerDay(defaults: defaults) == MemoryCardQueue.newPerDay(stored: 3))
    }

    @Test("The iPhone deals new cards by the account's allowance and keeps the last read when iCloud does not answer")
    func phoneReadsTheAllowance() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let waiting = (1...5).map { index in
            card("new-\(index)", keptAt: now.addingTimeInterval(-Double(7 - index) * day))
        }
        func deal(_ preferences: MobileMemoryReviewPreferences) -> MemoryCardQueue.Today {
            MemoryCardQueue.today(
                items: waiting,
                attempts: [],
                now: now,
                budgetMinutes: preferences.budgetMinutes,
                newPerDay: preferences.newCardsPerDay,
                deadlines: [],
                calendar: calendar
            )
        }
        let offline: Result<Int?, Error> = .failure(URLError(.notConnectedToInternet))

        // Before the first read: uncut, at the Mac's default.
        let unread = MobileMemoryReviewPreferences()
        #expect(unread.budgetMinutes == nil)
        #expect(unread.newCardsPerDay == MemoryCardQueue.defaultNewPerDay)
        #expect(deal(unread).newCount == 5)

        // Rows the learner never set read as the Mac's defaults.
        let defaults = unread.refreshed(budgetRead: .success(nil), newCardsRead: .success(nil))
        #expect(defaults == MobileMemoryReviewPreferences(
            budgetMinutes: MemoryReviewBudget.defaultMinutes,
            newCardsPerDay: MemoryCardQueue.defaultNewPerDay
        ))

        // Three new cards a day, set on the Mac: the phone deals three.
        let three = defaults.refreshed(budgetRead: .success(30), newCardsRead: .success(3))
        #expect(three.newCardsPerDay == 3)
        #expect(deal(three).entries.map(\.id) == ["new-1", "new-2", "new-3"])
        #expect(deal(three).newLeftOver == 2)

        // A failed read keeps what was last read, each row on its own.
        #expect(three.refreshed(budgetRead: offline, newCardsRead: offline) == three)
        let halfRead = three.refreshed(budgetRead: offline, newCardsRead: .success(250))
        #expect(halfRead.budgetMinutes == 30)
        #expect(halfRead.newCardsPerDay == 100, "clamped as the Mac clamps it")
        let otherHalf = three.refreshed(budgetRead: .success(45), newCardsRead: offline)
        #expect(otherHalf.budgetMinutes == 45)
        #expect(otherHalf.newCardsPerDay == 3)
    }

    @Test("An answer counts when the card is active and due, or new and eligible; practice counts a new card at once")
    func answerCountsRule() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let keptToday = card("kept-today", keptAt: try local(calendar, 9, 30, 8))
        let keptYesterday = card("kept-yesterday", keptAt: try local(calendar, 9, 29, 8))
        let (due, dueReview) = dueCard("due", dueAt: now.addingTimeInterval(-60))
        let (notYet, notYetReview) = dueCard("not-yet", dueAt: now.addingTimeInterval(3_600))
        func counts(_ item: MemoryItem, _ attempts: [MemoryAttempt], practice: Bool, status: MemoryItemStatus = .active) -> Bool {
            MemoryCardQueue.answerCounts(
                status: status,
                schedule: MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: calendar),
                now: now,
                practice: practice
            )
        }

        #expect(!counts(keptToday, [], practice: false))
        #expect(counts(keptToday, [], practice: true))
        #expect(counts(keptYesterday, [], practice: false))
        #expect(counts(due, [dueReview], practice: false))
        #expect(!counts(notYet, [notYetReview], practice: false))
        #expect(!counts(notYet, [notYetReview], practice: true))
        #expect(!counts(due, [dueReview], practice: false, status: .retired))
    }

    @Test("The budget cuts the list where the next card would overrun it")
    func budgetCutsTheList() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let due = (0..<12).map { index in
            dueCard(
                String(format: "due-%02d", index),
                dueAt: now.addingTimeInterval(-Double(12 - index) * 3_600)
            )
        }
        let new = (0..<2).map { index in
            card("new-\(index)", keptAt: now.addingTimeInterval(-Double(3 + index) * day))
        }
        let items = due.map { $0.item } + new
        let attempts = due.map { $0.review }

        func queue(budgetMinutes: Int?) -> MemoryCardQueue.Today {
            MemoryCardQueue.today(
                items: items,
                attempts: attempts,
                now: now,
                budgetMinutes: budgetMinutes,
                newPerDay: 10,
                deadlines: [],
                calendar: calendar
            )
        }

        // Five minutes at 30 seconds a due card: ten of the twelve.
        let five = queue(budgetMinutes: 5)
        #expect(five.entries.map(\.id) == (0..<10).map { String(format: "due-%02d", $0) })
        #expect(five.estimatedSeconds == 300)
        #expect(five.dueLeftOver == 2)
        #expect(five.newLeftOver == 2)

        // Six minutes holds every due card; a new card (a minute) no longer fits.
        let six = queue(budgetMinutes: 6)
        #expect(six.dueCount == 12)
        #expect(six.newCount == 0)
        #expect(six.newLeftOver == 2)

        // The budget is clamped like everywhere else, and nil leaves the list whole.
        #expect(queue(budgetMinutes: 1) == five)
        let whole = queue(budgetMinutes: nil)
        #expect(whole.entries.count == 14)
        #expect(whole.dueLeftOver == 0)
        #expect(whole.newLeftOver == 0)
        #expect(whole.estimatedSeconds == 12 * MemoryCardQueue.secondsPerDueCard + 2 * MemoryCardQueue.secondsPerNewCard)
    }

    @Test("Retired cards are skipped, a repeated card is dealt once, and input order changes nothing")
    func retiredRepeatedAndOrder() throws {
        let calendar = try losAngeles()
        let now = try local(calendar, 9, 30, 10)
        let (due, review) = dueCard("due", dueAt: now.addingTimeInterval(-day))
        let retired = card("retired", keptAt: now.addingTimeInterval(-9 * day), status: .retired)
        let retiredReview = graded("retired", .again, at: now.addingTimeInterval(-8 * day))
        let new = card("new", keptAt: now.addingTimeInterval(-2 * day))
        // An attempt on a card the caller did not pass is ignored.
        let stray = graded("not-passed", .good, at: now.addingTimeInterval(-day))

        let forward = MemoryCardQueue.today(
            items: [due, retired, new, due],
            attempts: [review, retiredReview, stray],
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )
        let backward = MemoryCardQueue.today(
            items: [new, due, retired],
            attempts: [stray, retiredReview, review],
            now: now,
            budgetMinutes: nil,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        )

        #expect(forward.entries.map(\.id) == ["due", "new"])
        #expect(forward == backward)
        #expect(MemoryCardQueue.Today.empty.entries.isEmpty)
        #expect(MemoryCardQueue.today(
            items: [],
            attempts: [],
            now: now,
            budgetMinutes: 15,
            newPerDay: 10,
            deadlines: [],
            calendar: calendar
        ) == .empty)
    }

    // MARK: - Fixtures

    private func losAngeles() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private func local(
        _ calendar: Calendar,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute
        )))
    }

    private func card(
        _ id: String,
        keptAt: Date,
        sourceID: String? = nil,
        goalID: String? = nil,
        status: MemoryItemStatus = .active
    ) -> MemoryItem {
        MemoryItem(
            id: id,
            kind: .concept,
            target: "The back of \(id)",
            rubricJSON: #"{"criteria":["Why it matters"]}"#,
            goalID: goalID,
            status: status,
            sources: [
                MemoryItemSource(
                    id: "anchor-\(id)",
                    memoryItemID: id,
                    sourceID: sourceID ?? "source-\(id)",
                    excerpt: "The passage behind \(id)",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ],
            createdAt: keptAt,
            updatedAt: keptAt
        )
    }

    private func graded(_ itemID: String, _ rating: MemoryScheduleRating, at: Date) -> MemoryAttempt {
        MemoryAttempt(
            id: "attempt-\(itemID)-\(Int(at.timeIntervalSinceReferenceDate))",
            memoryItemID: itemID,
            prompt: "The front of \(itemID)",
            learnerAnswer: "(self-graded)",
            score: rating == .again ? 0 : 1,
            scheduleRating: rating,
            gradeState: .graded,
            attemptedAt: at
        )
    }

    /// The miss an item was made with: a walkthrough Forgot or a course-quiz
    /// answer graded incorrect, kept at once.
    private func discovery(_ itemID: String, at: Date) -> MemoryAttempt {
        MemoryAttempt(
            id: "discovery-\(itemID)",
            memoryItemID: itemID,
            attemptType: .discovery,
            prompt: "The front of \(itemID)",
            learnerAnswer: "I didn't have it.",
            score: 0,
            scheduleRating: .again,
            gradeState: .graded,
            attemptedAt: at
        )
    }

    /// A card reviewed once and due again at `dueAt`. A first `.good` sets
    /// 2 days × 2.1, so the review is dated 4.2 days before.
    private func dueCard(
        _ id: String,
        dueAt: Date,
        sourceID: String? = nil,
        goalID: String? = nil
    ) -> (item: MemoryItem, review: MemoryAttempt) {
        let reviewedAt = dueAt.addingTimeInterval(-4.2 * day)
        return (
            card(id, keptAt: reviewedAt.addingTimeInterval(-2 * day), sourceID: sourceID, goalID: goalID),
            graded(id, .good, at: reviewedAt)
        )
    }
}
