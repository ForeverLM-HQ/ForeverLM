import Foundation

/// "Plan your day?" — asked each morning the day has no plan yet (product owner,
/// 2026-09-22: "if there isn't really a plan for the day yet, then maybe it
/// should show a notification … hey, you want to plan your day?"; 2026-09-27:
/// "in the morning; if there is not yet a plan for the day, please encourage
/// the user to make a plan with a popup notification … it's ok if you don't
/// fully stick to it; but the act of making a plan is helpful!").
///
/// The day is the Mac's Calendar, and planning it is a chat that writes events
/// into it (2026-09-30), so the question is whether today's calendar holds
/// anything the learner planned. The question is a card at the bottom left of
/// every Studio window, in the navigation rail's footer over the Now chip
/// (`PlanTheDayCard`), that waits there until it is answered, and a
/// notification only when ForeverLM is not the app in front
/// (`PlanTheDayNotifications`). The rule is pure: given the day's events and
/// the clock it says whether the question stands. `DayModel` asks it on every
/// tick of its clock.
enum PlanTheDay {
    /// Settings › General › Day. On until the learner switches it off,
    /// from the pane, from the card's or the notification's Don't Ask Again,
    /// or over MCP. Device-local, like the reading review: the question is
    /// asked on this Mac.
    static let settingKey = "planner.suggestPlanningTheDay"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: settingKey)
    }

    /// The learner has touched the Mac this recently: the notification is for
    /// someone sitting down to the day, not a banner left on a screen nobody
    /// is at since six in the morning. The card needs no one there; it waits.
    static let presenceSeconds: TimeInterval = 120
    /// With less of the day left than this, a plan is no longer what helps.
    static let minimumMinutesLeft = 120

    /// Whether the day holds anything the learner planned: a timed event
    /// that is theirs alone and happens once. A meeting with other people is
    /// someone else's plan too, and a recurring event is the routine the day
    /// is planned around, so a day holding only those has not been planned.
    static func isPlanned(_ events: [AppleCalendarEvent]) -> Bool {
        events.contains { $0.holdsTime && !$0.hasOtherPeople && $0.occurrenceDate == nil }
    }

    /// The minute the morning ends: the hour `/plan` stops planning today and
    /// plans tomorrow instead (`DayPlan.planTomorrowFromHour`), or earlier when
    /// the learner's day ends so soon that the last `minimumMinutesLeft` would
    /// fall inside it. A day that starts after this has no morning, and is
    /// not asked about.
    static func morningEndMinute(dayHours: ClosedRange<Int>) -> Int {
        min(DayPlan.planTomorrowFromHour * 60, dayHours.upperBound * 60 - minimumMinutesLeft)
    }

    /// Whether `nowMinute` is in the morning of the learner's day: from the
    /// hour their day starts (Settings › General › Day) until
    /// `morningEndMinute`.
    static func isMorning(nowMinute: Int, dayHours: ClosedRange<Int>) -> Bool {
        nowMinute >= dayHours.lowerBound * 60 && nowMinute < morningEndMinute(dayHours: dayHours)
    }

    /// Whether the question stands — what the card shows while it holds:
    /// switched on, the calendar on (the plan has nowhere to go without it),
    /// not answered today on this Mac, in the morning, and nothing on today's
    /// calendar the learner planned. An event added by any route answers it,
    /// on this Mac or the other one.
    static func isOpen(
        events: [AppleCalendarEvent],
        calendarOn: Bool,
        nowMinute: Int,
        dayHours: ClosedRange<Int>,
        answeredToday: Bool,
        isEnabled: Bool = PlanTheDay.isEnabled
    ) -> Bool {
        guard isEnabled, calendarOn, !answeredToday else { return false }
        guard isMorning(nowMinute: nowMinute, dayHours: dayHours) else { return false }
        return !isPlanned(events)
    }

    /// Whether this tick puts the question to the learner: the first tick of
    /// the day they are at the Mac while it stands. With ForeverLM in front
    /// the card already is the question; otherwise a notification says it,
    /// once, and the card is waiting when they come to the app.
    static func isPutNow(isOpen: Bool, askedToday: Bool, secondsSinceInput: TimeInterval) -> Bool {
        isOpen && !askedToday && secondsSinceInput < presenceSeconds
    }

    static let title = "Plan your day?"

    /// The line under the title, on the card and in the notification. The
    /// point is the planning, not the keeping to it (product owner, 2026-09-27).
    static let detail = "You don't have to stick to the plan. Making it is what helps."

    /// What this Mac has done with the question, by day. Two dates, since a
    /// question put is not a question answered: the card stays up after the
    /// notification went out, or after the learner saw it with the app in
    /// front, until they answer or close it.
    enum Ledger {
        /// The day the question was put to the learner: seen with ForeverLM
        /// in front, or said as a notification. At most one notification a day.
        static let key = "planner.planTheDay.askedOn"
        /// The day the learner answered: planned from the card or the
        /// notification, or closed the card for the day.
        static let answeredKey = "planner.planTheDay.answeredOn"

        static func wasAsked(on date: String, defaults: UserDefaults = .standard) -> Bool {
            defaults.string(forKey: key) == date
        }

        static func markAsked(on date: String, defaults: UserDefaults = .standard) {
            defaults.set(date, forKey: key)
        }

        static func wasAnswered(on date: String, defaults: UserDefaults = .standard) -> Bool {
            defaults.string(forKey: answeredKey) == date
        }

        static func markAnswered(on date: String, defaults: UserDefaults = .standard) {
            defaults.set(date, forKey: answeredKey)
        }
    }
}

extension DayPlan {
    /// From this hour, "plan my day" means tomorrow, and the morning's "Plan
    /// your day?" stops asking about today (`PlanTheDay.morningEndMinute`).
    /// By the afternoon today is half spent, and a day planned the evening
    /// before is the one that starts well.
    static let planTomorrowFromHour = 14
}
