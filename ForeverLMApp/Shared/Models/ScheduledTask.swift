import Foundation

/// How often a scheduled task comes due.
///
/// Deliberately a small preset list rather than a cron expression. A learner
/// setting up "quiz me every weekday morning" should not have to think in
/// five-field syntax, and every preset here maps onto one unambiguous local
/// wall-clock time, which is what the runner and both clients agree on.
enum ScheduledTaskCadence: String, Codable, CaseIterable, Sendable {
    /// Runs a single time, then stops coming due.
    case once
    case daily
    /// Monday through Friday.
    case weekdays
    case weekly
    case monthly

    var displayName: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }

    /// Whether `ScheduledTask.weekday` carries meaning for this cadence.
    var usesWeekday: Bool { self == .weekly }

    /// Whether `ScheduledTask.dayOfMonth` carries meaning for this cadence.
    var usesDayOfMonth: Bool { self == .monthly }
}

enum ScheduledTaskRunStatus: String, Codable, Sendable {
    /// Claimed by a device and currently generating.
    case running
    case succeeded
    case failed
    /// The occurrence passed while no client was running it. Recorded rather
    /// than swallowed: a task that quietly did nothing for a week should say so.
    case skipped

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Missed"
        }
    }
}

/// A recurring instruction ForeverLM sends to itself.
///
/// The instruction is ordinary chat text: when the task comes due, a client
/// starts a chat with the app's own tool surface and sends it, so the result is
/// a normal conversation the learner can read and continue. Nothing here
/// describes *how* to do the work — that stays the model's job.
struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    var instruction: String
    /// The Notebook (top-level learning goal) the produced chat is filed under.
    /// Nil files the chat in the general Chats section.
    var notebookID: String?
    /// Sources attached to every run, exactly as attaching them in Chat would.
    var sourceIDs: [String]
    var cadence: ScheduledTaskCadence
    /// `Calendar` weekday, 1 = Sunday … 7 = Saturday. Weekly cadence only.
    var weekday: Int?
    /// 1…31, clamped to the length of each month. Monthly cadence only.
    var dayOfMonth: Int?
    var hour: Int
    var minute: Int
    /// IANA identifier the wall-clock time is anchored to. "Every day at 8am"
    /// means 8am where the learner set it up, not 8am wherever a second device
    /// happens to be. Nil falls back to the reading device's current zone.
    var timeZoneID: String?
    /// The first day the task is eligible to run, and for `.once` the exact day
    /// it runs on. Nil means "from creation".
    var startDate: Date?
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    /// The occurrence instant most recently claimed by any device. This is the
    /// idempotency key: an occurrence at or before this never runs again.
    var lastOccurrenceAt: Date?
    var lastRunAt: Date?
    var lastRunStatus: ScheduledTaskRunStatus?
    /// Set by "Run now" (in either client or over MCP). The runner treats it as
    /// an extra one-off occurrence and clears it once claimed.
    var runNowRequestedAt: Date?

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        instruction: String,
        notebookID: String? = nil,
        sourceIDs: [String] = [],
        cadence: ScheduledTaskCadence = .daily,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil,
        hour: Int = 8,
        minute: Int = 0,
        timeZoneID: String? = TimeZone.current.identifier,
        startDate: Date? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOccurrenceAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastRunStatus: ScheduledTaskRunStatus? = nil,
        runNowRequestedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.notebookID = notebookID
        self.sourceIDs = sourceIDs
        self.cadence = cadence
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
        self.hour = hour
        self.minute = minute
        self.timeZoneID = timeZoneID
        self.startDate = startDate
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOccurrenceAt = lastOccurrenceAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.runNowRequestedAt = runNowRequestedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, instruction, notebookID, sourceIDs, cadence, weekday, dayOfMonth
        case hour, minute, timeZoneID, startDate, isEnabled, createdAt, updatedAt
        case lastOccurrenceAt, lastRunAt, lastRunStatus, runNowRequestedAt
    }

    /// Every optional decodes with `decodeIfPresent` so a payload written by an
    /// older or newer build still lands rather than failing the whole record.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        instruction = try container.decode(String.self, forKey: .instruction)
        notebookID = try container.decodeIfPresent(String.self, forKey: .notebookID)
        sourceIDs = try container.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
        cadence = try container.decodeIfPresent(ScheduledTaskCadence.self, forKey: .cadence) ?? .daily
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday)
        dayOfMonth = try container.decodeIfPresent(Int.self, forKey: .dayOfMonth)
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastOccurrenceAt = try container.decodeIfPresent(Date.self, forKey: .lastOccurrenceAt)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastRunStatus = try container.decodeIfPresent(ScheduledTaskRunStatus.self, forKey: .lastRunStatus)
        runNowRequestedAt = try container.decodeIfPresent(Date.self, forKey: .runNowRequestedAt)
    }
}

/// One occurrence's receipt. The durable output of a successful run is the
/// chat it produced; this row is the receipt that says which occurrence made it.
///
/// A run that failed in a way a later try may get past is tried again on the
/// same receipt (`ScheduledTaskRetry`): `attempt` counts the tries and
/// `retryAt` says when the next one is due, so one morning stays one receipt.
struct ScheduledTaskRun: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    /// The scheduled instant this run answers for. Unique per task, and the
    /// reason a second device cannot produce a duplicate chat for one morning.
    let occurrenceAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var status: ScheduledTaskRunStatus
    /// `review_sessions.id` of the chat the run produced.
    var sessionID: String?
    /// Failure text, why an occurrence was skipped, or which backup model
    /// answered and why. Never a summary of a successful run — that is the chat.
    var message: String?
    var deviceName: String?
    /// Which try at this occurrence the receipt describes, from 1.
    var attempt: Int
    /// When a failed run is tried again; nil once it is settled. Only the
    /// Mac that made the failed try picks it up (`deviceName`), since that
    /// is the Mac that was awake for it.
    var retryAt: Date?

    init(
        id: String = UUID().uuidString.lowercased(),
        taskID: String,
        occurrenceAt: Date,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: ScheduledTaskRunStatus = .running,
        sessionID: String? = nil,
        message: String? = nil,
        deviceName: String? = nil,
        attempt: Int = 1,
        retryAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.occurrenceAt = occurrenceAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.sessionID = sessionID
        self.message = message
        self.deviceName = deviceName
        self.attempt = max(1, attempt)
        self.retryAt = retryAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, occurrenceAt, startedAt, finishedAt, status, sessionID, message, deviceName
        case attempt, retryAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        taskID = try container.decode(String.self, forKey: .taskID)
        occurrenceAt = try container.decode(Date.self, forKey: .occurrenceAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? occurrenceAt
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = try container.decodeIfPresent(ScheduledTaskRunStatus.self, forKey: .status) ?? .succeeded
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        // A receipt written before retries existed was always its only try.
        attempt = max(1, try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 1)
        retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)
    }

    /// Failed, with a later try due.
    var isAwaitingRetry: Bool { status == .failed && retryAt != nil }
}

/// A task together with the receipts a client needs to render it.
struct ScheduledTaskDetail: Identifiable, Equatable, Sendable {
    var task: ScheduledTask
    var runs: [ScheduledTaskRun]
    var id: String { task.id }

    /// The receipt `deviceName` should try again now, if any: failed on this
    /// device, its next try due, and the task still on. Runs are newest first,
    /// and only the newest occurrence can be waiting, since a newer claim
    /// retires the retries before it.
    func dueRetry(deviceName: String, now: Date = Date()) -> ScheduledTaskRun? {
        guard task.isEnabled else { return nil }
        return runs.first {
            $0.isAwaitingRetry && $0.deviceName == deviceName && ($0.retryAt ?? .distantFuture) <= now
        }
    }

    /// When `deviceName` next tries one of this task's failed runs again,
    /// strictly after `now`. A try already due is `dueRetry`'s; one due that
    /// cannot be taken yet (signed out) waits for the next event rather than
    /// re-arming the timer every second.
    func upcomingRetry(deviceName: String, after now: Date = Date()) -> Date? {
        guard task.isEnabled else { return nil }
        return runs
            .filter { $0.isAwaitingRetry && $0.deviceName == deviceName }
            .compactMap(\.retryAt)
            .filter { $0 > now }
            .min()
    }
}

// MARK: - Retries

/// When a failed run is tried again (product owner, 2026-09-27: something turned on
/// overnight, "especially if it's on a free model", should not simply error
/// out). A run already walks the chat model's backups before it fails
/// (`AIBackupModels.chatConfigs`); this is the slower loop behind that, for
/// the failures only time fixes: a per-minute or per-day limit, an overloaded
/// host, a Wi-Fi that dropped at 3am.
///
/// A failure every later try would meet the same way — no balance, a refused
/// key, a model that is not offered, a Stop — is final at once. So is a try
/// that would land outside the occurrence's catch-up window: a briefing that
/// arrives the next afternoon is worse than one that says it failed.
enum ScheduledTaskRetry {
    /// Tries at one occurrence, the first included.
    static let maximumAttempts = 5

    /// The wait after each failed try, in order: past a per-minute limit and
    /// a brief outage first, then long enough for an overloaded free model
    /// to clear. About three hours in all, so a run at 2am gets its last try
    /// before 5am.
    static let delays: [TimeInterval] = [5 * 60, 15 * 60, 45 * 60, 2 * 60 * 60]

    /// When try `attempt + 1` is due, or nil when the run should stay failed.
    ///
    /// - Parameters:
    ///   - isRetryable: the failure is one a later try may get past
    ///     (`AITransientErrorClassifier.isTransient`).
    ///   - retryAfter: the server's own wait, when it named one. A later try
    ///     never comes sooner than that, and one the server puts past the
    ///     catch-up window is not made at all.
    static func retryAt(
        afterAttempt attempt: Int,
        isRetryable: Bool,
        retryAfter: TimeInterval?,
        occurrenceAt: Date,
        now: Date
    ) -> Date? {
        guard isRetryable, attempt >= 1, attempt < maximumAttempts else { return nil }
        let delay = max(delays[min(attempt - 1, delays.count - 1)], retryAfter ?? 0)
        let next = now.addingTimeInterval(delay)
        guard next.timeIntervalSince(occurrenceAt) <= ScheduledTask.catchUpWindow else { return nil }
        return next
    }

    /// "2nd try", for a receipt past its first.
    static func ordinalTry(_ attempt: Int) -> String {
        let suffix: String
        switch (attempt % 100, attempt % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(attempt)\(suffix) try"
    }
}

// MARK: - Keeping the Mac awake

/// Whether ForeverLM holds off idle sleep for scheduled tasks, and why.
///
/// A Mac that idles to sleep at 11pm runs a 2am task only when someone wakes
/// it, and ForeverLM cannot wake a sleeping Mac itself (scheduling a wake
/// needs an administrator). So the runner keeps idle sleep away instead:
///
/// - always while a run is generating, so a run in progress is never cut off
///   by the idle timer;
/// - while one is due within `lookahead`, only when the learner turned on
///   `keepMacAwakeKey` and the Mac is on power. A laptop on battery is left
///   to sleep: a drained battery runs nothing either.
///
/// The display still sleeps, and closing a laptop's lid still sleeps it.
enum ScheduledTaskWakePolicy {
    /// Device-local: each Mac decides whether it stays awake.
    static let keepMacAwakeKey = Prefs.Planner.keepMacAwakeForScheduledTasks.name
    /// How far ahead a waiting run keeps the Mac awake: the catch-up window,
    /// so a task set up in the evening for the small hours is covered from
    /// the moment the learner walks away.
    static let lookahead = ScheduledTask.catchUpWindow

    enum Hold: Equatable, Sendable {
        case none
        case running(title: String)
        case waiting(title: String, dueAt: Date)
    }

    static func hold(
        runningTitle: String?,
        nextDue: (at: Date, title: String)?,
        keepsMacAwake: Bool,
        isOnPower: Bool,
        now: Date = Date()
    ) -> Hold {
        if let runningTitle { return .running(title: runningTitle) }
        guard keepsMacAwake, isOnPower, let nextDue,
              nextDue.at.timeIntervalSince(now) <= lookahead else { return .none }
        return .waiting(title: nextDue.title, dueAt: nextDue.at)
    }

    /// When a hold that is `.none` only because the next run is too far off
    /// should be looked at again.
    static func reconsiderAt(nextDue: Date?, keepsMacAwake: Bool, now: Date = Date()) -> Date? {
        guard keepsMacAwake, let nextDue else { return nil }
        let start = nextDue.addingTimeInterval(-lookahead)
        return start > now ? start : nil
    }
}

// MARK: - Occurrence arithmetic

extension ScheduledTask {
    /// How many receipts travel with a task. Enough to answer "has this been
    /// working?" without turning one record into a growing log.
    static let retainedRunCount = 20

    /// The longest a missed occurrence stays runnable. A Mac that was closed
    /// over the weekend should produce Monday morning's briefing when it opens,
    /// not three days of stale ones.
    static let catchUpWindow: TimeInterval = 12 * 60 * 60

    /// Bounds every day-walking search. A monthly task can legitimately need to
    /// look almost a month ahead; nothing valid needs more than a year.
    private static let searchDayLimit = 400

    var resolvedTimeZone: TimeZone {
        timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone
        return calendar
    }

    /// Whether an occurrence may land on `day` (a start-of-day date in the
    /// task's own time zone).
    private func matches(day: Date, calendar: Calendar) -> Bool {
        if let startDate, calendar.startOfDay(for: day) < calendar.startOfDay(for: startDate) {
            return false
        }
        switch cadence {
        case .once:
            let anchor = startDate ?? createdAt
            return calendar.isDate(day, inSameDayAs: anchor)
        case .daily:
            return true
        case .weekdays:
            let weekday = calendar.component(.weekday, from: day)
            return weekday >= 2 && weekday <= 6
        case .weekly:
            let target = self.weekday ?? calendar.component(.weekday, from: startDate ?? createdAt)
            return calendar.component(.weekday, from: day) == target
        case .monthly:
            let target = dayOfMonth ?? calendar.component(.day, from: startDate ?? createdAt)
            guard let range = calendar.range(of: .day, in: .month, for: day) else { return false }
            // A 31st-of-the-month task still runs in February, on the last day.
            let clamped = min(max(target, 1), range.count)
            return calendar.component(.day, from: day) == clamped
        }
    }

    private func occurrence(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            second: 0,
            of: day
        )
    }

    /// The next instant this task comes due strictly after `reference`.
    ///
    /// Walks candidate days rather than leaning on `Calendar` matching policies:
    /// month-length clamping and the weekday filter are both easier to state
    /// directly than to encode in `DateComponents`, and a task list is far too
    /// small for the loop to matter.
    func nextOccurrence(after reference: Date, now: Date = Date()) -> Date? {
        let calendar = calendar()
        var day = calendar.startOfDay(for: reference)
        for _ in 0...Self.searchDayLimit {
            if matches(day: day, calendar: calendar),
               let candidate = occurrence(on: day, calendar: calendar),
               candidate > reference {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// The most recent instant this task came due at or before `now`.
    func mostRecentOccurrence(onOrBefore now: Date) -> Date? {
        let calendar = calendar()
        var day = calendar.startOfDay(for: now)
        for _ in 0...Self.searchDayLimit {
            if matches(day: day, calendar: calendar),
               let candidate = occurrence(on: day, calendar: calendar),
               candidate <= now {
                return candidate
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = previous
        }
        return nil
    }

    /// The occurrence a client should claim right now, or nil when there is
    /// nothing to do.
    ///
    /// Three things can make a task runnable, in priority order: an explicit
    /// Run now, an occurrence that just came due, and an occurrence missed
    /// while every client was closed — the last only inside `catchUpWindow`.
    func dueOccurrence(now: Date = Date()) -> (occurrence: Date, isCatchUp: Bool)? {
        guard isEnabled else { return nil }
        if let runNowRequestedAt {
            // Run now is its own occurrence so it can never collide with, or be
            // swallowed by, the scheduled one.
            if lastOccurrenceAt.map({ runNowRequestedAt > $0 }) ?? true {
                return (runNowRequestedAt, false)
            }
        }
        guard let occurrence = mostRecentOccurrence(onOrBefore: now) else { return nil }
        // A slot that passed before the task existed was never missed: a
        // weekly task made on Sunday afternoon starts next Sunday, not with a
        // catch-up of that morning's run (nor a "was not open" receipt for it).
        if occurrence < createdAt { return nil }
        if let lastOccurrenceAt, occurrence <= lastOccurrenceAt { return nil }
        return (occurrence, now.timeIntervalSince(occurrence) > 60)
    }

    /// An occurrence too old to be worth running. The caller records a `skipped`
    /// receipt for it instead of generating stale work.
    func isStale(occurrence: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(occurrence) > Self.catchUpWindow
    }

    /// When this task is next expected to run, for display and for arming the
    /// scheduler's single timer.
    func upcomingOccurrence(now: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        if cadence == .once, let lastOccurrenceAt, lastOccurrenceAt >= (startDate ?? createdAt) {
            return nil
        }
        let floor = [lastOccurrenceAt, now].compactMap { $0 }.max() ?? now
        return nextOccurrence(after: floor, now: now)
    }

    /// One line describing when this runs, shared by both clients and MCP so
    /// the learner and their assistant read the schedule the same way.
    var scheduleSummary: String {
        let clock = String(format: "%02d:%02d", min(max(hour, 0), 23), min(max(minute, 0), 59))
        switch cadence {
        case .once:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.timeZone = resolvedTimeZone
            let day = formatter.string(from: startDate ?? createdAt)
            return "Once on \(day) at \(clock)"
        case .daily:
            return "Every day at \(clock)"
        case .weekdays:
            return "Weekdays at \(clock)"
        case .weekly:
            let calendar = calendar()
            let index = min(max((weekday ?? 2) - 1, 0), 6)
            let name = calendar.weekdaySymbols[index]
            return "Every \(name) at \(clock)"
        case .monthly:
            let day = min(max(dayOfMonth ?? 1, 1), 31)
            return "Monthly on day \(day) at \(clock)"
        }
    }

    /// Normalizes a draft into a task the runner can evaluate: clamped clock
    /// fields, and cadence-irrelevant components dropped so a weekly task can
    /// never carry a stale day-of-month from an earlier edit.
    func normalized(now: Date = Date()) -> ScheduledTask {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hour = min(max(hour, 0), 23)
        copy.minute = min(max(minute, 0), 59)
        copy.weekday = cadence.usesWeekday ? min(max(weekday ?? 2, 1), 7) : nil
        copy.dayOfMonth = cadence.usesDayOfMonth ? min(max(dayOfMonth ?? 1, 1), 31) : nil
        copy.sourceIDs = sourceIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if copy.timeZoneID?.isEmpty != false { copy.timeZoneID = TimeZone.current.identifier }
        if copy.cadence == .once, copy.startDate == nil { copy.startDate = now }
        return copy
    }
}

extension Notification.Name {
    /// A scheduled task was created, edited, or asked to run now from somewhere
    /// other than the runner — today that means the MCP plugin, which shares
    /// this process with the app. The runner re-reads and re-arms rather than
    /// waiting for the next activation.
    static let scheduledTasksDidChange = Notification.Name("ScheduledTasksDidChange")
}
