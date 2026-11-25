import Foundation

/// The preference keys behind "Have today's review ready", in a file both
/// targets compile. The Mac's `DailyReviewPreparation` and the phone's
/// scheduler read the same key; the Mac writes it through its preference
/// store, the phone through `MobileModelPreferenceStore`.
enum DailyReviewPreparationKeys {
    /// Synced across the account. Listed in `SyncedPreferenceKeys.synced`.
    static let enabled = "memoryReview.dailyPreparation.enabled.v1"
    static let defaultHour = 7
}

/// When a day's review should be prepared, and whether to do it now. Pure, so
/// the Mac's runner, the phone's scheduler, and the tests share one clock.
enum DailyReviewPreparationTiming {

    static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    /// `hour` o'clock, local, on the day `now` falls in.
    static func preparationInstant(onDayOf now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(bySettingHour: clampHour(hour), minute: 0, second: 0, of: start) ?? start
    }

    /// When a timer should next fire: today's hour while it is still ahead,
    /// otherwise tomorrow's.
    static func nextPreparationInstant(after now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        let today = preparationInstant(onDayOf: now, hour: hour, calendar: calendar)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return preparationInstant(onDayOf: tomorrow, hour: hour, calendar: calendar)
    }

    /// The local day, in the form the day's session id uses, so "attempted
    /// today" and "today's chat" agree on what today is.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        MemoryReviewSession.sessionID(for: date, calendar: calendar)
    }

    enum Decision: Equatable, Sendable {
        /// Do the work now.
        case prepare
        /// The switch is off.
        case disabled
        /// Today's hour has not come.
        case notYet
        /// Today's chat exists — made here, on another device, or by an earlier
        /// preparation — so there is nothing to prepare.
        case alreadyExists
        /// This device already tried today and did not produce a chat. One
        /// attempt a day keeps a failing model from being billed on every
        /// activation; "Prepare now" is the way past it.
        case alreadyAttempted
    }

    static func decide(
        now: Date,
        isEnabled: Bool,
        hour: Int,
        todaysSessionExists: Bool,
        lastAttemptDay: String?,
        calendar: Calendar = .current
    ) -> Decision {
        guard isEnabled else { return .disabled }
        if todaysSessionExists { return .alreadyExists }
        guard now >= preparationInstant(onDayOf: now, hour: hour, calendar: calendar) else { return .notYet }
        if lastAttemptDay == dayKey(for: now, calendar: calendar) { return .alreadyAttempted }
        return .prepare
    }

    /// "7:00 AM" or "07:00", in the learner's own clock convention. The minutes
    /// are always zero, but they stay: the bare hour template renders "07" on a
    /// 24-hour clock, which reads as a code rather than a time of day.
    static func hourLabel(_ hour: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        let date = preparationInstant(onDayOf: Date(), hour: hour, calendar: calendar)
        return formatter.string(from: date)
    }
}

// MARK: - The morning's pick
//
// docs/morning-routine-design.md, "What gets surfaced": one source to
// explain each morning, chosen by query over records the app already keeps,
// never by a model. The first rule with a candidate wins; the rest are the
// queue Pick something else walks.

struct MorningPick: Equatable, Sendable {
    enum Reason: String, Sendable {
        /// Taken in since yesterday, never explained.
        case yesterday
        /// Its cards are due, and it was never explained.
        case keptNotExplained
        /// Explained once, its cards now overdue.
        case explainedDry
        /// The weekly connection: yesterday's source and an older one
        /// already explained, to be tied together.
        case connection
    }

    /// One source, or two for a connection (yesterday's first).
    let sourceIDs: [String]
    let reason: Reason
}

enum MorningPickRule {
    /// The least score of an explanation's exchange that counts as explained:
    /// held is 1, partial 0.5 (the Mac's `TeachBack.Verdict`, the voice
    /// tutor's had_it and partly).
    static let explainedScore = 0.75

    /// The `grading` an explanation's exchange carries (operation explain,
    /// or connect for two sources; verdict sound; no idea coverage), as the
    /// Mac writes it and the phone's voice explanation sends it.
    static func explanationGrading(sourceCount: Int) -> (operation: String, verdict: String) {
        (sourceCount > 1 ? "connect" : "explain", "sound")
    }

    /// Whether an exchange's grading marks an explanation the pick reads.
    static func isExplanation(operation: String?, verdict: String?, hasIdeaCoverage: Bool) -> Bool {
        (operation == "explain" || operation == "connect") && verdict == "sound" && !hasIdeaCoverage
    }

    /// A source of today's due cards: how many whole days its most overdue
    /// card is past due (0 = due today).
    struct DueSource: Equatable, Sendable {
        let sourceID: String
        let daysOverdue: Int
    }

    struct Inputs: Equatable, Sendable {
        /// Taken in to at least `substantial` since yesterday's start, most
        /// engaged first.
        var recent: [String] = []
        /// Sources of today's due (not new) cards.
        var due: [DueSource] = []
        /// When each source was last explained so that it held.
        var explainedAt: [String: Date] = [:]
        /// Skipped with Pick something else, not to be picked yet.
        var skipped: Set<String> = []
        /// The weekly connection's older half for `recent`'s first unexplained
        /// source, when this is the connection morning and one was found.
        var connectionPartner: String? = nil
    }

    /// Every candidate, best first, each source at most once as a single pick.
    static func queue(_ inputs: Inputs) -> [MorningPick] {
        var picks: [MorningPick] = []
        var used = Set<String>()
        func add(_ sourceID: String, _ reason: MorningPick.Reason) {
            guard !inputs.skipped.contains(sourceID), used.insert(sourceID).inserted else { return }
            picks.append(MorningPick(sourceIDs: [sourceID], reason: reason))
        }
        let yesterday = inputs.recent.filter { inputs.explainedAt[$0] == nil && !inputs.skipped.contains($0) }
        if let first = yesterday.first, let partner = inputs.connectionPartner,
           partner != first, inputs.explainedAt[partner] != nil, !inputs.skipped.contains(partner) {
            picks.append(MorningPick(sourceIDs: [first, partner], reason: .connection))
        }
        yesterday.forEach { add($0, .yesterday) }
        let driest = inputs.due.sorted {
            $0.daysOverdue != $1.daysOverdue ? $0.daysOverdue > $1.daysOverdue : $0.sourceID < $1.sourceID
        }
        driest.filter { inputs.explainedAt[$0.sourceID] == nil }.forEach { add($0.sourceID, .keptNotExplained) }
        driest.filter { inputs.explainedAt[$0.sourceID] != nil && $0.daysOverdue >= 1 }.forEach { add($0.sourceID, .explainedDry) }
        return picks
    }

    /// The weekly connection's morning: the first morning of the learner's
    /// week by the calendar.
    static func isConnectionMorning(_ now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: now) == calendar.firstWeekday
    }

    /// Whether a source explained at `at` counts for today's morning.
    static func explainedToday(_ explainedAt: [String: Date], now: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: now)
        return explainedAt.values.contains { $0 >= start }
    }
}
