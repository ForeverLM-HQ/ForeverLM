import Foundation
import Testing
@testable import ForeverLM

/// The Now chip's reading of the clock against today's Mac Calendar: which
/// state the day is in, what the chip says about it (nothing, in a quiet
/// hour), and the popover's schedule. See docs/planner-design.md, "The day is the Mac's Calendar".
@Suite("Day now")
struct DayNowTests {

    /// The Mac's own calendar: the chip says times on the learner's clock.
    private static let calendar = Calendar.current

    /// 2026-09-18 at `minute` past midnight on this Mac's clock.
    private func at(_ minute: Int) -> Date {
        let midnight = Self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 18))!
        return midnight.addingTimeInterval(TimeInterval(minute * 60))
    }

    private func event(
        _ start: Int, _ end: Int, _ title: String = "Work",
        allDay: Bool = false, declined: Bool = false, free: Bool = false, cancelled: Bool = false,
        others: Bool = false, url: String? = nil, notes: String? = nil
    ) -> AppleCalendarEvent {
        AppleCalendarEvent(
            calendarID: "CAL", eventIdentifier: "\(title)-\(start)", occurrenceDate: nil,
            title: title, start: at(start), end: at(end), isAllDay: allDay, isDeclined: declined,
            isFree: free, isCancelled: cancelled, isBirthday: false, location: nil, url: url,
            calendarTitle: "Work", notes: notes, hasOtherPeople: others, calendarAllowsModifications: true
        )
    }

    // MARK: The Day pane's calendar lane

    @Test("An event is drawn on the clock as the minutes of the day it covers, clipped to the day")
    func minuteSpans() {
        let day = at(0)
        let span = DayNow.minuteSpan(of: event(600, 660), on: day, calendar: Self.calendar)
        #expect(span.start == 600 && span.end == 660)
        // Begun yesterday, ends at ten: from midnight.
        let overnight = DayNow.minuteSpan(of: event(-120, 600), on: day, calendar: Self.calendar)
        #expect(overnight.start == 0 && overnight.end == 600)
        // Runs past midnight: to the end of the day.
        let late = DayNow.minuteSpan(of: event(1380, 1560), on: day, calendar: Self.calendar)
        #expect(late.start == 1380 && late.end == 1440)
        // A zero-length event is still a minute to draw.
        let instant = DayNow.minuteSpan(of: event(600, 600), on: day, calendar: Self.calendar)
        #expect(instant.end - instant.start == 1)
    }

    @Test("The clock's hours widen to hold the day's meetings and not an all-day event")
    func hoursHoldEvents() {
        let day = at(0)
        let window = 9...17
        #expect(DayNow.hourRange(window, holding: [], on: day, calendar: Self.calendar) == 9...17)
        let early = event(7 * 60 + 30, 8 * 60, "Run")
        let late = event(18 * 60, 19 * 60 + 15, "Dinner")
        #expect(DayNow.hourRange(window, holding: [early, late], on: day, calendar: Self.calendar) == 7...20)
        let trip = event(0, 1440, "Trip", allDay: true)
        #expect(DayNow.hourRange(window, holding: [trip], on: day, calendar: Self.calendar) == 9...17)
        #expect(DayNow.allDayEvents([trip, early]).map(\.title) == ["Trip"])
    }

    // MARK: State

    @Test("The calendar off is its own state; a day with nothing timed is empty")
    func offAndEmpty() {
        #expect(DayNow.state(events: [event(540, 600)], calendarOn: false, now: at(560), calendar: Self.calendar) == .calendarOff)
        #expect(DayNow.state(events: [], calendarOn: true, now: at(560), calendar: Self.calendar) == .empty)
        // All-day, declined, free and cancelled events hold no stretch of the day.
        let untimed = [
            event(0, 1440, "Trip", allDay: true),
            event(600, 660, "Declined", declined: true),
            event(600, 660, "Free", free: true),
            event(600, 660, "Called off", cancelled: true),
        ]
        #expect(DayNow.state(events: untimed, calendarOn: true, now: at(630), calendar: Self.calendar) == .empty)
    }

    @Test("Before the first event, inside one, between two, and after the last")
    func states() {
        let standup = event(540, 570, "Standup", others: true)
        let reading = event(600, 720, "Read the atlas")
        let events = [reading, standup]
        #expect(DayNow.state(events: events, calendarOn: true, now: at(500), calendar: Self.calendar) == .beforeFirst(next: standup))
        #expect(DayNow.state(events: events, calendarOn: true, now: at(550), calendar: Self.calendar) == .inEvent(standup))
        #expect(DayNow.state(events: events, calendarOn: true, now: at(580), calendar: Self.calendar) == .between(next: reading))
        #expect(DayNow.state(events: events, calendarOn: true, now: at(730), calendar: Self.calendar) == .between(next: nil))
        // An event's end is not inside it.
        #expect(DayNow.state(events: events, calendarOn: true, now: at(570), calendar: Self.calendar) == .between(next: reading))
    }

    @Test("When events overlap, the hour is in the one that began last")
    func overlap() {
        let block = event(540, 720, "Deep work")
        let call = event(600, 630, "Call", others: true)
        #expect(DayNow.state(events: [block, call], calendarOn: true, now: at(610), calendar: Self.calendar) == .inEvent(call))
        #expect(DayNow.state(events: [block, call], calendarOn: true, now: at(640), calendar: Self.calendar) == .inEvent(block))
    }

    // MARK: Presentation

    @Test("Inside an event the chip says its title and the minutes left, with a filled dot")
    func inEvent() throws {
        let reading = event(600, 720, "Read the atlas")
        let line = try #require(DayNow.presentation(state: .inEvent(reading), bout: nil, now: at(628)))
        #expect(line.title == "Read the atlas")
        #expect(line.detail == "1h 32m left")
        #expect(line.tone == .event)
        #expect(DayNow.presentation(state: .inEvent(reading), bout: nil, now: at(719))?.detail == "ending")
        // An untitled event reads as the Calendar app names one.
        #expect(DayNow.presentation(state: .inEvent(event(600, 720, "  ")), bout: nil, now: at(628))?.title == "New Event")
    }

    @Test("An event starting within the quarter hour shows ahead, with a ring")
    func upcoming() throws {
        let reading = event(600, 720, "Read the atlas")
        let before = try #require(DayNow.presentation(state: .beforeFirst(next: reading), bout: nil, now: at(588)))
        #expect(before.title == "Read the atlas")
        #expect(before.detail == "in 12m")
        #expect(before.tone == .upcoming)
        // The quarter hour itself counts; the minute before reads "starting".
        #expect(DayNow.presentation(state: .between(next: reading), bout: nil, now: at(585))?.detail == "in 15m")
        #expect(DayNow.presentation(state: .between(next: reading), bout: nil, now: at(599))?.detail == "starting")
    }

    @Test("A quiet hour draws nothing: off, empty, done for the day, or the next event a while off")
    func quiet() {
        let reading = event(600, 720, "Read the atlas")
        #expect(DayNow.presentation(state: .beforeFirst(next: reading), bout: nil, now: at(500)) == nil)
        #expect(DayNow.presentation(state: .between(next: reading), bout: nil, now: at(584)) == nil)
        #expect(DayNow.presentation(state: .between(next: nil), bout: nil, now: at(800)) == nil)
        #expect(DayNow.presentation(state: .empty, bout: nil, now: at(800)) == nil)
        #expect(DayNow.presentation(state: .calendarOff, bout: nil, now: at(800)) == nil)
    }

    @Test("A live bout takes the chip over the calendar, a quiet one too")
    func boutOutranksCalendar() throws {
        let reading = event(540, 600, "GDF15 assay")
        let now = Date()
        let bout = LearningBout(
            dayPlanID: "2026-09-18", title: "The assay, properly",
            plannedMinutes: 50, startedAt: now.addingTimeInterval(-20 * 60)
        )
        let line = try #require(DayNow.presentation(state: .inEvent(reading), bout: bout, now: now))
        #expect(line.title == "The assay, properly")
        #expect(line.detail == "30m left")
        #expect(line.tone == .bout)
        for state in [DayNowState.empty, .calendarOff, .between(next: nil)] {
            #expect(DayNow.presentation(state: state, bout: bout, now: now)?.tone == .bout)
        }

        let over = try #require(DayNow.boutPresentation(bout, now: now.addingTimeInterval(45 * 60)))
        #expect(over.detail == "15m over")
    }

    @Test("A finished bout hands the chip back to the calendar")
    func finishedBoutIsSilent() {
        var bout = LearningBout(dayPlanID: "2026-09-18", title: "Done", plannedMinutes: 30, startedAt: Date(timeIntervalSince1970: 0))
        bout.abandonedAt = Date(timeIntervalSince1970: 60)
        #expect(DayNow.boutPresentation(bout, now: Date()) == nil)
        let reading = event(540, 660, "Read around")
        #expect(DayNow.presentation(state: .inEvent(reading), bout: bout, now: at(555))?.tone == .event)
        #expect(DayNow.presentation(state: .empty, bout: bout, now: at(555)) == nil)
    }

    // MARK: The schedule

    @Test("The popover's schedule marks where the clock stands between events, never inside one")
    func scheduleRows() {
        let standup = event(540, 570, "Standup")
        let reading = event(600, 720, "Read the atlas")
        let events = [standup, reading]
        let between = DayNow.scheduleRows(events: events, state: .between(next: reading), now: at(580))
        #expect(between.map(\.id) == [standup.occurrenceKey, "now", reading.occurrenceKey])
        let before = DayNow.scheduleRows(events: events, state: .beforeFirst(next: standup), now: at(500))
        #expect(before.first == .now)
        let after = DayNow.scheduleRows(events: events, state: .between(next: nil), now: at(800))
        #expect(after.last == .now)
        let inside = DayNow.scheduleRows(events: events, state: .inEvent(reading), now: at(610))
        #expect(!inside.contains(.now))
    }

    @Test("Only timed events that hold the day are on the schedule, by start")
    func timedEvents() {
        let late = event(900, 960, "Late")
        let early = event(540, 570, "Early")
        let events = [late, event(0, 1440, "Trip", allDay: true), event(600, 660, "Free", free: true), early]
        let timed = DayNow.timedEvents(events, on: at(600), calendar: Self.calendar)
        #expect(timed.map(\.title) == ["Early", "Late"])
    }

    @Test("A Teams invitation joins from its call link, not from the help link beside it")
    func joinLink() {
        let teams = event(600, 630, "Weekly", others: true, notes: """
        Microsoft Teams meeting
        Need help? https://aka.ms/JoinTeamsMeeting
        Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc
        """)
        #expect(teams.joinLink?.label == "Join Teams")
        #expect(teams.joinLink?.url.host == "teams.microsoft.com")
        let zoom = event(600, 630, "Zara", url: "https://us02web.zoom.us/j/123")
        #expect(zoom.joinLink?.label == "Join Zoom")
        #expect(event(600, 630, "Solo").joinLink == nil)
    }

    @Test("Minutes read as hours past sixty, and the progress runs from start to end")
    func words() {
        #expect(DayNow.durationText(45) == "45m")
        #expect(DayNow.durationText(60) == "1h")
        #expect(DayNow.durationText(95) == "1h 35m")
        let reading = event(600, 720, "Read the atlas")
        #expect(DayNow.progress(of: reading, now: at(600)) == 0)
        #expect(DayNow.progress(of: reading, now: at(660)) == 0.5)
        #expect(DayNow.progress(of: reading, now: at(800)) == 1)
    }
}
