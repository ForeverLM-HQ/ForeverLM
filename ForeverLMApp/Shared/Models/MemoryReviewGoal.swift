import Foundation

/// The day's goal: the review's time budget, spent.
///
/// Foundation only, compiled into the Mac and the iPhone (listed for the phone
/// in project.yml). Not in Shared/Portable: the web Studio has no Memory
/// review surface, and everything in Portable ships in the website's wasm.
///
/// `MemoryReviewBudget` says how long today's review is planned to take. The
/// goal is the same number read the other way round — the minutes the learner
/// actually spends on the review, on whichever device, before the day counts
/// as done. Time counts while the review chat is on screen and the learner is
/// doing something in it: typing, sending, picking a chip, scrolling, or
/// reading a reply as it streams. A chat left open on a desk counts nothing
/// after `idleGrace`.
///
/// One number, one day, one streak. Every client computes the same result
/// from the same synced rows, so the badge on the Mac's Memory row and the
/// card on the phone never disagree about whether today is done.
enum MemoryReviewGoal {
    /// How long after the learner's last input the clock keeps running. Long
    /// enough to think about an answer; short enough that a chat left open
    /// stops counting before the coffee is made.
    static let idleGrace: TimeInterval = 90

    /// How often a client advances the clock while the review is on screen.
    /// Once a second: the review's own clock reads the snapshot straight off
    /// this tick, so a slower beat made it jump several seconds at a time.
    static let heartbeat: TimeInterval = 1

    /// The most one heartbeat may credit. A Mac that slept for an hour with
    /// the review open comes back to a few seconds, not an hour. Wider than
    /// the beat itself so a tick that lands late on a busy main thread still
    /// credits the whole interval.
    static let maximumTickCredit: TimeInterval = 15

    /// How often accrued time is written to the store while the review runs.
    /// Also the most a crash can lose.
    static let persistInterval: TimeInterval = 30

    static func goalSeconds(budgetMinutes: Int) -> TimeInterval {
        TimeInterval(MemoryReviewBudget.clamp(budgetMinutes)) * 60
    }

    /// "2026-09-05": the local day, the unit the goal and the streak count in.
    /// The same day the review's session id names.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        DailyNote.dayKey(for: date, calendar: calendar)
    }

    /// The day before, in the same key form. Nil for a malformed key.
    static func previousDayKey(_ dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = date(fromDayKey: dayKey, calendar: calendar),
              let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        return Self.dayKey(for: previous, calendar: calendar)
    }

    static func date(fromDayKey dayKey: String, calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components)
    }

    /// One row per device per day. A device only ever writes its own row, so
    /// two devices accruing time on the same day never overwrite each other;
    /// the day's total is the sum.
    static func activityID(day: String, deviceID: String) -> String {
        "\(day)#\(deviceID)"
    }

    /// What the Memory row trails, and what the review's own chrome shows.
    ///
    /// The minutes are a clock on a review that is running, never a demand made
    /// of a day that has not started one: a learner who has not sat down yet is
    /// not told they owe fifteen minutes, and a day whose review already
    /// happened is not told it again. `quiet` is the resting state, and the
    /// row's label stands alone.
    enum Badge: Equatable, Sendable {
        /// Nothing trails the label.
        case quiet
        /// The review is on screen: the time still to go on today's goal,
        /// counting down as it is spent.
        case remaining(TimeInterval)
        /// Today's goal is met. The streak, and no minutes.
        case done(streak: Int)
    }

    /// `reviewIsUnderway` is whether a review is on screen on this device right
    /// now — the only state in which minutes are worth showing.
    static func badge(snapshot: MemoryReviewGoalSnapshot, reviewIsUnderway: Bool) -> Badge {
        if snapshot.isTodayComplete { return .done(streak: snapshot.streak) }
        guard reviewIsUnderway else { return .quiet }
        return .remaining(snapshot.today.remainingSeconds)
    }

    /// "15 min", "1 min", "under a minute".
    static func remainingLabel(seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds <= 0 { return "done" }
        if minutes <= 1 && seconds < 60 { return "under a minute" }
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

/// What one device did towards one day's goal. Synced as its own record.
struct MemoryReviewActivity: Codable, Hashable, Sendable {
    let id: String
    let day: String
    let deviceID: String
    var activeSeconds: TimeInterval
    /// The goal in force on this device when the row was last written, so a
    /// past day is judged by the goal it had, not by today's setting.
    var goalSeconds: TimeInterval
    var updatedAt: Date

    init(day: String, deviceID: String, activeSeconds: TimeInterval, goalSeconds: TimeInterval, updatedAt: Date) {
        self.id = MemoryReviewGoal.activityID(day: day, deviceID: deviceID)
        self.day = day
        self.deviceID = deviceID
        self.activeSeconds = activeSeconds
        self.goalSeconds = goalSeconds
        self.updatedAt = updatedAt
    }
}

/// One day against its goal, summed over every device.
struct MemoryReviewDayProgress: Equatable, Sendable {
    let day: String
    let activeSeconds: TimeInterval
    let goalSeconds: TimeInterval

    var isComplete: Bool { goalSeconds > 0 && activeSeconds >= goalSeconds }
    var remainingSeconds: TimeInterval { max(0, goalSeconds - activeSeconds) }
    var fraction: Double {
        guard goalSeconds > 0 else { return 0 }
        return min(1, activeSeconds / goalSeconds)
    }

    static func empty(day: String, goalSeconds: TimeInterval) -> MemoryReviewDayProgress {
        MemoryReviewDayProgress(day: day, activeSeconds: 0, goalSeconds: goalSeconds)
    }
}

/// Today, and the streak: what the Memory row and the Home card show.
struct MemoryReviewGoalSnapshot: Equatable, Sendable {
    var today: MemoryReviewDayProgress
    /// Consecutive days done, ending today or yesterday. Yesterday keeps the
    /// streak alive until today is missed, so a learner who opens the app in
    /// the morning sees the run they are about to extend, not zero.
    var streak: Int

    var isTodayComplete: Bool { today.isComplete }

    static func empty(day: String, goalSeconds: TimeInterval) -> MemoryReviewGoalSnapshot {
        MemoryReviewGoalSnapshot(today: .empty(day: day, goalSeconds: goalSeconds), streak: 0)
    }
}

/// The arithmetic every client runs over the synced rows.
enum MemoryReviewProgress {

    /// Days summed over devices. A day's goal is the one on the row written
    /// most recently, which is the goal in force when the day was last worked.
    static func days(from rows: [MemoryReviewActivity]) -> [String: MemoryReviewDayProgress] {
        var byDay: [String: (seconds: TimeInterval, goal: TimeInterval, goalAt: Date)] = [:]
        for row in rows {
            if var existing = byDay[row.day] {
                existing.seconds += max(0, row.activeSeconds)
                if row.updatedAt > existing.goalAt {
                    existing.goal = row.goalSeconds
                    existing.goalAt = row.updatedAt
                }
                byDay[row.day] = existing
            } else {
                byDay[row.day] = (max(0, row.activeSeconds), row.goalSeconds, row.updatedAt)
            }
        }
        var result: [String: MemoryReviewDayProgress] = [:]
        for (day, entry) in byDay {
            result[day] = MemoryReviewDayProgress(day: day, activeSeconds: entry.seconds, goalSeconds: entry.goal)
        }
        return result
    }

    /// Consecutive completed days ending today, or ending yesterday when
    /// today is not done yet. Two misses in a row is zero.
    static func streak(completedDays: Set<String>, today: String, calendar: Calendar = .current) -> Int {
        var cursor: String? = completedDays.contains(today)
            ? today
            : MemoryReviewGoal.previousDayKey(today, calendar: calendar)
        var count = 0
        while let day = cursor, completedDays.contains(day) {
            count += 1
            cursor = MemoryReviewGoal.previousDayKey(day, calendar: calendar)
        }
        return count
    }
}

/// The clock one client runs while the review is on screen.
///
/// Pure: fed timestamps, it says how many seconds to credit. Each heartbeat
/// credits the time since the last one if the learner did something within
/// `MemoryReviewGoal.idleGrace` of now, or the tutor is mid-reply — reading a
/// streamed answer is part of the review — and nothing otherwise. A gap
/// longer than `maximumTickCredit` (the app slept, the Mac slept) credits
/// only that much.
struct MemoryReviewEngagementClock: Equatable, Sendable {
    private(set) var lastActivityAt: Date?
    private(set) var lastTickAt: Date?
    let idleGrace: TimeInterval
    let maximumTickCredit: TimeInterval

    init(
        idleGrace: TimeInterval = MemoryReviewGoal.idleGrace,
        maximumTickCredit: TimeInterval = MemoryReviewGoal.maximumTickCredit
    ) {
        self.idleGrace = idleGrace
        self.maximumTickCredit = maximumTickCredit
    }

    /// The learner did something: a key, a click, a scroll, a chip.
    mutating func noteActivity(at now: Date) {
        lastActivityAt = now
    }

    /// The review came on screen. The first tick after this credits nothing;
    /// it only starts the interval.
    mutating func start(at now: Date) {
        lastTickAt = now
    }

    /// The review left the screen. The next `start` begins a fresh interval.
    mutating func stop() {
        lastTickAt = nil
    }

    /// Whether the learner counts as engaged right now.
    func isEngaged(at now: Date, tutorIsResponding: Bool) -> Bool {
        if tutorIsResponding { return true }
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) <= idleGrace
    }

    /// Advances the clock and returns the seconds to credit.
    @discardableResult
    mutating func tick(at now: Date, tutorIsResponding: Bool) -> TimeInterval {
        defer { lastTickAt = now }
        guard let lastTickAt else { return 0 }
        let elapsed = now.timeIntervalSince(lastTickAt)
        guard elapsed > 0, isEngaged(at: now, tutorIsResponding: tutorIsResponding) else { return 0 }
        return min(elapsed, maximumTickCredit)
    }
}

/// The day's review ended before its goal: the learner left, and the day
/// does not count. Its cards can still be gone through, with no
/// clock and no second commitment.
///
/// Written by the device the learner left on and read back by it, so a
/// relaunch the same day knows the session is over. A record from another
/// day says nothing about today; the day key is what makes it apply.
struct MemoryReviewSessionEnd: Codable, Equatable, Sendable {
    /// "2026-09-19", the day the session was ended on.
    let day: String
    /// What the day had counted, over every device, when it was ended.
    let activeSeconds: TimeInterval
    let endedAt: Date

    func applies(to day: String) -> Bool {
        self.day == day
    }
}

/// The commitment: starting today's review is a promise of the goal's minutes.
///
/// The product owner (2026-09-19), on a badge reading "under a minute": "i don't get
/// this memory timer to be honest. i think it should just lock me into the
/// app for 15 mins; and i can also quit but then the memory session is over.
/// there needs to be a focused commitment to do that session". So a review
/// is not a chat with a clock beside it that pauses when the learner steps
/// out; it is a session, and leaving it before the goal ends it for the day.
/// Since 2026-10-12 an ended day still deals its cards (product owner, at "30
/// cards today" over "Today's review ended." with no button: "nothing here to
/// click and start reviewing … someone should be naive to the app and just
/// 'get it'"): Keep Going opens them as a done day's does, uncommitted and
/// with no clock, and the day stays ended.
/// These are the rules — pure, so both clients can hold them; the Mac's
/// `MemoryReviewEngagementTracker` runs them today.
enum MemoryReviewCommitment {
    /// Where today's review stands.
    enum State: Equatable, Sendable {
        /// Today's review can be started, or is being sat: the goal is not
        /// met and nothing has ended it.
        case open
        /// The learner ended the session with minutes still to go. The day
        /// does not count, but its cards can still be gone through;
        /// `afterSeconds` is what the day had counted when they did.
        case ended(afterSeconds: TimeInterval)
        /// The goal is met. Nothing more is asked of the day, and leaving the
        /// review ends nothing.
        case done(streak: Int)
    }

    /// Today's state from the synced rows and this device's own end record.
    /// Done wins over ended: a day whose goal was met elsewhere after this
    /// device gave up is a day done, and done is done.
    ///
    /// `cardsFinished` is the card review's other way to be done: every card
    /// today asked for was answered before the goal's minutes were spent.
    /// The day is done when the cards run out, rather than padded to the
    /// minutes (decisions 2026-09-30, the product owner's call 1); the Mac records it
    /// for the day on the device it happened on.
    static func state(
        snapshot: MemoryReviewGoalSnapshot,
        end: MemoryReviewSessionEnd?,
        cardsFinished: Bool = false
    ) -> State {
        if snapshot.isTodayComplete || cardsFinished { return .done(streak: snapshot.streak) }
        if let end, end.applies(to: snapshot.today.day) { return .ended(afterSeconds: end.activeSeconds) }
        return .open
    }

    /// What leaving the review writes down: an end record while the goal is
    /// unmet, nothing once it is met. Leaving a finished review is walking out
    /// of a room, not breaking a promise.
    static func end(snapshot: MemoryReviewGoalSnapshot, now: Date) -> MemoryReviewSessionEnd? {
        guard !snapshot.isTodayComplete else { return nil }
        return MemoryReviewSessionEnd(
            day: snapshot.today.day,
            activeSeconds: snapshot.today.activeSeconds,
            endedAt: now
        )
    }

    /// Whether leaving the review now is the explicit "end the session" that
    /// deserves a word first. Only while it is open: a done review's × is a
    /// plain way out.
    static func leavingEndsSession(_ state: State) -> Bool {
        if case .open = state { return true }
        return false
    }

    /// Whether the clock credits time. Not on a day whose session is over: a
    /// chat reopened to read back is a record, and minutes spent in it are not
    /// a second session.
    static func clockRuns(_ state: State) -> Bool {
        if case .ended = state { return false }
        return true
    }
}

/// The run of review days, as a grid: a square a day, a week a column, the
/// darkest squares the days whose goal was met.
///
/// Read from the rows the goal and the streak are read from, so a square is
/// dark here for exactly the reason its day counted there. A day that has a
/// review chat but no minutes — every review before the goal shipped, and any
/// review sat on a client that was not counting — still draws, faintly: it
/// happened, and a grid that denied it would be wrong about the learner's own
/// history.
///
/// The grid is the whole of what the Memory pane says about the past.
/// It replaced a list of dates, one row a day, which said only that a review
/// existed and made eight days look like a filing cabinet; the grid shows the
/// rhythm instead, the way commits are shown. No
/// streak number goes with it: the run is there to be seen in the squares, and
/// a count beside them would turn a missed week into a failure.
enum MemoryReviewHistory {
    /// Weeks the grid covers. Half a year of columns is what fits the sheet at
    /// a legible square, and it is long enough that a fortnight off reads as a
    /// gap in a practice rather than as the whole picture.
    static let defaultWeeks = 24

    /// How dark one day's square is drawn.
    enum Level: Int, Comparable, Sendable {
        case none = 0
        /// A review happened. Either some minutes short of half the goal, or a
        /// chat with no minutes recorded at all.
        case partial = 1
        /// Half the goal or better, short of it.
        case most = 2
        /// The day's goal was met.
        case met = 3

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Day: Identifiable, Equatable, Sendable {
        /// "2026-09-17", the same key the goal counts in.
        let key: String
        let date: Date
        let level: Level
        let activeSeconds: TimeInterval
        /// Whether a review chat exists for the day, which is what makes the
        /// square openable.
        let hasChat: Bool
        let isToday: Bool
        /// A day in the current week that has not happened yet. Drawn as a
        /// hole rather than as an empty day: the week is not over.
        let isFuture: Bool

        var id: String { key }
    }

    struct Week: Identifiable, Equatable, Sendable {
        let index: Int
        let days: [Day]

        var id: Int { index }
    }

    /// A month's name over the column its first week falls in.
    struct MonthLabel: Identifiable, Equatable, Sendable {
        let column: Int
        let title: String

        var id: Int { column }
    }

    struct Grid: Equatable, Sendable {
        let weeks: [Week]
        let monthLabels: [MonthLabel]
        /// Days in the window that carry a review of any length.
        let reviewedDays: Int

        static let empty = Grid(weeks: [], monthLabels: [], reviewedDays: 0)
    }

    /// A day whose goal is unknown — no activity row, only a chat the learner
    /// wrote in — is a review that happened, so it draws at `partial` rather
    /// than vanishing. `answered` is that: an exchange with the learner's
    /// answer in it. The bare existence of the day's chat is not evidence,
    /// because the morning preparation makes the chat with its opening
    /// question before anyone has sat down; a day that stopped there was
    /// skipped, and drew faintly as if it had not been.
    static func level(activeSeconds: TimeInterval, goalSeconds: TimeInterval, answered: Bool) -> Level {
        if goalSeconds > 0, activeSeconds > 0 {
            let fraction = activeSeconds / goalSeconds
            if fraction >= 1 { return .met }
            return fraction >= 0.5 ? .most : .partial
        }
        if activeSeconds > 0 { return .partial }
        return answered ? .partial : .none
    }

    /// Columns run oldest to newest and end with the week today is in, so the
    /// last column is always the one being lived.
    /// `chatDays` are the days with a chat to open; `answeredDays` the subset
    /// the learner wrote in, which is what colours a day that has no minutes.
    static func grid(
        chatDays: Set<String>,
        answeredDays: Set<String>,
        progress: [String: MemoryReviewDayProgress],
        weeks: Int = defaultWeeks,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Grid {
        let columns = max(1, weeks)
        let today = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstColumn = calendar.date(byAdding: .weekOfYear, value: -(columns - 1), to: thisWeek)
        else { return .empty }

        var built: [Week] = []
        var labels: [MonthLabel] = []
        var reviewed = 0
        var lastLabelledMonth: Int?

        for column in 0..<columns {
            guard let columnStart = calendar.date(byAdding: .day, value: column * 7, to: firstColumn) else { continue }
            var days: [Day] = []
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: columnStart) else { continue }
                let key = MemoryReviewGoal.dayKey(for: date, calendar: calendar)
                let day = progress[key]
                let isFuture = date > today
                let hasChat = chatDays.contains(key)
                let level = isFuture
                    ? Level.none
                    : self.level(
                        activeSeconds: day?.activeSeconds ?? 0,
                        goalSeconds: day?.goalSeconds ?? 0,
                        answered: answeredDays.contains(key)
                    )
                if level != .none { reviewed += 1 }
                days.append(
                    Day(
                        key: key,
                        date: date,
                        level: level,
                        activeSeconds: day?.activeSeconds ?? 0,
                        hasChat: hasChat && !isFuture,
                        isToday: calendar.isDate(date, inSameDayAs: today),
                        isFuture: isFuture
                    )
                )
            }
            built.append(Week(index: column, days: days))

            // A column belongs to the month its first day falls in, and only
            // the first column of a month is named — the labels would collide
            // otherwise, and a month is four columns wide.
            let month = calendar.component(.month, from: columnStart)
            if month != lastLabelledMonth {
                lastLabelledMonth = month
                let symbols = calendar.shortMonthSymbols
                if month >= 1, month <= symbols.count {
                    labels.append(MonthLabel(column: column, title: symbols[month - 1]))
                }
            }
        }

        return Grid(weeks: built, monthLabels: labels, reviewedDays: reviewed)
    }
}
