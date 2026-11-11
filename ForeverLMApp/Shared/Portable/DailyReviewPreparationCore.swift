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
