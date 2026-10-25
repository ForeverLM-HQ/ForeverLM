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

    @Test("Forced, the question stands until the calendar holds a plan: answering or closing it does not end it")
    func forced() {
        func open(answered: Bool, events: [AppleCalendarEvent] = [], enabled: Bool = true, forced: Bool) -> Bool {
            PlanTheDay.isOpen(
                events: events, calendarOn: true, nowMinute: 9 * 60, dayHours: 6...24,
                answeredToday: answered, isEnabled: enabled, forced: forced
            )
        }
        #expect(!open(answered: true, forced: false))
        #expect(open(answered: true, forced: true))
        #expect(open(answered: false, forced: true))
        // A plan still ends it, and so does switching the question off.
        #expect(!open(answered: true, events: [event(660, 750, "Read the atlas")], forced: true))
        #expect(!open(answered: false, enabled: false, forced: true))
    }

    @Test("A forced day opens the planning chat once, for someone at the Mac with ForeverLM in front")
    func opensChat() {
        func opens(
            isOpen: Bool = true, forced: Bool = true, openedToday: Bool = false,
            inFront: Bool = true, idle: TimeInterval = 5
        ) -> Bool {
            PlanTheDay.opensChatNow(
                isOpen: isOpen, forced: forced, openedToday: openedToday,
                appIsInFront: inFront, secondsSinceInput: idle
            )
        }
        #expect(opens())
        #expect(!opens(forced: false))
        #expect(!opens(isOpen: false))
        #expect(!opens(openedToday: true))
        #expect(!opens(inFront: false))
        #expect(!opens(idle: PlanTheDay.presenceSeconds))
    }

    @Test("The ledger keeps the day the forced chat opened apart from the day asked and the day answered")
    func chatLedger() throws {
        let suite = try #require(UserDefaults(suiteName: "PlanTheDayTests.\(UUID().uuidString)"))
        #expect(!PlanTheDay.Ledger.chatWasOpened(on: date, defaults: suite))
        PlanTheDay.Ledger.markChatOpened(on: date, defaults: suite)
        #expect(PlanTheDay.Ledger.chatWasOpened(on: date, defaults: suite))
        #expect(!PlanTheDay.Ledger.chatWasOpened(on: "2026-09-23", defaults: suite))
        #expect(!PlanTheDay.Ledger.wasAsked(on: date, defaults: suite) && !PlanTheDay.Ledger.wasAnswered(on: date, defaults: suite))
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

/// The strip's bell as the one inbox (docs/codex-shell-plan.md, Track 4): read
/// marks that survive a relaunch, a card read for what it says now kept out
/// of the corner, the notices only the bell holds, and the bell's dot.
@MainActor
@Suite("The bell: one inbox")
struct InboxReadMarkTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "InboxReadMarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("Read marks survive a relaunch; Mark as Unread takes one away for good")
    func marksSurviveRelaunch() throws {
        try withDefaults { defaults in
            let tray = CornerNoticeTray(defaults: defaults)
            tray.markRead(.shareRequests, subject: ["req-1"])
            tray.markRead(.planTheDay, subject: ["2026-10-13"])
            let relaunched = CornerNoticeTray(defaults: defaults)
            #expect(relaunched.isRead(.shareRequests, subject: ["req-1"]))
            #expect(relaunched.isRead(.planTheDay, subject: ["2026-10-13"]))
            #expect(!relaunched.isRead(.shareRequests, subject: ["req-1", "req-2"]), "a new request is news")
            relaunched.markUnread(.planTheDay)
            #expect(!CornerNoticeTray(defaults: defaults).isRead(.planTheDay, subject: ["2026-10-13"]))
            // A tray with no defaults keeps nothing past its run.
            let scratch = CornerNoticeTray()
            scratch.markRead(.cardsToCheck, subject: ["a"])
            #expect(CornerNoticeTray().read.isEmpty)
        }
    }

    @Test("A card read for what it says now stays out of the corner after a relaunch; news brings it back, and a tuck lasts one launch")
    func corner() throws {
        try withDefaults { defaults in
            let tray = CornerNoticeTray(defaults: defaults)
            #expect(tray.showsInCorner(.planTheDay, subject: ["2026-10-13"]))
            tray.markRead(.planTheDay, subject: ["2026-10-13"])
            #expect(!tray.showsInCorner(.planTheDay, subject: ["2026-10-13"]))
            let relaunched = CornerNoticeTray(defaults: defaults)
            #expect(!relaunched.showsInCorner(.planTheDay, subject: ["2026-10-13"]))
            #expect(relaunched.showsInCorner(.planTheDay, subject: ["2026-10-14"]), "a new day's plan is news")
            relaunched.tuck(.cardsToCheck)
            #expect(!relaunched.showsInCorner(.cardsToCheck, subject: ["a"]))
            #expect(CornerNoticeTray(defaults: defaults).showsInCorner(.cardsToCheck, subject: ["a"]))
        }
    }

    @Test("A mark is what the notice says now, so it never outgrows it")
    func markIsReplaced() {
        let tray = CornerNoticeTray()
        tray.markRead(.cardsToCheck, subject: ["a", "b"])
        tray.markRead(.cardsToCheck, subject: ["c"])
        #expect(tray.read[.cardsToCheck] == ["c"])
        #expect(!tray.isRead(.cardsToCheck, subject: ["a"]))
    }

    @Test("Cards to check, requests and plugins to reconnect are the bell's alone, each about its own ids")
    func bellOnlyKinds() {
        #expect(CornerNoticeKind.allCases.filter { !$0.isCornerCard } == [.cardsToCheck, .shareRequests, .pluginReconnect])
        let subjects = InboxSubjects(planDay: nil, cardsToCheck: nil, shareRequestIDs: ["req-1"], reconnectPlugins: ["x"])
        #expect(subjects.subject(.shareRequests) == ["req-1"])
        #expect(subjects.subject(.pluginReconnect) == ["x"])
    }

    @Test("The bell's dot: an unread chat, a notice only the bell holds, or a tucked card; never a card still in the corner")
    func dot() {
        let tray = CornerNoticeTray()
        #expect(!tray.lightsBell(unread: [], hasUnreadChats: false))
        #expect(tray.lightsBell(unread: [], hasUnreadChats: true))
        #expect(tray.lightsBell(unread: [.shareRequests], hasUnreadChats: false))
        #expect(!tray.lightsBell(unread: [.planTheDay], hasUnreadChats: false), "a card in the corner is in view already")
        #expect(tray.lightsBell(unread: [.cardsToCheck], hasUnreadChats: false), "cards to check never stand in the corner")
        tray.tuck(.planTheDay)
        #expect(tray.lightsBell(unread: [.planTheDay], hasUnreadChats: false))
    }
}
