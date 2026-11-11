import Foundation

/// The one switch behind "today's review is ready when I open the app".
///
/// Off by default. When on, an open Mac does at the chosen hour exactly what the
/// Memory row does live — assemble the day's cohort, extract any missing
/// ideas, call the planner once, and create today's memory chat with its
/// opening question — so the click that follows resumes a chat that already
/// exists instead of waiting half a minute for one to be planned. The same
/// switch owns the one daily notification (`CohortReviewNotifications`):
/// "ready" and "told it is ready" are one decision, not two.
///
/// The opt-in follows the account, because it is a spending decision: one
/// planner call and one opening message a day, billed whether or not the review
/// is opened. The hour stays on the device, because the hour a review should be
/// waiting is a property of that machine's mornings, not of the account.
/// (docs/memory-design.md, "Daily preparation".)
enum DailyReviewPreparation {
    /// Synced. Listed in `SyncedPreferenceKeys.synced`; the phone reads the
    /// same key through `DailyReviewPreparationKeys`.
    static let enabledKey = Prefs.Memory.dailyPreparationEnabled.name
    /// Device-local. Listed in `SyncedPreferenceKeys.excluded` with its reason.
    static let hourKey = Prefs.Memory.dailyPreparationHour.name
    static let maxOfferShowings = 3

    static let defaultHour = DailyReviewPreparationKeys.defaultHour

    /// How long a live planning wait runs before the chat offers to move it to
    /// the morning. Long enough that the wait is felt; short enough that most
    /// planning calls are still running when the offer appears.
    static let offerDelay: TimeInterval = 4

    // MARK: - Settings

    static var isEnabled: Bool {
        Preferences.value(Prefs.Memory.dailyPreparationEnabled)
    }

    static func setEnabled(_ enabled: Bool) {
        Preferences.set(enabled, for: Prefs.Memory.dailyPreparationEnabled)
    }

    static var hour: Int {
        get { clampHour(Preferences.value(Prefs.Memory.dailyPreparationHour) ?? defaultHour) }
        set { Preferences.set(clampHour(newValue), for: Prefs.Memory.dailyPreparationHour) }
    }

    static func clampHour(_ hour: Int) -> Int {
        DailyReviewPreparationTiming.clampHour(hour)
    }

    /// Device-local. Set once the learner has taken the in-chat offer or
    /// touched the Settings switch; the offer is then never made again.
    static var offerDecided: Bool {
        Preferences.value(Prefs.Memory.dailyPreparationOfferDecided) ?? false
    }

    static func markOfferDecided() {
        Preferences.set(true, for: Prefs.Memory.dailyPreparationOfferDecided)
    }

    /// Device-local. How many planning waits have shown the offer. The offer
    /// has no "no" button — a wait is not the place to demand an answer — so
    /// being shown `maxOfferShowings` times without being taken is the answer.
    static var offerShownCount: Int {
        Preferences.value(Prefs.Memory.dailyPreparationOfferShownCount) ?? 0
    }

    /// Called once per planning wait that actually showed the offer.
    static func recordOfferShown() {
        Preferences.set(offerShownCount + 1, for: Prefs.Memory.dailyPreparationOfferShownCount)
    }

    /// Whether the chat should offer preparation while a review is being
    /// planned live: only to someone who has neither turned it on, nor decided
    /// in Settings, nor already let the offer pass a few times.
    static var shouldOffer: Bool {
        offerStands(isEnabled: isEnabled, decided: offerDecided, shownCount: offerShownCount)
    }

    static func offerStands(isEnabled: Bool, decided: Bool, shownCount: Int) -> Bool {
        !isEnabled && !decided && shownCount < maxOfferShowings
    }

    // MARK: - Timing

    /// The clock lives in `DailyReviewPreparationTiming`, which the phone
    /// compiles too. These forward so Mac call sites read as before.
    typealias Decision = DailyReviewPreparationTiming.Decision

    static func preparationInstant(onDayOf now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        DailyReviewPreparationTiming.preparationInstant(onDayOf: now, hour: hour, calendar: calendar)
    }

    static func nextPreparationInstant(after now: Date, hour: Int, calendar: Calendar = .current) -> Date {
        DailyReviewPreparationTiming.nextPreparationInstant(after: now, hour: hour, calendar: calendar)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        DailyReviewPreparationTiming.dayKey(for: date, calendar: calendar)
    }

    static func decide(
        now: Date,
        isEnabled: Bool,
        hour: Int,
        todaysSessionExists: Bool,
        lastAttemptDay: String?,
        calendar: Calendar = .current
    ) -> Decision {
        DailyReviewPreparationTiming.decide(
            now: now, isEnabled: isEnabled, hour: hour,
            todaysSessionExists: todaysSessionExists, lastAttemptDay: lastAttemptDay, calendar: calendar
        )
    }

    static func hourLabel(_ hour: Int, calendar: Calendar = .current, locale: Locale = .current) -> String {
        DailyReviewPreparationTiming.hourLabel(hour, calendar: calendar, locale: locale)
    }
}

// MARK: - The daily time budget on the Mac

extension MemoryReviewBudget {
    /// The learner's daily budget as this Mac knows it: the synced row's local
    /// mirror in `UserDefaults`, the default when nothing was ever set.
    static var minutes: Int {
        guard let stored = Preferences.value(Prefs.Memory.budgetMinutes) else {
            return defaultMinutes
        }
        return clamp(stored)
    }

    /// Written through `PreferenceStore`, so the other Mac and the phone see
    /// the same number.
    static func setMinutes(_ minutes: Int) {
        Preferences.set(clamp(minutes), for: Prefs.Memory.budgetMinutes)
    }
}
