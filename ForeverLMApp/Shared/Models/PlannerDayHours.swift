import Foundation

/// The hours of the day the Planner's clock draws: the learner's own window,
/// six in the morning to midnight unless they set it (product owner, 2026-09-20:
/// "between midnight and 6 a.m. we don't need to show in the app but I want
/// to be able to set that somewhere"). Two synced preferences — the day is
/// the learner's, so the window follows the account to the other Mac — read
/// by the clock, Settings › Chat › Day, and
/// `get_planner_settings` / `set_planner_settings`.
///
/// The window is where the clock *starts and stops drawing*, never a rule
/// about where a block may go: a block outside it, drawn from a chat or on
/// the other Mac, widens the clock to hold it (`DayPlanDetail.clockHourRange`).
enum PlannerDayHours {
    /// Listed in `SyncedPreferenceKeys.synced`.
    static let startKey = "planner.dayHours.start.v1"
    static let endKey = "planner.dayHours.end.v1"

    static let defaultStart = 6
    static let defaultEnd = 24

    /// The hours a day starts on: midnight up to eleven at night, so an end
    /// after it always exists.
    static let startHours = 0...23
    /// The hours a day ends on: one in the morning up to midnight (24).
    static let endHours = 1...24

    static var start: Int {
        get { clampStart(UserDefaults.standard.object(forKey: startKey) as? Int ?? defaultStart) }
        set { UserDefaults.standard.set(clampStart(newValue), forKey: startKey) }
    }

    static var end: Int {
        get { clampEnd(UserDefaults.standard.object(forKey: endKey) as? Int ?? defaultEnd) }
        set { UserDefaults.standard.set(clampEnd(newValue), forKey: endKey) }
    }

    /// The stored window with its two ends put in order: a start at or past
    /// the end (two Macs each moving one end, or a hand-edited plist) reads
    /// as the hour from the start, cut at midnight.
    static var window: ClosedRange<Int> { ordered(start: start, end: end) }

    static func clampStart(_ hour: Int) -> Int { min(max(hour, startHours.lowerBound), startHours.upperBound) }
    static func clampEnd(_ hour: Int) -> Int { min(max(hour, endHours.lowerBound), endHours.upperBound) }

    /// `start...end` with both clamped to their ranges and the end kept after
    /// the start.
    static func ordered(start: Int, end: Int) -> ClosedRange<Int> {
        let s = clampStart(start)
        let e = max(clampEnd(end), s + 1)
        return s...e
    }

    /// Why a setting cannot be taken, in the words the pane and the tool
    /// both use; nil when it can.
    static func validationMessage(start: Int?, end: Int?) -> String? {
        if let start, !startHours.contains(start) {
            return "day_start_hour is an hour of the day, 0 (midnight) to 23."
        }
        if let end, !endHours.contains(end) {
            return "day_end_hour is an hour of the day, 1 to 24 (midnight)."
        }
        let s = start ?? Self.start
        let e = end ?? Self.end
        if e <= s {
            return "The day must end after it starts: \(DayPlan.clockString(minute: e * 60)) is not after \(DayPlan.clockString(minute: s * 60))."
        }
        return nil
    }
}
