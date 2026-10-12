import Foundation
import Testing
@testable import ForeverLM

/// "Plan your day?" (`PlanTheDay`, planner-design.md): what counts as a
/// planned day on the Mac's Calendar, when the card stands, and when the
/// question is put.
@Suite("Plan the day")
struct PlanTheDayTests {
    private let date = "2026-09-22"

    private func at(_ minute: Int) -> Date {
        Calendar.current.startOfDay(for: DayPlan.startOfDay(date)!).addingTimeInterval(TimeInterval(minute * 60))
    }

    private func event(
        _ start: Int, _ end: Int, _ title: String,
        others: Bool = false, recurring: Bool = false, allDay: Bool = false, free: Bool = false
    ) -> AppleCalendarEvent {
        AppleCalendarEvent(
            calendarID: "CAL", eventIdentifier: title, occurrenceDate: recurring ? at(start) : nil,
            title: title, start: at(start), end: at(end), isAllDay: allDay, isDeclined: false,
            isFree: free, isCancelled: false, isBirthday: false, location: nil, url: nil,
            hasOtherPeople: others
        )
    }

    @Test("Meetings with other people and the routine are the day's shape; a one-off event of the learner's own is a plan")
    func planned() {
        #expect(!PlanTheDay.isPlanned([]))
        #expect(!PlanTheDay.isPlanned([
            event(600, 630, "Standup", others: true),
            event(720, 780, "Lunch", recurring: true),
            event(0, 1440, "Holiday", allDay: true),
            event(900, 960, "Maybe", free: true),
        ]))
        #expect(PlanTheDay.isPlanned([
            event(600, 630, "Standup", others: true),
            event(660, 750, "Read the atlas"),
        ]))
    }

    @Test("The morning runs from the start of the learner's day to the hour /plan turns to tomorrow")
    func morning() {
        let turn = DayPlan.planTomorrowFromHour * 60
        #expect(PlanTheDay.morningEndMinute(dayHours: 6...24) == turn)
        #expect(!PlanTheDay.isMorning(nowMinute: 5 * 60 + 59, dayHours: 6...24))
        #expect(PlanTheDay.isMorning(nowMinute: 6 * 60, dayHours: 6...24))
        #expect(PlanTheDay.isMorning(nowMinute: turn - 1, dayHours: 6...24))
        #expect(!PlanTheDay.isMorning(nowMinute: turn, dayHours: 6...24))
        // The learner's own start moves the morning's beginning, not its end.
        #expect(!PlanTheDay.isMorning(nowMinute: 8 * 60, dayHours: 9...19))
        #expect(PlanTheDay.isMorning(nowMinute: 9 * 60, dayHours: 9...19))
        #expect(PlanTheDay.morningEndMinute(dayHours: 9...19) == turn)
        // A day that ends early keeps its last two hours out of the morning.
        #expect(PlanTheDay.morningEndMinute(dayHours: 6...15) == 13 * 60)
        #expect(!PlanTheDay.isMorning(nowMinute: 13 * 60, dayHours: 6...15))
        // A day that starts after the turn has no morning to ask in.
        #expect(!PlanTheDay.isMorning(nowMinute: 15 * 60, dayHours: 15...24))
    }

    @Test("The card stands in the morning of an unplanned day until it is answered, and only while the calendar is on")
    func open() {
        func open(
            now: Int,
            events: [AppleCalendarEvent] = [],
            hours: ClosedRange<Int> = 6...24,
            answered: Bool = false,
            calendarOn: Bool = true,
            enabled: Bool = true
        ) -> Bool {
            PlanTheDay.isOpen(
                events: events,
                calendarOn: calendarOn,
                nowMinute: now,
                dayHours: hours,
                answeredToday: answered,
                isEnabled: enabled
            )
        }
        #expect(open(now: 9 * 60))
        #expect(open(now: 9 * 60, events: [event(600, 630, "Standup", others: true)]))
        // Only in the morning.
        #expect(!open(now: 5 * 60 + 59))
        #expect(open(now: 6 * 60))
        #expect(!open(now: DayPlan.planTomorrowFromHour * 60))
        #expect(!open(now: 18 * 60, hours: 8...19))
        // Until answered, only while switched on, and only with somewhere to
        // write the plan.
        #expect(!open(now: 9 * 60, answered: true))
        #expect(!open(now: 9 * 60, enabled: false))
        #expect(!open(now: 9 * 60, calendarOn: false))
        // A plan is the answer: a planned day is not asked about.
        #expect(!open(now: 9 * 60, events: [event(660, 750, "Read the atlas")]))
    }

    @Test("The question is put once, to someone at the Mac, while it stands")
    func put() {
        #expect(PlanTheDay.isPutNow(isOpen: true, askedToday: false, secondsSinceInput: 5))
        #expect(!PlanTheDay.isPutNow(isOpen: false, askedToday: false, secondsSinceInput: 5))
        #expect(!PlanTheDay.isPutNow(isOpen: true, askedToday: true, secondsSinceInput: 5))
        #expect(!PlanTheDay.isPutNow(isOpen: true, askedToday: false, secondsSinceInput: PlanTheDay.presenceSeconds))
    }

    @Test("Each ledger answers for its own day, and asking is not answering")
    func ledger() throws {
        let defaults = try #require(UserDefaults(suiteName: "PlanTheDayTests.\(UUID().uuidString)"))
        #expect(!PlanTheDay.Ledger.wasAsked(on: date, defaults: defaults))
        #expect(!PlanTheDay.Ledger.wasAnswered(on: date, defaults: defaults))
        PlanTheDay.Ledger.markAsked(on: date, defaults: defaults)
        #expect(PlanTheDay.Ledger.wasAsked(on: date, defaults: defaults))
        #expect(!PlanTheDay.Ledger.wasAsked(on: "2026-09-23", defaults: defaults))
        // The card stays up after the question was put, until answered.
        #expect(!PlanTheDay.Ledger.wasAnswered(on: date, defaults: defaults))
        PlanTheDay.Ledger.markAnswered(on: date, defaults: defaults)
        #expect(PlanTheDay.Ledger.wasAnswered(on: date, defaults: defaults))
        #expect(!PlanTheDay.Ledger.wasAnswered(on: "2026-09-23", defaults: defaults))
    }

    @Test("The words say the planning is what helps, not keeping to it")
    func words() {
        #expect(PlanTheDay.title == "Plan your day?")
        #expect(PlanTheDay.detail == "Making a time-block plan is very helpful. Don't worry if you can't stick to it perfectly. The plan is flexible.")
    }
}

/// The notifications center's read marks (`CornerNoticeTray`), for "Plan
/// your day?" and its sibling corner cards: a mark holds while the card says
/// nothing new, and read is seen, so the card leaves the corner too.
@MainActor
@Suite("Notification read marks")
struct CornerNoticeReadMarkTests {
    @Test("A card marked read stays read until it is about something new")
    func readHoldsUntilNews() {
        let tray = CornerNoticeTray()
        let today: Set<String> = ["a", "b", "day:2026-10-10"]
        #expect(!tray.isRead(.cardsToCheck, subject: today))
        tray.markRead(.cardsToCheck, subject: today)
        #expect(tray.isRead(.cardsToCheck, subject: today))
        // A pile that shrinks is not news; a new source or a new day is.
        #expect(tray.isRead(.cardsToCheck, subject: ["a", "day:2026-10-10"]))
        #expect(!tray.isRead(.cardsToCheck, subject: ["a", "b", "c", "day:2026-10-10"]))
        #expect(!tray.isRead(.cardsToCheck, subject: ["a", "b", "day:2026-10-11"]))
        // Each kind is marked on its own.
        #expect(!tray.isRead(.planTheDay, subject: ["2026-10-10"]))
    }

    @Test("Marking read takes the card out of the corner, and marking unread leaves it out")
    func readTucks() {
        let tray = CornerNoticeTray()
        tray.markRead(.planTheDay, subject: ["2026-10-10"])
        #expect(tray.isTucked(.planTheDay))
        #expect(!tray.isTucked(.cardsToCheck))
        tray.markUnread(.planTheDay)
        #expect(!tray.isRead(.planTheDay, subject: ["2026-10-10"]))
        #expect(tray.isTucked(.planTheDay))
    }

    @Test("A day's plan is about its day, and the cards pile about its sources and today")
    func subjects() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pile = CardsToCheckNudge.Pile(cardCount: 74, sourceIDs: ["a", "b"])
        #expect(CornerNoticeKind.planTheDay.subject(planDay: "2026-10-10", cardsToCheck: pile) == ["2026-10-10"])
        #expect(
            CornerNoticeKind.cardsToCheck.subject(planDay: nil, cardsToCheck: pile, now: now)
                == ["a", "b", "day:" + MemoryReviewGoal.dayKey(for: now)]
        )
    }
}
