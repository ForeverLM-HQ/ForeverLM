import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The daily goal and the streak (docs/memory-design.md, "The daily goal and
/// the streak"): the day key, the clock's idle rule, the per-device sum, the
/// streak's yesterday rule, and schema 91's row round-tripping through the
/// store and the sync payload.
@Suite("Memory review goal")
struct MemoryReviewGoalTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("The day key is the local day the session id names")
    func dayKey() {
        // 2026-09-03 14:00 UTC.
        let date = Date(timeIntervalSince1970: 1_788_444_000)
        #expect(MemoryReviewGoal.dayKey(for: date, calendar: utc) == "2026-09-03")
        #expect(MemoryReviewSession.sessionID(for: date, calendar: utc).hasSuffix(MemoryReviewGoal.dayKey(for: date, calendar: utc)))
        #expect(MemoryReviewGoal.previousDayKey("2026-09-01", calendar: utc) == "2026-08-31")
        #expect(MemoryReviewGoal.previousDayKey("2026-01-01", calendar: utc) == "2025-12-31")
        #expect(MemoryReviewGoal.previousDayKey("not a day", calendar: utc) == nil)
        #expect(MemoryReviewGoal.activityID(day: "2026-09-05", deviceID: "mac-1") == "2026-09-05#mac-1")
        #expect(MemoryReviewGoal.goalSeconds(budgetMinutes: 15) == 900)
        // Clamped like the budget itself.
        #expect(MemoryReviewGoal.goalSeconds(budgetMinutes: 1) == TimeInterval(MemoryReviewBudget.minimumMinutes * 60))
    }

    @Test("The remaining label rounds up to whole minutes")
    func remainingLabel() {
        #expect(MemoryReviewGoal.remainingLabel(seconds: 900) == "15 min")
        #expect(MemoryReviewGoal.remainingLabel(seconds: 61) == "2 min")
        #expect(MemoryReviewGoal.remainingLabel(seconds: 60) == "1 min")
        #expect(MemoryReviewGoal.remainingLabel(seconds: 12) == "under a minute")
        #expect(MemoryReviewGoal.remainingLabel(seconds: 0) == "done")
    }

    @Test("The countdown keeps one shape and never runs past zero")
    func countdownLabel() {
        #expect(MemoryReviewGoal.countdownLabel(seconds: 900) == "15:00")
        #expect(MemoryReviewGoal.countdownLabel(seconds: 61) == "1:01")
        #expect(MemoryReviewGoal.countdownLabel(seconds: 0.4) == "0:01")
        #expect(MemoryReviewGoal.countdownLabel(seconds: 0) == "0:00")
        #expect(MemoryReviewGoal.countdownLabel(seconds: -30) == "0:00")
    }

    @Test("Minutes show only while a review is running; a day that already met its goal shows the streak")
    func badgeIsAClockNotADemand() {
        let goal = MemoryReviewGoal.goalSeconds(budgetMinutes: 15)
        let untouched = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-09-05", activeSeconds: 0, goalSeconds: goal),
            streak: 3
        )
        // Nothing has started: the row says nothing rather than asking for
        // fifteen minutes.
        #expect(MemoryReviewGoal.badge(snapshot: untouched, reviewIsUnderway: false) == .quiet)
        #expect(MemoryReviewGoal.badge(snapshot: untouched, reviewIsUnderway: true) == .remaining(goal))

        // A review that ran earlier and left minutes on the day is still not a
        // demand once the learner has left it.
        let partly = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-09-05", activeSeconds: 240, goalSeconds: goal),
            streak: 3
        )
        #expect(MemoryReviewGoal.badge(snapshot: partly, reviewIsUnderway: false) == .quiet)
        #expect(MemoryReviewGoal.badge(snapshot: partly, reviewIsUnderway: true) == .remaining(goal - 240))

        // Done is done, on screen or not.
        let done = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-09-05", activeSeconds: goal, goalSeconds: goal),
            streak: 4
        )
        #expect(MemoryReviewGoal.badge(snapshot: done, reviewIsUnderway: false) == .done(streak: 4))
        #expect(MemoryReviewGoal.badge(snapshot: done, reviewIsUnderway: true) == .done(streak: 4))
    }

    /// The review moves hosts when the window gives itself over to it and when
    /// the learner leaves again: SwiftUI builds the second panel before it
    /// tears the first one down, and both wrap the same session manager. Keyed
    /// by the manager, the departing panel's dismissal cancelled the arriving
    /// panel's registration, and the clock stopped on a review still on screen
    /// — the rail's badge went out the moment the workspace came back.
    @MainActor
    @Test("A review rehosted mid-session keeps its clock; the last panel to go stops it")
    func presenceIsKeyedToThePanelNotTheManager() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memory-goal-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let tracker = MemoryReviewEngagementTracker.shared
        let manager = ReviewSessionManager()
        let sessionID = MemoryReviewSession.sessionID(for: Date())
        let arriving = UUID()
        let departing = UUID()

        tracker.present(manager, panel: departing, sessionID: sessionID, storage: storage)
        #expect(tracker.isReviewOnScreen)

        tracker.present(manager, panel: arriving, sessionID: sessionID, storage: storage)
        tracker.dismiss(panel: departing)
        #expect(tracker.isReviewOnScreen)

        tracker.dismiss(panel: arriving)
        #expect(!tracker.isReviewOnScreen)
    }

    @Test("The clock credits engaged intervals and nothing idle, backgrounded, or asleep")
    func clock() {
        var clock = MemoryReviewEngagementClock(idleGrace: 90, maximumTickCredit: 15)
        let start = Date(timeIntervalSince1970: 1_788_444_000)
        // Nothing has started: no credit.
        #expect(clock.tick(at: start, tutorIsResponding: false) == 0)
        clock.start(at: start)
        // No activity yet, tutor quiet: the learner is not engaged.
        #expect(clock.tick(at: start.addingTimeInterval(5), tutorIsResponding: false) == 0)
        // A key press; the next ticks count.
        clock.noteActivity(at: start.addingTimeInterval(6))
        #expect(clock.tick(at: start.addingTimeInterval(10), tutorIsResponding: false) == 5)
        #expect(clock.tick(at: start.addingTimeInterval(15), tutorIsResponding: false) == 5)
        // Ninety seconds after the key press the grace runs out.
        #expect(clock.tick(at: start.addingTimeInterval(96), tutorIsResponding: false) == 15)
        #expect(clock.tick(at: start.addingTimeInterval(101), tutorIsResponding: false) == 0)
        // Reading a streamed reply counts without any input.
        #expect(clock.tick(at: start.addingTimeInterval(106), tutorIsResponding: true) == 5)
        // The Mac slept for an hour with the chat open: one tick's cap, not an hour.
        clock.noteActivity(at: start.addingTimeInterval(3_700))
        #expect(clock.tick(at: start.addingTimeInterval(3_706), tutorIsResponding: false) == 15)
        // Leaving the screen and coming back starts a fresh interval.
        clock.stop()
        #expect(clock.tick(at: start.addingTimeInterval(3_800), tutorIsResponding: true) == 0)
        clock.start(at: start.addingTimeInterval(3_800))
        #expect(clock.tick(at: start.addingTimeInterval(3_805), tutorIsResponding: true) == 5)
    }

    private func row(_ day: String, _ device: String, _ seconds: TimeInterval, goal: TimeInterval = 900, at: TimeInterval = 0) -> MemoryReviewActivity {
        MemoryReviewActivity(
            day: day,
            deviceID: device,
            activeSeconds: seconds,
            goalSeconds: goal,
            updatedAt: Date(timeIntervalSinceReferenceDate: at)
        )
    }

    @Test("A day sums every device; its goal is the one most recently written")
    func daysSumAcrossDevices() {
        let days = MemoryReviewProgress.days(from: [
            row("2026-09-04", "mac", 500, goal: 900, at: 10),
            row("2026-09-04", "phone", 400, goal: 600, at: 20),
            row("2026-09-03", "mac", 200),
        ])
        #expect(days["2026-09-04"]?.activeSeconds == 900)
        #expect(days["2026-09-04"]?.goalSeconds == 600)
        #expect(days["2026-09-04"]?.isComplete == true)
        #expect(days["2026-09-03"]?.isComplete == false)
        #expect(days["2026-09-03"]?.remainingSeconds == 700)
    }

    @Test("The streak ends today when today is done, else yesterday; two misses is zero")
    func streak() {
        let done: Set<String> = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"]
        #expect(MemoryReviewProgress.streak(completedDays: done, today: "2026-09-04", calendar: utc) == 4)
        // Today not yet done: yesterday's run still stands.
        #expect(MemoryReviewProgress.streak(completedDays: done, today: "2026-09-05", calendar: utc) == 4)
        // Yesterday missed: the run is over.
        #expect(MemoryReviewProgress.streak(completedDays: done, today: "2026-09-06", calendar: utc) == 0)
        // A gap earlier stops the count there.
        #expect(MemoryReviewProgress.streak(completedDays: ["2026-09-01", "2026-09-03", "2026-09-04"], today: "2026-09-04", calendar: utc) == 2)
        #expect(MemoryReviewProgress.streak(completedDays: [], today: "2026-09-04", calendar: utc) == 0)
    }

    // MARK: - The commitment

    /// The product owner (2026-09-19): "it should just lock me into the app for 15 mins;
    /// and i can also quit but then the memory session is over. there needs to
    /// be a focused commitment to do that session".
    @Test("Leaving early ends the day; leaving a done review ends nothing; an ended day stops the clock and offers no second start")
    func commitment() {
        let goal = MemoryReviewGoal.goalSeconds(budgetMinutes: 15)
        let now = Date(timeIntervalSince1970: 1_788_444_000)
        let open = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-09-19", activeSeconds: 240, goalSeconds: goal),
            streak: 2
        )
        let done = MemoryReviewGoalSnapshot(
            today: MemoryReviewDayProgress(day: "2026-09-19", activeSeconds: goal, goalSeconds: goal),
            streak: 3
        )

        // Nothing has ended today: the review is open, and leaving is ending.
        #expect(MemoryReviewCommitment.state(snapshot: open, end: nil) == .open)
        #expect(MemoryReviewCommitment.leavingEndsSession(.open))
        #expect(MemoryReviewCommitment.clockRuns(.open))

        // Leaving with minutes to go writes down the day and what it had.
        let end = MemoryReviewCommitment.end(snapshot: open, now: now)
        #expect(end == MemoryReviewSessionEnd(day: "2026-09-19", activeSeconds: 240, endedAt: now))
        let ended = MemoryReviewCommitment.state(snapshot: open, end: end)
        #expect(ended == .ended(afterSeconds: 240))
        // The day does not count: no clock, and the × is a plain way out
        // rather than a question. Its cards can still be gone through.
        #expect(!MemoryReviewCommitment.clockRuns(ended))
        #expect(!MemoryReviewCommitment.leavingEndsSession(ended))

        // Yesterday's end says nothing about today.
        let stale = MemoryReviewSessionEnd(day: "2026-09-18", activeSeconds: 100, endedAt: now)
        #expect(!stale.applies(to: "2026-09-19"))
        #expect(MemoryReviewCommitment.state(snapshot: open, end: stale) == .open)

        // Done is done: leaving writes nothing, and a goal met elsewhere
        // after this device gave up still makes the day done.
        #expect(MemoryReviewCommitment.end(snapshot: done, now: now) == nil)
        #expect(MemoryReviewCommitment.state(snapshot: done, end: nil) == .done(streak: 3))
        #expect(MemoryReviewCommitment.state(snapshot: done, end: end) == .done(streak: 3))
        #expect(!MemoryReviewCommitment.leavingEndsSession(.done(streak: 3)))
        #expect(MemoryReviewCommitment.clockRuns(.done(streak: 3)))
    }

    // MARK: - The history grid

    /// 2026-09-18 12:00 UTC, a Friday.
    private var referenceDay: Date { Date(timeIntervalSince1970: 1_789_732_800) }

    private func progress(_ day: String, minutes: Double, goalMinutes: Double = 15) -> MemoryReviewDayProgress {
        MemoryReviewDayProgress(day: day, activeSeconds: minutes * 60, goalSeconds: goalMinutes * 60)
    }

    @Test("A day's square darkens with the minutes spent on it")
    func historyLevels() {
        #expect(MemoryReviewHistory.level(activeSeconds: 900, goalSeconds: 900, answered: true) == .met)
        #expect(MemoryReviewHistory.level(activeSeconds: 1200, goalSeconds: 900, answered: true) == .met)
        #expect(MemoryReviewHistory.level(activeSeconds: 600, goalSeconds: 900, answered: true) == .most)
        #expect(MemoryReviewHistory.level(activeSeconds: 120, goalSeconds: 900, answered: true) == .partial)
        // A review the learner wrote in with no activity row is still a
        // review: every day before the goal shipped looks like this.
        #expect(MemoryReviewHistory.level(activeSeconds: 0, goalSeconds: 0, answered: true) == .partial)
        #expect(MemoryReviewHistory.level(activeSeconds: 0, goalSeconds: 900, answered: true) == .partial)
        // Minutes with no written answer — a voice review — still colour.
        #expect(MemoryReviewHistory.level(activeSeconds: 60, goalSeconds: 900, answered: false) == .partial)
        // And a day with neither is a hole, whether or not a prepared chat
        // was waiting on it.
        #expect(MemoryReviewHistory.level(activeSeconds: 0, goalSeconds: 900, answered: false) == .none)
        #expect(MemoryReviewHistory.level(activeSeconds: 0, goalSeconds: 0, answered: false) == .none)
    }

    @Test("The grid ends with this week and counts every reviewed day")
    func historyGridShape() {
        var calendar = utc
        calendar.firstWeekday = 1
        let grid = MemoryReviewHistory.grid(
            // 2026-09-15 has a chat but no answer and no minutes: the morning
            // prepared it and nobody sat down.
            chatDays: ["2026-09-17", "2026-09-15", "2026-09-10"],
            answeredDays: ["2026-09-17", "2026-09-10"],
            progress: [
                "2026-09-17": progress("2026-09-17", minutes: 15),
                "2026-09-16": progress("2026-09-16", minutes: 4),
                "2026-09-18": progress("2026-09-18", minutes: 8)
            ],
            weeks: 4,
            now: referenceDay,
            calendar: calendar
        )

        #expect(grid.weeks.count == 4)
        #expect(grid.weeks.allSatisfy { $0.days.count == 7 })
        // Sunday-first weeks, so the last column runs 2026-09-13…2026-09-19.
        #expect(grid.weeks.last?.days.first?.key == "2026-09-13")
        #expect(grid.weeks.last?.days.last?.key == "2026-09-19")

        let days = Dictionary(uniqueKeysWithValues: grid.weeks.flatMap { $0.days }.map { ($0.key, $0) })
        #expect(days["2026-09-17"]?.level == .met)
        #expect(days["2026-09-17"]?.hasChat == true)
        // Minutes with no chat of their own still draw; there is simply
        // nothing to open.
        #expect(days["2026-09-16"]?.level == .partial)
        #expect(days["2026-09-16"]?.hasChat == false)
        #expect(days["2026-09-10"]?.level == .partial)
        // A prepared chat nobody answered opens, but draws as a hole.
        #expect(days["2026-09-15"]?.level == MemoryReviewHistory.Level.none)
        #expect(days["2026-09-15"]?.hasChat == true)
        #expect(days["2026-09-18"]?.isToday == true)
        #expect(days["2026-09-18"]?.level == .most)
        // The rest of the week has not happened, so it is neither a miss nor
        // openable.
        #expect(days["2026-09-19"]?.isFuture == true)
        #expect(days["2026-09-19"]?.level == MemoryReviewHistory.Level.none)
        #expect(days["2026-09-19"]?.hasChat == false)
        // Four days carry a review: three with minutes, one with only an
        // answered chat. The prepared, unanswered chat is not one of them.
        #expect(grid.reviewedDays == 4)
    }

    @Test("A month is named once, over the column it opens in")
    func historyMonthLabels() {
        var calendar = utc
        calendar.firstWeekday = 1
        let grid = MemoryReviewHistory.grid(
            chatDays: [],
            answeredDays: [],
            progress: [:],
            weeks: 12,
            now: referenceDay,
            calendar: calendar
        )
        let columns = grid.monthLabels.map(\.column)
        #expect(columns == Array(Set(columns)).sorted())
        #expect(grid.monthLabels.count <= 4)
        // Each label names the month its column opens in.
        for label in grid.monthLabels {
            let opening = grid.weeks[label.column].days[0].date
            let month = calendar.component(.month, from: opening)
            #expect(label.title == calendar.shortMonthSymbols[month - 1])
        }
    }

    @Test("A session id gives up the day the grid counts in")
    func historyDayKeyFromSessionID() {
        #expect(MemoryReviewSession.dayKey(fromSessionID: "memory-2026-09-17") == "2026-09-17")
        #expect(MemoryReviewSession.dayKey(fromSessionID: "memory-nonsense") == nil)
        #expect(MemoryReviewSession.dayKey(fromSessionID: UUID().uuidString) == nil)
    }

}

@Suite("Memory review goal storage", .serialized)
struct MemoryReviewGoalStorageTests {

    private static func temporaryStore() throws -> (KnowledgeStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-memory-goal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try KnowledgeStore(storeDirectory: root), root)
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    @Test("A day counts as answered once the learner wrote in its chat; a prepared chat alone does not")
    func answeredDaysReadFromExchanges() throws {
        let store = try KnowledgeStore(inMemory: true)
        // The morning made this chat and asked: the opening question is an
        // exchange whose answer is empty, the way `startMemoryReview` writes it.
        try store.createReviewSession(id: "memory-2026-09-15", topic: "Memory review", sourceIDs: [])
        try store.addReviewExchange(
            sessionID: "memory-2026-09-15", question: "", answer: "",
            evaluation: "Yesterday you read about the proton gradient. What drives it?",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // This one was sat.
        try store.createReviewSession(id: "memory-2026-09-17", topic: "Memory review", sourceIDs: [])
        try store.addReviewExchange(
            sessionID: "memory-2026-09-17", question: "Q", answer: "It is the proton gradient.",
            evaluation: "E", score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // An ordinary chat with an answer is not a memory review.
        try store.createReviewSession(id: "chat-1", topic: "Chat", sourceIDs: [])
        try store.addReviewExchange(
            sessionID: "chat-1", question: "Q", answer: "A",
            evaluation: "E", score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(try store.answeredMemoryReviewDays() == ["2026-09-17"])
    }

    @Test("A device's row is written whole and read back")
    func roundTrip() throws {
        let (store, root) = try Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = MemoryReviewActivity(day: "2026-09-05", deviceID: "mac-a", activeSeconds: 120, goalSeconds: 900, updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.recordMemoryReviewActivity(first)
        // The running total replaces the row; replaying is harmless.
        let later = MemoryReviewActivity(day: "2026-09-05", deviceID: "mac-a", activeSeconds: 300, goalSeconds: 900, updatedAt: Date(timeIntervalSinceReferenceDate: 1_030))
        try store.recordMemoryReviewActivity(later)
        try store.recordMemoryReviewActivity(later)

        let rows = try store.loadMemoryReviewActivities()
        #expect(rows == [later])
        #expect(try store.loadMemoryReviewActivity(later.id) == later)
    }
}
