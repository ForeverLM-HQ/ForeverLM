import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The day's MCP tools: the Mac's Calendar read and written through EventKit,
/// and the day's log (MCPTools+Calendar.swift). EventKit itself is not driven
/// here — the test host has no Calendar grant — so these pin what the tools
/// decide before they reach it: the times a call names, the occurrence it
/// names, the free time left in the learner's day, and what a call says when
/// the calendar is off.
@Suite("MCP calendar tools")
struct MCPCalendarToolsTests {

    private let calendar = Calendar.current
    private let date = "2026-10-01"

    private func at(_ minute: Int, on day: String = "2026-10-01") -> Date {
        DayPlan.startOfDay(day, calendar: calendar)!.addingTimeInterval(TimeInterval(minute * 60))
    }

    private func existing(_ start: Int, _ end: Int, allDay: Bool = false) -> AppleCalendarEvent {
        AppleCalendarEvent(
            calendarID: "CAL", eventIdentifier: "E1", occurrenceDate: nil, title: "Read the atlas",
            start: at(start), end: at(end), isAllDay: allDay, isDeclined: false, isFree: false,
            isCancelled: false, isBirthday: false, location: nil, url: nil
        )
    }

    @Test("The Planner's tools are gone and the day's are registered, each saying what it needs")
    func registered() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for gone in ["get_day_plan", "add_time_block", "update_time_block", "delete_time_block", "revise_day_plan", "update_day_plan"] {
            #expect(byName[gone] == nil, "\(gone) is still registered")
        }
        let read = try #require(byName["get_calendar_events"])
        #expect(read.description.contains("has_other_people"))
        #expect(read.description.contains("free_from_now"))
        let create = try #require(byName["create_calendar_event"])
        #expect((create.inputSchema["required"] as? [String]) == ["title"])
        let update = try #require(byName["update_calendar_event"])
        #expect((update.inputSchema["required"] as? [String]) == ["event_id"])
        let delete = try #require(byName["delete_calendar_event"])
        #expect(delete.description.contains("Not undoable"))
        #expect(byName["get_day_activity"] != nil)
        let bout = try #require(byName["start_learning_bout"])
        let boutProperties = try #require(bout.inputSchema["properties"] as? [String: Any])
        #expect(boutProperties["event_id"] != nil && boutProperties["block_id"] == nil)
    }

    @Test("A new event takes its date, start and end or length; all day runs midnight to midnight")
    func newEventTimes() throws {
        let timed = try MCPDataStore.eventTimes(date: date, start: "09:30", end: "11:00", durationMinutes: nil, allDay: false, keeping: nil)
        #expect(timed.start == at(570) && timed.end == at(660))
        let long = try MCPDataStore.eventTimes(date: date, start: "23:00", end: nil, durationMinutes: 120, allDay: false, keeping: nil)
        #expect(long.end == at(60, on: "2026-10-02"), "a length carries past midnight")
        let allDay = try MCPDataStore.eventTimes(date: date, start: nil, end: nil, durationMinutes: nil, allDay: true, keeping: nil)
        #expect(allDay.start == at(0) && allDay.end == at(0, on: "2026-10-02"))

        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventTimes(date: date, start: nil, end: "10:00", durationMinutes: nil, allDay: false, keeping: nil) }
        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventTimes(date: date, start: "09:00", end: nil, durationMinutes: nil, allDay: false, keeping: nil) }
        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventTimes(date: date, start: "10:00", end: "09:00", durationMinutes: nil, allDay: false, keeping: nil) }
        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventTimes(date: date, start: "9 am", end: "10:00", durationMinutes: nil, allDay: false, keeping: nil) }
        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventTimes(date: date, start: "09:00", end: nil, durationMinutes: 0, allDay: false, keeping: nil) }
    }

    @Test("A change keeps what it does not name: the time when only the date moves, the length when only the start does")
    func changedEventTimes() throws {
        let event = existing(570, 660)
        let movedDay = try MCPDataStore.eventTimes(date: "2026-10-02", start: nil, end: nil, durationMinutes: nil, allDay: false, keeping: event)
        #expect(movedDay.start == at(570, on: "2026-10-02") && movedDay.end == at(660, on: "2026-10-02"))
        let later = try MCPDataStore.eventTimes(date: date, start: "13:00", end: nil, durationMinutes: nil, allDay: false, keeping: event)
        #expect(later.start == at(780) && later.end == at(870))
        let longer = try MCPDataStore.eventTimes(date: date, start: nil, end: "12:00", durationMinutes: nil, allDay: false, keeping: event)
        #expect(longer.start == at(570) && longer.end == at(720))
        let shorter = try MCPDataStore.eventTimes(date: date, start: nil, end: nil, durationMinutes: 30, allDay: false, keeping: event)
        #expect(shorter.end == at(600))
    }

    @Test("An occurrence is named by the time get_calendar_events gave it, and a span is this or future")
    func occurrenceAndSpan() throws {
        let original = at(570)
        let written = MCPDataStore.localISO.string(from: original)
        #expect(try MCPDataStore.occurrenceDate(written) == original)
        #expect(try MCPDataStore.occurrenceDate("2026-10-01T07:30:00Z") == ISO8601DateFormatter().date(from: "2026-10-01T07:30:00Z"))
        #expect(try MCPDataStore.occurrenceDate(nil) == nil)
        #expect(throws: MCPError.self) { _ = try MCPDataStore.occurrenceDate("next Tuesday") }
        #expect(try MCPDataStore.eventSpan(nil) == .thisEvent)
        #expect(try MCPDataStore.eventSpan("future") == .futureEvents)
        #expect(throws: MCPError.self) { _ = try MCPDataStore.eventSpan("all") }
    }

    @Test("The free time left is what no event holds inside the learner's day, from now on today")
    func freeStretches() {
        let clock = DayClock(date: date, now: at(600), calendar: calendar, dayHours: 8...18)
        let busy: [(start: Date, end: Date)] = [(at(540), at(630)), (at(660), at(720)), (at(700), at(750)), (at(1000), at(1005))]
        let free = clock.freeStretches(busy: busy)
        // From now (10:00), not the day's start; a meeting overlapping another
        // is one busy stretch; a sliver under fifteen minutes is not free time.
        #expect(free == [630..<660, 750..<1000, 1005..<1080])
        // A meeting over before now, one after the day's end, and one with its
        // end before its start hold none of the time left (the standup at
        // 09:00 asked about at 14:20 once trapped here).
        let outside: [(start: Date, end: Date)] = [(at(540), at(570)), (at(1100), at(1160)), (at(900), at(880))]
        #expect(clock.freeStretches(busy: outside) == [600..<1080])
        #expect(clock.freeStretches(busy: outside + busy) == free)
        // A day ahead counts from the start of the learner's day.
        let tomorrow = DayClock(date: "2026-10-02", now: at(600), calendar: calendar, dayHours: 8...18)
        #expect(tomorrow.freeStretches(busy: []) == [480..<1080])
        // A day behind has none.
        let yesterday = DayClock(date: "2026-09-30", now: at(600), calendar: calendar, dayHours: 8...18)
        #expect(yesterday.freeStretches(busy: []).isEmpty)
        #expect(clock.fields(busy: busy)["free_from_now"] != nil)
        #expect(tomorrow.fields(busy: [])["free"] != nil)
        #expect(tomorrow.relativeDay == "tomorrow")
    }

    @Test("The day's calendars: every calendar but Birthdays until the learner chooses, and an account signed in after the choice shows until unticked")
    func shownCalendars() {
        let calendars = [
            AppleCalendarListEntry(id: "work", title: "Work", account: "iCloud", accountID: "icloud", isBirthdays: false, isSubscribed: false),
            AppleCalendarListEntry(id: "bday", title: "Birthdays", account: "Other", accountID: "other", isBirthdays: true, isSubscribed: false),
            AppleCalendarListEntry(id: "hol", title: "Holidays", account: "Other", accountID: "other", isBirthdays: false, isSubscribed: true),
        ]
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: nil, knownAccountIDs: nil, newEventsCalendarID: nil).map(\.id) == ["work", "hol"])
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: ["bday"], knownAccountIDs: nil, newEventsCalendarID: nil).map(\.id) == ["bday"])
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: [], knownAccountIDs: nil, newEventsCalendarID: nil).isEmpty)
        #expect(AppleCalendarService.accountIDs(of: calendars) == ["icloud", "other"])

        // An Exchange account signed in after the choice is shown; the
        // calendars the choice left off stay off.
        let withExchange = calendars + [
            AppleCalendarListEntry(id: "ews", title: "Calendar", account: "Exchange", accountID: "exchange", isBirthdays: false, isSubscribed: false),
            AppleCalendarListEntry(id: "ews-bday", title: "Birthdays", account: "Exchange", accountID: "exchange", isBirthdays: true, isSubscribed: false),
        ]
        let known = AppleCalendarService.accountIDs(of: calendars)
        #expect(AppleCalendarService.shown(from: withExchange, selectedIDs: [], knownAccountIDs: known, newEventsCalendarID: nil).map(\.id) == ["ews"])
        #expect(AppleCalendarService.shown(from: withExchange, selectedIDs: ["work"], knownAccountIDs: known, newEventsCalendarID: nil).map(\.id) == ["work", "ews"])
        // Once the learner chooses with Exchange listed, its calendars follow the choice.
        #expect(AppleCalendarService.shown(from: withExchange, selectedIDs: ["work"], knownAccountIDs: AppleCalendarService.accountIDs(of: withExchange), newEventsCalendarID: nil).map(\.id) == ["work"])
        // A choice from before accounts were recorded is kept as it was.
        #expect(AppleCalendarService.shown(from: withExchange, selectedIDs: ["work"], knownAccountIDs: nil, newEventsCalendarID: nil).map(\.id) == ["work"])
    }

    @Test("The calendar new events go to is always in the day, so a planned day is never hidden; the stored choice leaves it as the learner made it")
    func newEventsCalendarAlwaysShown() {
        let calendars = [
            AppleCalendarListEntry(id: "icloud", title: "Calendar", account: "iCloud", accountID: "icloud", isBirthdays: false, isSubscribed: false),
            AppleCalendarListEntry(id: "ews", title: "Calendar", account: "Exchange", accountID: "exchange", isBirthdays: false, isSubscribed: false),
            AppleCalendarListEntry(id: "bday", title: "Birthdays", account: "Other", accountID: "other", isBirthdays: true, isSubscribed: false),
        ]
        let known = AppleCalendarService.accountIDs(of: calendars)
        // The product owner's Mac on 2026-09-30: no calendar chosen, and a chat had
        // planned the evening into iCloud. The plan shows.
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: [], knownAccountIDs: known, newEventsCalendarID: "icloud").map(\.id) == ["icloud"])
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: ["ews"], knownAccountIDs: known, newEventsCalendarID: "icloud").map(\.id) == ["icloud", "ews"])
        // Already shown: nothing doubles.
        #expect(AppleCalendarService.shown(from: calendars, selectedIDs: nil, knownAccountIDs: nil, newEventsCalendarID: "icloud").map(\.id) == ["icloud", "ews"])
        // What the Settings checkboxes store leaves it out unless chosen.
        #expect(!AppleCalendarService.isChosen(calendars[0], selectedIDs: ["ews"], knownAccountIDs: known))
        #expect(AppleCalendarService.isChosen(calendars[1], selectedIDs: ["ews"], knownAccountIDs: known))
        #expect(!AppleCalendarService.isChosen(calendars[2], selectedIDs: nil, knownAccountIDs: nil))
    }

    @Test("The Planner's choice of Mac calendars is not read as the day's")
    func plannerChoiceRetired() {
        #expect(!AppleCalendarService.retiredPlannerSelectionKeys.contains(AppleCalendarService.selectedIDsKey))
        #expect(!AppleCalendarService.retiredPlannerSelectionKeys.contains(AppleCalendarService.knownAccountIDsKey))
        #expect(AppleCalendarService.retiredPlannerSelectionKeys == ["planner.appleCalendar.selectedIDs", "planner.appleCalendar.knownAccountIDs"])
    }

    @Test("With the Mac's Calendar off, every calendar tool says how to turn it on and writes nothing")
    func calendarOff() async throws {
        guard !AppleCalendarService.shared.isConnected else { return }
        let registry = MCPToolRegistry(store: MCPDataStore())
        for (name, arguments) in [
            ("get_calendar_events", [:] as [String: Any]),
            ("create_calendar_event", ["title": "Read", "start": "09:00", "end": "10:00"] as [String: Any]),
            ("update_calendar_event", ["event_id": "E1", "title": "x"] as [String: Any]),
            ("delete_calendar_event", ["event_id": "E1"] as [String: Any]),
        ] {
            let outcome = await registry.callToolDetailed(name: name, arguments: arguments)
            #expect(outcome.isError, "\(name) answered \(outcome.text)")
            #expect(outcome.text.contains("Calendar"), "\(name) answered \(outcome.text)")
        }
    }
}

/// Groups: each context of the learner's work on a calendar of its own, so
/// it keeps one colour (`CalendarGroup`, `CalendarGroups`). Made-up names.
@Suite("Calendar groups")
struct CalendarGroupsTests {

    private let dayJob = CalendarGroup(id: "g1", name: "Acme", calendarID: "WORK", keywords: ["Widget review"])
    private let society = CalendarGroup(id: "g2", name: "Guild", calendarID: "GUILD", keywords: ["Grant draft"])
    private let sport = CalendarGroup(id: "g3", name: "Exercise", calendarID: "GYM", keywords: ["Run", "Gym"])

    private var groups: [CalendarGroup] { [dayJob, society, sport] }

    @Test("A block's title names its group first, then its notes")
    func titleThenNotes() {
        #expect(CalendarGroups.group(title: "Guild thesis: write", notes: "Before the Acme sync", in: groups)?.id == "g2")
        #expect(CalendarGroups.group(title: "Grant draft: proposals", notes: nil, in: groups)?.id == "g2")
        #expect(CalendarGroups.group(title: "Deep work", notes: "Serves Q4 objective: Acme (handover)", in: groups)?.id == "g1")
        #expect(CalendarGroups.group(title: "Dentist", notes: "Bring the forms", in: groups) == nil)
    }

    @Test("A word must stand on its own, in any case and accent")
    func wholeWords() {
        #expect(CalendarGroups.names("guild mtDNA thesis", "Guild"))
        #expect(CalendarGroups.names("Prep (Gym)", "gym"))
        #expect(!CalendarGroups.names("Guildford trip", "Guild"))
        #expect(!CalendarGroups.names("Rerun the predictions", "Run"))
        #expect(CalendarGroups.names("Café run", "cafe"))
    }

    @Test("The longest word wins when two groups are named")
    func longestWins() {
        let block = CalendarGroups.group(title: "Widget review with the Guild", notes: nil, in: groups)
        #expect(block?.id == "g1")
    }

    @Test("A block on a group's calendar is that group's, whatever it says")
    func calendarFirst() {
        #expect(CalendarGroups.group(calendarID: "GYM", title: "Acme standup", notes: nil, in: groups)?.id == "g3")
        #expect(CalendarGroups.group(calendarID: "OTHER", title: "Acme standup", notes: nil, in: groups)?.id == "g1")
    }

    @Test("Words under three letters never name a group")
    func shortWords() {
        let tiny = CalendarGroup(name: "Ox", calendarID: "OX", keywords: ["  ", "Oxbow"])
        #expect(tiny.words == ["Oxbow"])
        #expect(CalendarGroups.group(title: "Ox day", notes: nil, in: [tiny]) == nil)
    }

    @Test("Keywords come from a comma list, blanks and repeats dropped")
    func keywordList() {
        #expect(CalendarGroups.keywords(from: "Grant draft, , grant draft,WR-16 ") == ["Grant draft", "WR-16"])
    }

    @Test("Groups survive a round trip through the Mac's defaults, and an empty list clears them")
    func storage() throws {
        let defaults = try #require(UserDefaults(suiteName: "CalendarGroupsTests-\(UUID().uuidString)"))
        CalendarGroups.save(groups, to: defaults)
        #expect(CalendarGroups.load(from: defaults) == groups)
        CalendarGroups.save([], to: defaults)
        #expect(defaults.data(forKey: CalendarGroups.defaultsKey) == nil)
        #expect(CalendarGroups.load(from: defaults).isEmpty)
    }

    @Test("A group's calendar is in the day even when the learner's choice leaves it off")
    func groupCalendarsShown() {
        let calendars = [
            AppleCalendarListEntry(id: "MINE", title: "Calendar", account: "iCloud", accountID: "A", isBirthdays: false, isSubscribed: false),
            AppleCalendarListEntry(id: "GUILD", title: "Guild", account: "iCloud", accountID: "A", isBirthdays: false, isSubscribed: false),
        ]
        let without = AppleCalendarService.shown(from: calendars, selectedIDs: ["MINE"], knownAccountIDs: ["A"], newEventsCalendarID: nil)
        #expect(without.map(\.id) == ["MINE"])
        let with = AppleCalendarService.shown(
            from: calendars, selectedIDs: ["MINE"], knownAccountIDs: ["A"], newEventsCalendarID: nil, groupCalendarIDs: ["GUILD"]
        )
        #expect(with.map(\.id) == ["MINE", "GUILD"])
    }

    @Test("Colours read and write as #RRGGBB")
    func colorHex() {
        #expect(CalendarColor(hex: "#FF8D28")?.hex == "#FF8D28")
        #expect(CalendarColor(hex: "a359d9")?.hex == "#A359D9")
        #expect(CalendarColor(hex: "#12345") == nil)
        #expect(CalendarColor(hex: "purple") == nil)
    }

    @Test("Repeats become the rule a planned week needs")
    func repeats() {
        #expect(CalendarEventRepeat.weekly.rule(until: nil).frequency == .weekly)
        #expect(CalendarEventRepeat.weekly.rule(until: nil).daysOfTheWeek == nil)
        #expect(CalendarEventRepeat.weekdays.rule(until: nil).daysOfTheWeek?.count == 5)
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CalendarEventRepeat.daily.rule(until: until).recurrenceEnd?.endDate == until)
    }

    @Test("A regroup reaches from this week's Monday through thirteen weeks")
    func regroupSpan() throws {
        let calendar = PlanQuarterWeeks.weekCalendar()
        let wednesday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15)))
        let span = CalendarGroups.regroupSpan(now: wednesday)
        #expect(calendar.component(.weekday, from: span.start) == 2)
        #expect(calendar.component(.day, from: span.start) == 9)
        #expect(calendar.dateComponents([.day], from: span.start, to: span.end).day == 91)
    }

    @Test("Overlapping events sit side by side in the week grid")
    func gridLanes() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }
        let lanes = PlanWeekGrid.lanes([
            (id: "a", start: at(0), end: at(60)),
            (id: "b", start: at(30), end: at(90)),
            (id: "c", start: at(60), end: at(120)),
            (id: "d", start: at(180), end: at(240)),
        ])
        #expect(lanes["a"]?.index == 0)
        #expect(lanes["b"]?.index == 1)
        #expect(lanes["c"]?.index == 0)
        #expect(lanes["a"]?.count == 2 && lanes["b"]?.count == 2 && lanes["c"]?.count == 2)
        #expect(lanes["d"]?.index == 0 && lanes["d"]?.count == 1)
    }

    @Test("The calendar tools offer groups, repeats and one context at a time")
    func toolsSayIt() throws {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let create = try #require(byName["create_calendar_event"])
        let createProperties = try #require(create.inputSchema["properties"] as? [String: Any])
        #expect(createProperties["repeat"] != nil && createProperties["repeat_until"] != nil)
        #expect(create.description.contains("group"))
        let set = try #require(byName["set_calendar_settings"])
        let setProperties = try #require(set.inputSchema["properties"] as? [String: Any])
        #expect(setProperties["groups"] != nil && setProperties["regroup"] != nil)
        #expect(MCPDataStore.oneContextGuidance.contains("one context at a time"))
        #expect(ReviewSlashCommandParser.planDayInstructions.contains("one context in my head at a time"))
    }
}

#endif
