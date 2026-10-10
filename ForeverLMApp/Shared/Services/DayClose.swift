import Foundation

/// The hour the day is closed on this Mac, and whether to close it now.
///
/// The day close has a switch of its own, "Close the day each evening"
/// (synced: what it spends is the account's), and a device-local hour,
/// because the hour a day ends is a property of this machine's evenings.
/// Until 2026-10-01 it ran behind "Have today's review ready"
/// (`DailyReviewPreparation`), when the morning's preparation was a paid
/// planner call and the two were one spending decision; the morning calls no
/// model since the card review, and turning it off must not stop the evening's
/// drafting and consolidation. A learner who never touched the new switch
/// keeps what the old one said. What runs is `DayClosePass` — the day's
/// chats and reading folded into what the tutor knows, cards drafted from
/// what was finished, cards reworded — then the next morning's cards are
/// counted. (docs/memory-design.md, "The day close".)
enum DayClosePreferences {
    /// Synced. Listed in `SyncedPreferenceKeys.synced`.
    static let enabledKey = "memoryReview.dayClose.enabled.v1"
    /// Device-local. Listed in `SyncedPreferenceKeys.excluded` with its reason.
    static let hourKey = "memoryReview.dayClose.hour.v1"
    /// Late enough that the day's reading is usually over, early enough that
    /// a Mac still open at it is the common case.
    static let defaultHour = 22
    /// Device-local receipt of what this Mac last did about closing the day.
    static let lastRunKey = "memoryReview.dayClose.lastRun.v1"

    static var hour: Int {
        get { DailyReviewPreparationTiming.clampHour(UserDefaults.standard.object(forKey: hourKey) as? Int ?? defaultHour) }
        set { UserDefaults.standard.set(DailyReviewPreparationTiming.clampHour(newValue), forKey: hourKey) }
    }

    /// Whether the day closes itself at the hour. A learner who never set
    /// this switch keeps the one it was behind until it had its own:
    /// "Have today's review ready".
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let stored = defaults.object(forKey: enabledKey) as? NSNumber { return stored.boolValue }
        return defaults.bool(forKey: DailyReviewPreparation.enabledKey)
    }

    static var isEnabled: Bool { isEnabled(defaults: .standard) }

    static func setEnabled(_ enabled: Bool) {
        PreferenceStore.set(enabled, forKey: enabledKey)
    }

    /// What to pin this switch to just before "Have today's review ready"
    /// changes, or nil once it has a value of its own. Until then it follows
    /// that switch, so changing the reminder would also start or stop the
    /// evening's paid close; pinning it to what it does now (`reminderWas`,
    /// the reminder's value before the change) keeps the update's promise
    /// and parts the two from then on.
    static func valueToPin(reminderWas: Bool, defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: enabledKey) == nil ? reminderWas : nil
    }

    /// Pins the switch, as `valueToPin` says, before the reminder changes.
    static func pinBeforeReminderChange(reminderWas: Bool) {
        if let value = valueToPin(reminderWas: reminderWas) { setEnabled(value) }
    }
}

/// When the day should be closed, and whether to do it now. Pure, like
/// `DailyReviewPreparationTiming`, so the runner and the tests share one clock.
enum DayCloseTiming {
    enum Decision: Equatable, Sendable {
        /// Do the work now.
        case run
        /// The switch is off; only an explicit close (the shutdown, "Close the
        /// day now", `close_day`) runs.
        case disabled
        /// Today's hour has not come.
        case notYet
        /// This device already closed today, at the hour or by hand.
        case alreadyRan
    }

    /// `hour` o'clock today, by the local calendar.
    static func closeInstant(onDayOf now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        DailyReviewPreparationTiming.preparationInstant(onDayOf: now, hour: hour, calendar: calendar)
    }

    /// When a timer should next fire: today's hour while it is ahead,
    /// otherwise tomorrow's.
    static func nextCloseInstant(after now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        DailyReviewPreparationTiming.nextPreparationInstant(after: now, hour: hour, calendar: calendar)
    }

    static func decide(
        now: Date,
        isEnabled: Bool,
        hour: Int,
        lastRunDay: String?,
        calendar: Calendar = .current
    ) -> Decision {
        guard isEnabled else { return .disabled }
        if lastRunDay == DailyReviewPreparationTiming.dayKey(for: now, calendar: calendar) { return .alreadyRan }
        guard now >= closeInstant(onDayOf: now, hour: hour, calendar: calendar) else { return .notYet }
        return .run
    }

    /// The window a first close covers when no earlier close left a
    /// watermark: from the start of yesterday, the same stretch the ledger
    /// and the guaranteed pass read.
    static func firstWatermark(now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
    }
}
