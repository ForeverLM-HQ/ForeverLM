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
    /// Settings › Chat › Day. On until the learner switches it off,
    /// from the pane, from the card's or the notification's Don't Ask Again,
    /// or over MCP. Device-local, like the reading review: the question is
    /// asked on this Mac.
    static let settingKey = Prefs.Planner.suggestPlanningTheDay.name

    static var isEnabled: Bool {
        Preferences.value(Prefs.Planner.suggestPlanningTheDay)
    }

    static func setEnabled(_ enabled: Bool) {
        Preferences.set(enabled, for: Prefs.Planner.suggestPlanningTheDay)
    }

    /// Settings › Chat › Day, under the switch above: Make Me Plan. Off
    /// until the learner turns it on (product owner, 2026-10-15: "give me the
    /// option to FORCE myself to plan my day if it hasn't been planned yet …
    /// now it's just a notification nudge"). While the day is unplanned the
    /// card cannot be closed or switched off from itself, the planning chat
    /// opens by itself the first time the learner is at the Mac in the
    /// morning, and the question stands until the calendar holds a plan: only
    /// planning, or this switch, lifts it. It needs the question asked at all,
    /// so it does nothing while `isEnabled` is off.
    static let forcedKey = Prefs.Planner.forcePlanningTheDay.name

    static var isForced: Bool {
        isEnabled && Preferences.value(Prefs.Planner.forcePlanningTheDay)
    }

    static func setForced(_ forced: Bool) {
        Preferences.set(forced, for: Prefs.Planner.forcePlanningTheDay)
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
    /// hour their day starts (Settings › Chat › Day) until
    /// `morningEndMinute`.
    static func isMorning(nowMinute: Int, dayHours: ClosedRange<Int>) -> Bool {
        nowMinute >= dayHours.lowerBound * 60 && nowMinute < morningEndMinute(dayHours: dayHours)
    }

    /// Whether the question stands — what the card shows while it holds:
    /// switched on, the calendar on (the plan has nowhere to go without it),
    /// not answered today on this Mac, in the morning, and nothing on today's
    /// calendar the learner planned. An event added by any route answers it,
    /// on this Mac or the other one. Forced (`isForced`), only that answers it:
    /// closing the card, or opening the chat and leaving it, does not.
    static func isOpen(
        events: [AppleCalendarEvent],
        calendarOn: Bool,
        nowMinute: Int,
        dayHours: ClosedRange<Int>,
        answeredToday: Bool,
        isEnabled: Bool = PlanTheDay.isEnabled,
        forced: Bool = PlanTheDay.isForced
    ) -> Bool {
        guard isEnabled, calendarOn, forced || !answeredToday else { return false }
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

    /// Whether this tick opens the planning chat itself, for a forced day: the
    /// first tick of the day the learner is at the Mac with ForeverLM in front
    /// while the question stands. Once a day, so a learner who leaves the chat
    /// is not thrown back into a new one; the card stays until the day is planned.
    static func opensChatNow(
        isOpen: Bool,
        forced: Bool,
        openedToday: Bool,
        appIsInFront: Bool,
        secondsSinceInput: TimeInterval
    ) -> Bool {
        forced && isOpen && !openedToday && appIsInFront && secondsSinceInput < presenceSeconds
    }

    static let title = "Plan your day?"

    /// The title once the learner has asked to be made to plan.
    static let forcedTitle = "Plan your day"

    /// The line under the title, on the card and in the notification. The
    /// point is the planning, not the keeping to it (product owner, 2026-09-27).
    static let detail = "Making a time-block plan is very helpful. Don't worry if you can't stick to it perfectly. The plan is flexible."

    /// What this Mac has done with the question, by day. Two dates, since a
    /// question put is not a question answered: the card stays up after the
    /// notification went out, or after the learner saw it with the app in
    /// front, until they answer or close it.
    enum Ledger {
        /// The day a forced question opened the planning chat by itself.
        static func chatWasOpened(on date: String, defaults: UserDefaults = .standard) -> Bool {
            defaults.string(forKey: Prefs.Planner.planTheDayChatOpenedOn.name) == date
        }

        static func markChatOpened(on date: String, defaults: UserDefaults = .standard) {
            defaults.set(date, forKey: Prefs.Planner.planTheDayChatOpenedOn.name)
        }

        /// The day the question was put to the learner: seen with ForeverLM
        /// in front, or said as a notification. At most one notification a day.
        static func wasAsked(on date: String, defaults: UserDefaults = .standard) -> Bool {
            defaults.string(forKey: Prefs.Planner.planTheDayAskedOn.name) == date
        }

        static func markAsked(on date: String, defaults: UserDefaults = .standard) {
            defaults.set(date, forKey: Prefs.Planner.planTheDayAskedOn.name)
        }

        /// The day the learner answered: planned from the card or the
        /// notification, or closed the card for the day.
        static func wasAnswered(on date: String, defaults: UserDefaults = .standard) -> Bool {
            defaults.string(forKey: Prefs.Planner.planTheDayAnsweredOn.name) == date
        }

        static func markAnswered(on date: String, defaults: UserDefaults = .standard) {
            defaults.set(date, forKey: Prefs.Planner.planTheDayAnsweredOn.name)
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
