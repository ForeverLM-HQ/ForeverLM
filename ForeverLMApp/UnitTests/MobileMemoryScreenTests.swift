import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's Memory screen (docs/memory-design.md, "The Memory screen on
/// the iPhone"): the Mac's Memory pane's words, by the phone's state; the
/// history grid's days from the review chats the phone holds; and how half a
/// year of squares fits a phone.
@Suite("The Memory screen on the phone")
struct MobileMemoryScreenTests {
    private static let day: TimeInterval = 86_400

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    /// Thursday 1 October 2026, noon UTC.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 1
        components.hour = 12
        return MobileMemoryScreenTests.calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    private func key(daysAgo: Int) -> String {
        MemoryReviewGoal.dayKey(for: Self.now.addingTimeInterval(-Double(daysAgo) * Self.day), calendar: Self.calendar)
    }

    private func snapshot(seconds: TimeInterval, goal: TimeInterval = 900) -> MemoryReviewGoalSnapshot {
        MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: key(daysAgo: 0), activeSeconds: seconds, goalSeconds: goal),
            streak: 3
        )
    }

    // MARK: - Review's words

    @Test("The counts line is today's cards as the Mac's pane says them; cards to check and practice are not today's")
    func countsLine() {
        #expect(MobileMemoryScreenCopy.countsLine(MemoryCardDayCounts(due: 6, new: 4, practice: 2)) == "6 due · 4 new")
        #expect(MobileMemoryScreenCopy.countsLine(MemoryCardDayCounts(due: 6, new: 0, practice: 0)) == "6 due")
        #expect(MobileMemoryScreenCopy.countsLine(MemoryCardDayCounts(due: 0, new: 4, practice: 0)) == "4 new")
        #expect(MobileMemoryScreenCopy.countsLine(.zero) == "Nothing due today")
        #expect(
            MobileMemoryScreenCopy.countsLine(MemoryCardDayCounts(due: 0, new: 0, practice: 3, toCheck: 9)) == "Nothing due today",
            "practice and cards to check wait outside today's review"
        )
    }

    @Test("The phone's day is open until the goal is met on any device, then done; it is never ended early")
    func stateAndButtons() {
        let open = MobileMemoryScreenCopy.state(goal: snapshot(seconds: 600))
        let done = MobileMemoryScreenCopy.state(goal: snapshot(seconds: 900))
        #expect(open == .open)
        #expect(done == .done(streak: 3))

        let waiting = MemoryCardDayCounts(due: 2, new: 1, practice: 4)
        #expect(MobileMemoryScreenCopy.primaryTitle(state: open, counts: waiting) == "Start Review")
        #expect(MobileMemoryScreenCopy.primaryTitle(state: done, counts: waiting) == "Keep Going")
        #expect(MobileMemoryScreenCopy.primaryTitle(state: open, counts: MemoryCardDayCounts(due: 0, new: 0, practice: 4)) == nil, "no card waits today")
        #expect(MobileMemoryScreenCopy.primaryTitle(state: .ended(afterSeconds: 120), counts: waiting) == nil)

        #expect(MobileMemoryScreenCopy.promise(state: open) == nil, "the Mac's promise is its committed session, which the phone does not hold")
        #expect(MobileMemoryScreenCopy.promise(state: done) == "Today's review is done.")
        #expect(MobileMemoryScreenCopy.promise(state: .ended(afterSeconds: 120)) == nil)
    }

    @Test("All Cards says New, Due, Tomorrow, or the day a card is next asked")
    func statusLine() {
        let calendar = Self.calendar
        let now = Self.now
        #expect(MobileMemoryScreenCopy.statusLine(MemorySchedule(memoryItemID: "a", dueAt: now.addingTimeInterval(Self.day)), now: now, calendar: calendar) == "New")
        let seen = { (dueAt: Date) in
            MemorySchedule(memoryItemID: "b", dueAt: dueAt, lastAttemptAt: now.addingTimeInterval(-Self.day), repetitionCount: 1)
        }
        #expect(MobileMemoryScreenCopy.statusLine(seen(now.addingTimeInterval(-60)), now: now, calendar: calendar) == "Due")
        #expect(MobileMemoryScreenCopy.statusLine(seen(now), now: now, calendar: calendar) == "Due")
        #expect(MobileMemoryScreenCopy.statusLine(seen(now.addingTimeInterval(Self.day)), now: now, calendar: calendar) == "Tomorrow")
        let later = now.addingTimeInterval(5 * Self.day)
        #expect(MobileMemoryScreenCopy.statusLine(seen(later), now: now, calendar: calendar) == later.formatted(.dateTime.month(.abbreviated).day()))
    }

    // MARK: - The history grid's days

    @Test("The grid opens earlier days' review chats, colours a day from an answer in its chat, and opens nothing hidden, empty or today's")
    func historyDays() {
        let sessions = [
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 2))", hasTurns: true, isAnswered: true, isHidden: false),
            // The morning prepared it and nobody sat: openable, not coloured.
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 3))", hasTurns: true, isAnswered: false, isHidden: false),
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 4))", hasTurns: true, isAnswered: true, isHidden: true),
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 5))", hasTurns: false, isAnswered: false, isHidden: false),
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 0))", hasTurns: true, isAnswered: true, isHidden: false),
            MobileMemoryHistoryDays.Session(id: "memory-review-topic", hasTurns: true, isAnswered: true, isHidden: false),
            MobileMemoryHistoryDays.Session(id: "ios-chat-1", hasTurns: true, isAnswered: true, isHidden: false),
        ]
        let days = MobileMemoryHistoryDays.days(of: sessions, now: Self.now, calendar: Self.calendar)
        #expect(days.chatDays == [key(daysAgo: 2), key(daysAgo: 3)], "today's is Start Review's; a hidden or empty chat opens nothing")
        #expect(days.answeredDays == [key(daysAgo: 2), key(daysAgo: 4), key(daysAgo: 0)], "an answer colours its day, hidden or today's alike")
        #expect(MobileMemoryHistoryDays.sessionID(day: key(daysAgo: 2)) == MemoryReviewSession.sessionID(for: Self.now.addingTimeInterval(-2 * Self.day), calendar: Self.calendar))
    }

    @Test("Read through the Mac's rule, those days and the synced minutes draw the run: a third, two thirds, solid; today outlined; the rest of the week a hole")
    func historyGrid() throws {
        let calendar = Self.calendar
        let sessions = [
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 9))", hasTurns: true, isAnswered: true, isHidden: false),
            MobileMemoryHistoryDays.Session(id: "memory-\(key(daysAgo: 8))", hasTurns: true, isAnswered: false, isHidden: false),
        ]
        let days = MobileMemoryHistoryDays.days(of: sessions, now: Self.now, calendar: calendar)
        let progress = [
            key(daysAgo: 1): MemoryReviewDayProgress(day: key(daysAgo: 1), activeSeconds: 900, goalSeconds: 900),
            key(daysAgo: 2): MemoryReviewDayProgress(day: key(daysAgo: 2), activeSeconds: 500, goalSeconds: 900),
            key(daysAgo: 3): MemoryReviewDayProgress(day: key(daysAgo: 3), activeSeconds: 120, goalSeconds: 900),
            key(daysAgo: 0): MemoryReviewDayProgress(day: key(daysAgo: 0), activeSeconds: 0, goalSeconds: 900),
        ]
        let grid = MemoryReviewHistory.grid(
            chatDays: days.chatDays,
            answeredDays: days.answeredDays,
            progress: progress,
            weeks: MemoryReviewHistory.defaultWeeks,
            now: Self.now,
            calendar: calendar
        )
        #expect(grid.weeks.count == 24, "half a year of columns")
        #expect(grid.weeks.allSatisfy { $0.days.count == 7 }, "a column a week")
        let byKey = Dictionary(uniqueKeysWithValues: grid.weeks.flatMap(\.days).map { ($0.key, $0) })
        #expect(byKey[key(daysAgo: 1)]?.level == .met)
        #expect(byKey[key(daysAgo: 2)]?.level == .most)
        #expect(byKey[key(daysAgo: 3)]?.level == .partial)
        #expect(byKey[key(daysAgo: 9)]?.level == .partial, "an answered chat with no minutes happened")
        #expect(byKey[key(daysAgo: 9)]?.hasChat == true)
        #expect(byKey[key(daysAgo: 8)]?.level == MemoryReviewHistory.Level.none, "a chat nobody sat is no review")
        #expect(byKey[key(daysAgo: 8)]?.hasChat == true, "but it still opens")
        let today = try #require(byKey[key(daysAgo: 0)])
        #expect(today.isToday)
        #expect(!today.hasChat)
        #expect(grid.reviewedDays == 4)
        let lastWeek = try #require(grid.weeks.last)
        #expect(lastWeek.days.contains { $0.isToday }, "the last column is the week being lived")
        #expect(lastWeek.days.filter(\.isFuture).count == 3, "Friday to Sunday are a hole, not misses")
    }

    @Test("A picked day says its date and what happened on it, never a count of days")
    func dayDescription() {
        let calendar = Self.calendar
        let date = Self.now.addingTimeInterval(-2 * Self.day)
        let title = MemoryReviewSession.title(for: date, calendar: calendar)
        func day(_ level: MemoryReviewHistory.Level, seconds: TimeInterval, isToday: Bool = false) -> MemoryReviewHistory.Day {
            MemoryReviewHistory.Day(key: key(daysAgo: 2), date: date, level: level, activeSeconds: seconds, hasChat: false, isToday: isToday, isFuture: false)
        }
        #expect(MobileMemoryScreenCopy.dayDescription(day(.none, seconds: 0), calendar: calendar) == title)
        #expect(MobileMemoryScreenCopy.dayDescription(day(.none, seconds: 0, isToday: true), calendar: calendar) == "\(title) · today")
        #expect(MobileMemoryScreenCopy.dayDescription(day(.most, seconds: 610), calendar: calendar) == "\(title) · 10 min")
        #expect(MobileMemoryScreenCopy.dayDescription(day(.partial, seconds: 0), calendar: calendar) == "\(title) · review")
        #expect(MobileMemoryScreenCopy.dayDescription(day(.met, seconds: 900, isToday: true), calendar: calendar) == "\(title) · 15 min · today")
    }

    // MARK: - Fitting a phone

    @Test("Half a year fits every iPhone, the squares growing with the width up to an iPad's, and a narrow split shows fewer weeks")
    func layout() {
        // An iPhone's width less the screen's 16-point margins.
        #expect(MobileMemoryHistoryLayout.weeks(width: 343) == 24)
        #expect(MobileMemoryHistoryLayout.cellSize(width: 343, weeks: 24) == 10)
        #expect(MobileMemoryHistoryLayout.cellSize(width: 361, weeks: 24) == 11, "the Mac's square")
        #expect(MobileMemoryHistoryLayout.cellSize(width: 408, weeks: 24) == 13)
        #expect(MobileMemoryHistoryLayout.weeks(width: 688) == 24)
        #expect(MobileMemoryHistoryLayout.cellSize(width: 688, weeks: 24) == 16, "an iPad's squares stop growing")

        let narrow = MobileMemoryHistoryLayout.weeks(width: 250)
        #expect(narrow == 21)
        #expect(MobileMemoryHistoryLayout.cellSize(width: 250, weeks: narrow) == 8)
        let used = Double(narrow) * 8 + Double(narrow - 1) * MobileMemoryHistoryLayout.spacing
            + MobileMemoryHistoryLayout.gutterWidth + MobileMemoryHistoryLayout.gutterGap
        #expect(used <= 250, "the grid fits its width")
        #expect(MobileMemoryHistoryLayout.weeks(width: 0) == 1, "before the width is known")
    }
}
