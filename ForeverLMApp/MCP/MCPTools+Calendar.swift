import Foundation

// MARK: - The day (MCP tools)
//
// The learner's day is the Mac's Calendar (2026-09-30, when the Planner went;
// the product owner: "the agent can plan our day by literally writing to the mac
// calendar"). An assistant reads the day's events, adds the hours it plans as
// events, and moves or removes the ones it added — through EventKit, so what
// it writes is in the Calendar app, on the learner's phone through their
// calendar account, and in the Now chip at once. What the calendar cannot hold
// stays ForeverLM's: the day's log of what the learner actually did
// (`get_day_activity`) and learning bouts (MCPTools+LearningBouts.swift).
//
// Desktop-only in the public allowlist: EventKit and the grant are the Mac's.

extension MCPDataStore {

    // MARK: Reading the calendar

    /// One or more days of the shown calendars, event by event, with where
    /// each stands against the learner's clock and, for today, the free time
    /// left in the learner's day.
    func getCalendarEvents(date rawDate: String?, days rawDays: Int?) async throws -> String {
        let service = try await connectedCalendar()
        let first = try resolvedDayDate(rawDate)
        let days = min(max(rawDays ?? 1, 1), 14)
        let now = Date()
        let scope = screenRecordScope()
        var dayPayloads: [[String: Any]] = []
        for offset in 0..<days {
            guard let date = DayPlan.dateString(first, offsetBy: offset),
                  let dayStart = DayPlan.startOfDay(date),
                  let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            var events = try await service.shownEvents(from: dayStart, to: dayEnd)
            if let scope { events = events.filter(scope.allowsCalendarEvent) }
            let clock = DayClock(date: date, now: now)
            var day: [String: Any] = [
                "date": date,
                "events": events.map { calendarEventPayload($0, now: now) },
            ]
            day.merge(clock.fields(busy: DayNow.timedEvents(events, on: dayStart).map { ($0.start, $0.end) })) { _, new in new }
            dayPayloads.append(day)
        }
        var payload: [String: Any] = [
            "calendar_on": true,
            "today": DayPlan.dateString(for: now),
            "now": DayNow.clockString(now),
            "timezone": TimeZone.current.identifier,
            "days": dayPayloads,
            "guidance": "Plan a day by adding its hours as events with create_calendar_event, into the free stretches (free_from_now on today). An event with has_other_people is a meeting: it stays at its time, and only the Calendar app may change it. editable says which events you may move or delete; delete only what the learner asked you to or what you added for them.",
        ]
        if let calendar = try await service.newEventsCalendar() {
            payload["new_events_calendar"] = ["id": calendar.id, "title": calendar.title, "account": calendar.account]
        }
        return try jsonString(payload)
    }

    // MARK: Writing the calendar

    func createCalendarEvent(arguments: [String: Any]) async throws -> String {
        let service = try await connectedCalendar()
        guard let title = Self.dayText(arguments["title"]) else {
            throw MCPError.invalidInput("title is required: what the hour is for, in the learner's words.")
        }
        let date = try resolvedDayDate(arguments["date"] as? String)
        let allDay = try Self.dayBool(arguments["all_day"], "all_day") ?? false
        let times = try Self.eventTimes(
            date: date,
            start: Self.dayText(arguments["start"]),
            end: Self.dayText(arguments["end"]),
            durationMinutes: Self.dayInt(arguments["duration_minutes"], "duration_minutes"),
            allDay: allDay,
            keeping: nil
        )
        let calendarID = try await resolvedCalendarID(Self.dayText(arguments["calendar_id"]), service: service)
        let url = try Self.eventURL(Self.dayText(arguments["url"]))
        do {
            let event = try await service.createEvent(CalendarEventDraft(
                title: title,
                start: times.start,
                end: times.end,
                isAllDay: allDay,
                notes: Self.dayText(arguments["notes"]),
                location: Self.dayText(arguments["location"]),
                url: url,
                calendarID: calendarID
            ))
            return try jsonString([
                "created": true,
                "event": calendarEventPayload(event, now: Date()),
                "message": "Added ‘\(DayNow.displayTitle(event))’ to \(event.calendarTitle), \(Self.dayLabel(event)).",
            ] as [String: Any])
        } catch let error as AppleCalendarServiceError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    func updateCalendarEvent(arguments: [String: Any]) async throws -> String {
        let service = try await connectedCalendar()
        guard let eventID = Self.dayText(arguments["event_id"]) else {
            throw MCPError.invalidInput("event_id is required. get_calendar_events returns it.")
        }
        let occurrence = try Self.occurrenceDate(Self.dayText(arguments["occurrence_date"]))
        let span = try Self.eventSpan(Self.dayText(arguments["span"]))
        let existing = try await calendarEvent(eventID: eventID, occurrenceDate: arguments["occurrence_date"] as? String)
        var changes = CalendarEventChanges()
        changes.title = Self.dayText(arguments["title"])
        changes.notes = arguments["notes"] as? String
        changes.location = arguments["location"] as? String
        changes.url = arguments["url"] as? String
        if let url = changes.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try Self.eventURL(url)
        }
        let allDay = try Self.dayBool(arguments["all_day"], "all_day")
        changes.isAllDay = allDay
        let rawDate = arguments["date"] as? String
        let start = Self.dayText(arguments["start"])
        let end = Self.dayText(arguments["end"])
        let duration = try Self.dayInt(arguments["duration_minutes"], "duration_minutes")
        if rawDate != nil || start != nil || end != nil || duration != nil || allDay != nil {
            let date = rawDate == nil ? DayPlan.dateString(for: existing.start) : try resolvedDayDate(rawDate)
            let times = try Self.eventTimes(
                date: date,
                start: start,
                end: end,
                durationMinutes: duration,
                allDay: allDay ?? existing.isAllDay,
                keeping: existing
            )
            changes.start = times.start
            changes.end = times.end
        }
        if let calendarID = Self.dayText(arguments["calendar_id"]) {
            changes.calendarID = try await resolvedCalendarID(calendarID, service: service)
        }
        guard !changes.isEmpty else {
            throw MCPError.invalidInput("Pass at least one of title, date, start, end, duration_minutes, all_day, notes, location, url or calendar_id.")
        }
        do {
            let event = try await service.updateEvent(identifier: eventID, occurrenceDate: occurrence, changes: changes, span: span)
            return try jsonString([
                "updated": true,
                "event": calendarEventPayload(event, now: Date()),
                "message": "Changed ‘\(DayNow.displayTitle(event))’: \(Self.dayLabel(event)).",
            ] as [String: Any])
        } catch let error as AppleCalendarServiceError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    func deleteCalendarEvent(arguments: [String: Any]) async throws -> String {
        let service = try await connectedCalendar()
        guard let eventID = Self.dayText(arguments["event_id"]) else {
            throw MCPError.invalidInput("event_id is required. get_calendar_events returns it.")
        }
        let occurrence = try Self.occurrenceDate(Self.dayText(arguments["occurrence_date"]))
        let span = try Self.eventSpan(Self.dayText(arguments["span"]))
        let existing = try await calendarEvent(eventID: eventID, occurrenceDate: arguments["occurrence_date"] as? String)
        do {
            try await service.deleteEvent(identifier: eventID, occurrenceDate: occurrence, span: span)
        } catch let error as AppleCalendarServiceError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "deleted": true,
            "event_id": eventID,
            "message": "Removed ‘\(DayNow.displayTitle(existing))’ (\(Self.dayLabel(existing)))\(span == .futureEvents ? " and the occurrences after it" : "") from \(existing.calendarTitle).",
        ] as [String: Any])
    }

    /// One event by id, for a tool that acts on it. Not private: the bout
    /// tools start a bout on an event.
    func calendarEvent(eventID: String, occurrenceDate rawOccurrence: String?) async throws -> AppleCalendarEvent {
        let service = try await connectedCalendar()
        let occurrence = try Self.occurrenceDate(Self.dayText(rawOccurrence))
        do {
            return try await service.event(identifier: eventID, occurrenceDate: occurrence)
        } catch AppleCalendarServiceError.eventNotFound {
            throw MCPError.notFound("No event with id \(eventID)\(occurrence == nil ? "" : " on that occurrence") in the Mac's Calendar. get_calendar_events lists the day's events.")
        } catch let error as AppleCalendarServiceError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    private func connectedCalendar() async throws -> AppleCalendarService {
        let service = AppleCalendarService.shared
        guard service.isConnected else {
            let hint = service.isBlockedBySystem
                ? "macOS refused ForeverLM's Calendar access; the learner allows it in System Settings › Privacy & Security › Calendars, then turns Calendar on."
                : "Turn it on with set_calendar_settings apple_calendar_enabled true (macOS asks the learner once), or the learner turns it on in Settings › Plugins › Calendar."
            throw MCPError.invalidInput("The Mac's Calendar is off for ForeverLM. \(hint)")
        }
        return service
    }

    /// A calendar named by id, or by a title only one calendar has.
    private func resolvedCalendarID(_ requested: String?, service: AppleCalendarService) async throws -> String? {
        guard let requested else { return nil }
        let calendars = try await service.calendars()
        if calendars.contains(where: { $0.id == requested }) { return requested }
        let byTitle = calendars.filter { $0.title.caseInsensitiveCompare(requested) == .orderedSame }
        guard byTitle.count == 1 else {
            let known = calendars.filter(\.allowsModifications).map { "\($0.title) [\($0.id)]" }.joined(separator: ", ")
            throw MCPError.notFound("No single calendar matches \(requested). Calendars that take events: \(known.isEmpty ? "none" : known).")
        }
        return byTitle[0].id
    }

    // MARK: The day's log

    /// What ForeverLM saw the learner do on a day, span by span, with the
    /// day's bouts: the half of the day the calendar cannot hold.
    func getDayActivity(date rawDate: String?) async throws -> String {
        let date = try resolvedDayDate(rawDate)
        let clock = DayClock(date: date, now: Date())
        var payload: [String: Any] = ["date": date]
        payload.merge(clock.fields(busy: nil)) { _, new in new }
        guard let stored = try await notebookFileStorage.loadDayPlan(date) else {
            payload["log"] = []
            payload["logged_minutes"] = [:] as [String: Int]
            payload["bouts"] = []
            payload["minutes_learned"] = 0
            return try jsonString(payload)
        }
        // Screen record mode (admin only): the take's own log and bouts.
        let detail = screenRecordScope().map { $0.scoped(stored) } ?? stored
        let nowMinute = clock.isToday ? clock.nowMinute : nil
        payload["log"] = detail.activities.map { dayActivityPayload($0, nowMinuteIfToday: nowMinute) }
        payload["logged_minutes"] = Dictionary(uniqueKeysWithValues: detail.loggedMinutesByKind.map { ($0.key.rawValue, $0.value) })
        payload["bouts"] = detail.boutsByRecency.map { learningBoutPayload($0) }
        payload["minutes_learned"] = detail.minutesLearned()
        return try jsonString(payload)
    }

    /// The Activity pane's Delete on a sitting, one span at a time: the span
    /// is named back before it goes, so the answer says what was forgotten.
    func deleteDayActivity(activityID rawID: String?) async throws -> String {
        let activityID = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activityID.isEmpty else {
            throw MCPError.invalidInput("activity_id is required. Use the log in get_day_activity to find it.")
        }
        guard let activity = try knowledgeStore().loadDayActivity(activityID) else {
            throw MCPError.notFound("No log entry with id \(activityID).")
        }
        do {
            try await notebookFileStorage.deleteDayActivities([activityID])
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let clock = "\(DayPlan.clockString(minute: activity.startMinute))–\(DayPlan.clockString(minute: activity.endMinute))"
        return try jsonString([
            "deleted": true,
            "activity_id": activityID,
            "date": activity.dayPlanID,
            "title": activity.title,
            "kind": activity.kind.rawValue,
            "message": "Forgot ‘\(activity.title)’ (\(clock)) from \(activity.dayPlanID)'s log.",
        ] as [String: Any])
    }

    // MARK: Payloads

    func calendarEventPayload(_ event: AppleCalendarEvent, now: Date) -> [String: Any] {
        var payload: [String: Any] = [
            "event_id": event.eventIdentifier,
            "title": DayNow.displayTitle(event),
            "calendar_id": event.calendarID,
            "calendar": event.calendarTitle,
            "date": DayPlan.dateString(for: event.start),
            "all_day": event.isAllDay,
            "start_at": Self.localISO.string(from: event.start),
            "end_at": Self.localISO.string(from: event.end),
            "duration_minutes": Int((event.end.timeIntervalSince(event.start) / 60).rounded()),
            "when": event.end <= now ? "ended" : (event.start <= now ? "now" : "ahead"),
            "has_other_people": event.hasOtherPeople,
            "editable": event.isEditable,
            "recurring": event.occurrenceDate != nil,
        ]
        if !event.isAllDay {
            payload["start"] = DayNow.clockString(event.start)
            payload["end"] = DayNow.clockString(event.end)
        }
        if let occurrence = event.occurrenceDate { payload["occurrence_date"] = Self.localISO.string(from: occurrence) }
        if event.start <= now, now < event.end, !event.isAllDay {
            payload["minutes_left"] = Int((event.end.timeIntervalSince(now) / 60).rounded(.up))
        }
        if let location = event.location, !location.isEmpty { payload["location"] = location }
        if let url = event.url, !url.isEmpty { payload["url"] = url }
        if let link = event.joinLink { payload["join_link"] = link.url.absoluteString }
        if let notes = event.notes, !notes.isEmpty { payload["notes"] = notes }
        if !event.attendeeNames.isEmpty { payload["attendees"] = event.attendeeNames }
        if event.isFree { payload["free"] = true }
        if event.isDeclined { payload["declined"] = true }
        if event.isCancelled { payload["cancelled"] = true }
        if let link = event.calendarAppURL { payload["calendar_link"] = link.absoluteString }
        return payload
    }

    /// One span of the day's log: what the app saw the learner doing, when,
    /// and the link that opens it. On today a span still going says so
    /// (`ongoing`) and runs to now: its stored end is exclusive and written in
    /// batches, so a sitting in progress would otherwise read as ending a
    /// minute after the clock, or two before it.
    func dayActivityPayload(_ activity: DayActivity, nowMinuteIfToday: Int?) -> [String: Any] {
        let nowMinute = nowMinuteIfToday.flatMap { activity.isOngoing(atMinute: $0) ? $0 : nil }
        let endMinute = nowMinute ?? activity.endMinute
        var payload: [String: Any] = [
            "activity_id": activity.id,
            "start": DayPlan.clockString(minute: activity.startMinute),
            "end": DayPlan.clockString(minute: endMinute),
            "duration_minutes": max(0, endMinute - activity.startMinute),
            "kind": activity.kind.rawValue,
            "title": activity.title,
            "\(activity.kind.targetKind)_id": activity.targetID,
            "link": activity.link,
        ]
        if nowMinute != nil { payload["ongoing"] = true }
        return payload
    }

    func meetingActionItemPayload(_ item: MeetingActionItem) -> [String: Any] {
        var payload: [String: Any] = [
            "item_id": item.id,
            "text": item.text,
            "done": item.isDone,
            "source_id": item.sourceID,
            "group_id": item.groupID,
            "position": item.position,
        ]
        if let owner = item.owner { payload["owner"] = owner }
        if let due = item.dueHint { payload["due"] = due }
        if let doneAt = item.doneAt { payload["done_at"] = ISO8601DateFormatter().string(from: doneAt) }
        return payload
    }

    // MARK: Input

    /// Dates are structure, parsed deterministically; an omitted date is today
    /// on this Mac's clock.
    func resolvedDayDate(_ raw: String?) throws -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "today" {
            return DayPlan.dateString(for: Date())
        }
        if trimmed.lowercased() == "tomorrow", let tomorrow = DayPlan.dateString(DayPlan.dateString(for: Date()), offsetBy: 1) {
            return tomorrow
        }
        guard DayPlan.isValidDateString(trimmed) else {
            throw MCPError.invalidInput("date must be formatted YYYY-MM-DD (or \"today\" / \"tomorrow\"), not \"\(trimmed)\".")
        }
        return trimmed
    }

    /// Where an event starts and ends on `date`. A new event names its start
    /// and its end or length; a change keeps whatever it does not name — the
    /// time of day when only the date moves, the length when only the start
    /// does. An all-day event runs from the day's midnight to the next.
    static func eventTimes(
        date: String,
        start: String?,
        end: String?,
        durationMinutes: Int?,
        allDay: Bool,
        keeping existing: AppleCalendarEvent?,
        calendar: Calendar = .current
    ) throws -> (start: Date, end: Date) {
        guard let dayStart = DayPlan.startOfDay(date, calendar: calendar) else {
            throw MCPError.invalidInput("date must be formatted YYYY-MM-DD, not \"\(date)\".")
        }
        if allDay {
            let days = max(1, (durationMinutes ?? 0) / DayPlan.minutesPerDay)
            guard let dayEnd = calendar.date(byAdding: .day, value: days, to: dayStart) else {
                throw MCPError.invalidInput("That day has no end on this calendar.")
            }
            return (dayStart, dayEnd)
        }
        let startMinute: Int
        if let start {
            startMinute = try clockMinute(start, field: "start")
        } else if let existing, !existing.isAllDay {
            let parts = calendar.dateComponents([.hour, .minute], from: existing.start)
            startMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        } else {
            throw MCPError.invalidInput("start is required: a 24-hour clock time, HH:MM.")
        }
        let startDate = dayStart.addingTimeInterval(TimeInterval(startMinute * 60))
        let endDate: Date
        if let end {
            let endMinute = try clockMinute(end, field: "end")
            guard endMinute > startMinute else {
                throw MCPError.invalidInput("end must be after start on the same day; for an event past midnight pass duration_minutes instead.")
            }
            endDate = dayStart.addingTimeInterval(TimeInterval(endMinute * 60))
        } else if let durationMinutes {
            guard durationMinutes > 0, durationMinutes <= 24 * 60 else {
                throw MCPError.invalidInput("duration_minutes must be between 1 and 1440.")
            }
            endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        } else if let existing, !existing.isAllDay {
            endDate = startDate.addingTimeInterval(existing.end.timeIntervalSince(existing.start))
        } else {
            throw MCPError.invalidInput("Pass end (HH:MM) or duration_minutes.")
        }
        return (startDate, endDate)
    }

    private static func clockMinute(_ raw: String, field: String) throws -> Int {
        guard let minute = DayPlan.minute(fromClock: raw) else {
            throw MCPError.invalidInput("\(field) must be a 24-hour clock time formatted HH:MM, not \"\(raw)\".")
        }
        return minute
    }

    /// An occurrence's original date, as `get_calendar_events` gave it.
    static func occurrenceDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = localISO.date(from: raw) ?? withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return date
        }
        throw MCPError.invalidInput("occurrence_date must be the ISO 8601 time get_calendar_events returned, not \"\(raw)\".")
    }

    static func eventSpan(_ raw: String?) throws -> CalendarEventSpan {
        guard let raw else { return .thisEvent }
        guard let span = CalendarEventSpan(rawValue: raw.lowercased()) else {
            throw MCPError.invalidInput("span must be \"this\" or \"future\".")
        }
        return span
    }

    static func eventURL(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        guard let url = URL(string: raw), url.scheme != nil else {
            throw MCPError.invalidInput("url must be a full link, not \"\(raw)\".")
        }
        return url
    }

    fileprivate static func dayText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func dayBool(_ value: Any?, _ name: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return try AppSettingEntry.bool(value, name)
    }

    fileprivate static func dayInt(_ value: Any?, _ name: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double, double.rounded() == double { return Int(double) }
        if let text = value as? String, let int = Int(text.trimmingCharacters(in: .whitespaces)) { return int }
        throw MCPError.invalidInput("\(name) must be a whole number.")
    }

    /// "Thursday 1 October, 09:00–10:30", said back after a write.
    private static func dayLabel(_ event: AppleCalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM"
        let day = formatter.string(from: event.start)
        return event.isAllDay ? "\(day), all day" : "\(day), \(DayNow.rangeText(event))"
    }

    /// ISO 8601 on the learner's clock, offset included: "2026-10-01T09:00:00+02:00".
    static let localISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - The learner's clock

/// Where the learner's clock stands against the day being read, said in the
/// payload instead of left to the assistant: the day's name, where it sits
/// against today, the hours the learner's day runs, and on today the clock and
/// the free time left of it (product owner, 2026-09-29: "clearly it doesn't have a
/// good sense of the time right now as it's making this plan").
struct DayClock: Sendable {
    /// The day being read, as `YYYY-MM-DD`.
    let date: String
    /// Today on the learner's Mac.
    let today: String
    let now: Date
    /// Minutes after local midnight, now.
    let nowMinute: Int
    /// The hours the learner's day runs (`PlannerDayHours`, Settings › General › Day).
    let dayHours: ClosedRange<Int>
    let calendar: Calendar

    init(date: String, now: Date = Date(), calendar: Calendar = .current, dayHours: ClosedRange<Int> = PlannerDayHours.window) {
        self.date = date
        self.now = now
        today = DayPlan.dateString(for: now, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        self.dayHours = dayHours
        self.calendar = calendar
    }

    var isToday: Bool { date == today }

    /// The day as it is said against today: today, tomorrow, yesterday, in
    /// 3 days, 2 days ago.
    var relativeDay: String? {
        guard let day = DayPlan.startOfDay(date, calendar: calendar),
              let start = DayPlan.startOfDay(today, calendar: calendar),
              let days = calendar.dateComponents([.day], from: start, to: day).day else { return nil }
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }

    /// The day's name in English, "Thursday".
    var weekday: String? {
        guard let day = DayPlan.startOfDay(date, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }

    /// What nothing in `busy` holds of the learner's day from now (on today)
    /// or from the day's start (ahead), as clock stretches. Pure.
    func freeStretches(busy: [(start: Date, end: Date)]) -> [Range<Int>] {
        guard date >= today, let dayStart = DayPlan.startOfDay(date, calendar: calendar) else { return [] }
        let from = isToday ? max(nowMinute, dayHours.lowerBound * 60) : dayHours.lowerBound * 60
        let to = dayHours.upperBound * 60
        guard to > from else { return [] }
        // Each busy time clipped to what is left of the day; one that ended
        // before now, or starts after the day ends, holds none of it.
        let taken = busy
            .compactMap { interval -> Range<Int>? in
                let start = Int((interval.start.timeIntervalSince(dayStart) / 60).rounded(.down))
                let end = Int((interval.end.timeIntervalSince(dayStart) / 60).rounded(.up))
                let lower = max(from, start)
                let upper = min(to, end)
                return lower < upper ? lower..<upper : nil
            }
            .sorted { $0.lowerBound < $1.lowerBound }
        var free: [Range<Int>] = []
        var cursor = from
        for interval in taken {
            if interval.lowerBound > cursor { free.append(cursor..<interval.lowerBound) }
            cursor = max(cursor, interval.upperBound)
        }
        if cursor < to { free.append(cursor..<to) }
        // A sliver is not time a plan can use.
        return free.filter { $0.count >= 15 }
    }

    /// The payload's clock keys: the day's name and hours on every day; on
    /// today the clock; and, given the day's busy times, the free stretches
    /// left in the learner's day.
    func fields(busy: [(start: Date, end: Date)]?) -> [String: Any] {
        var fields: [String: Any] = [
            "day_starts": DayPlan.clockString(minute: dayHours.lowerBound * 60),
            "day_ends": DayPlan.clockString(minute: dayHours.upperBound * 60),
        ]
        if let weekday { fields["weekday"] = weekday }
        if let relativeDay { fields["relative_day"] = relativeDay }
        if isToday { fields["now"] = DayPlan.clockString(minute: nowMinute) }
        if let busy, date >= today {
            fields[isToday ? "free_from_now" : "free"] = freeStretches(busy: busy).map { stretch -> [String: Any] in
                [
                    "start": DayPlan.clockString(minute: stretch.lowerBound),
                    "end": DayPlan.clockString(minute: stretch.upperBound),
                    "minutes": stretch.count,
                ]
            }
        }
        return fields
    }
}

// MARK: - Settings › General › Day

/// Settings › General › Day, readable and writable from a chat so the pane is
/// never the only place it can be changed (`get_day_settings` /
/// `set_day_settings`): the hours the learner's day runs (synced) and the
/// device-local "Plan your day?" switch. macOS's answer about ForeverLM's
/// notifications rides along (`notifications_status`), because the pane says
/// it under the switch.
extension MCPDataStore {

    @MainActor
    static func daySettingsPayload(notifications: NotificationPermission) -> [String: Any] {
        let window = PlannerDayHours.window
        let morningStart = DayPlan.clockString(minute: window.lowerBound * 60)
        let morningEnd = DayPlan.clockString(minute: PlanTheDay.morningEndMinute(dayHours: window))
        let planningScope = PlanTheDay.isMorning(nowMinute: window.lowerBound * 60, dayHours: window)
            ? "this Mac: each morning, \(morningStart)–\(morningEnd), while today's calendar holds nothing the learner planned (meetings with other people and recurring events do not count), a card asks \"Plan your day?\" in the bottom-left of the Studio window and waits there until answered: Plan in Chat starts the planning conversation, which writes the day into the Mac's Calendar, and the close button means not today. If the learner sits down with ForeverLM not in front, a notification says it once as well."
            : "this Mac: never asked while the learner's day starts at \(morningStart), after the morning it is asked in (until \(morningEnd))."
        return [
            "day_start_hour": window.lowerBound,
            "day_end_hour": window.upperBound,
            "day_hours": "The learner's day runs \(DayPlan.clockString(minute: window.lowerBound * 60))–\(DayPlan.clockString(minute: window.upperBound * 60)): what get_calendar_events counts free time inside, and the hours the Activity pane's clock draws. Follows the account to the learner's other Macs.",
            "suggest_planning_the_day": PlanTheDay.isEnabled,
            "suggest_planning_scope": planningScope,
            "notifications_status": notifications.rawValue,
            "notifications_note": dayNotificationsNote(notifications),
        ]
    }

    /// What `notifications_status` means for the switches beside it, said
    /// for an assistant: the pane says it in one line, with the way out.
    static func dayNotificationsNote(_ permission: NotificationPermission) -> String {
        switch permission {
        case .allowed:
            return "macOS lets ForeverLM notify on this Mac: a bout's two alarms, the memory review reminder and \"Plan your day?\" while ForeverLM is not in front can all reach the learner."
        case .refused:
            return "macOS refuses ForeverLM's notifications on this Mac, so none is shown: a bout's alarms are silent, the memory review reminder never comes, and \"Plan your day?\" is only the card. The switches still read as set. Only the learner can undo it, in ForeverLM's entry in System Settings › Notifications; no tool can."
        case .notAsked:
            return "macOS has not been asked on this Mac. It shows its prompt the first time one of these notifications is due, or now with set_day_settings request_notifications true; only the learner can answer it."
        }
    }

    /// `request_notifications`' answer, from macOS's answer before the call.
    static func notificationRequestAnswer(before permission: NotificationPermission) -> String {
        switch permission {
        case .notAsked:
            return "Asked: macOS is showing its prompt on the learner's Mac and only they can answer it, so tell them to look for it. get_day_settings reads the answer."
        case .refused:
            return "Not asked: macOS refused before, and asking again shows nothing. Only the learner can allow ForeverLM, in System Settings › Notifications."
        case .allowed:
            return "Not asked: macOS already lets ForeverLM notify on this Mac."
        }
    }

    func getDaySettings() async throws -> String {
        let notifications = await NotificationPermission.current()
        return try jsonString(await Self.daySettingsPayload(notifications: notifications))
    }

    func setDaySettings(
        dayStartHour: Int?,
        dayEndHour: Int?,
        suggestPlanningTheDay: Bool? = nil,
        requestNotifications: Bool? = nil
    ) async throws -> String {
        // request_notifications is the pane's Allow Notifications button, not
        // a setting: only true presses it.
        let requestsNotifications = requestNotifications == true
        guard dayStartHour != nil || dayEndHour != nil || suggestPlanningTheDay != nil || requestsNotifications else {
            throw MCPError.invalidInput("Pass at least one of day_start_hour, day_end_hour, suggest_planning_the_day, or request_notifications true.")
        }
        if let message = await MainActor.run(body: { PlannerDayHours.validationMessage(start: dayStartHour, end: dayEndHour) }) {
            throw MCPError.invalidInput(message)
        }
        let changed = await MainActor.run {
            var changed = false
            if let dayStartHour {
                changed = PlannerDayHours.start != dayStartHour || changed
                PlannerDayHours.start = dayStartHour
            }
            if let dayEndHour {
                changed = PlannerDayHours.end != dayEndHour || changed
                PlannerDayHours.end = dayEndHour
            }
            if let suggestPlanningTheDay {
                changed = PlanTheDay.isEnabled != suggestPlanningTheDay || changed
                PlanTheDay.setEnabled(suggestPlanningTheDay)
            }
            return changed
        }
        let notifications = await NotificationPermission.current()
        var requestAnswer: String?
        if requestsNotifications {
            requestAnswer = Self.notificationRequestAnswer(before: notifications)
            if notifications == .notAsked {
                // Not awaited: the prompt waits on the learner, who may not
                // be at the Mac, and the call must not wait with it.
                Task { await NotificationPermission.request() }
            }
        }
        var payload = await Self.daySettingsPayload(notifications: notifications)
        payload["changed"] = changed
        if let requestAnswer { payload["notifications_request"] = requestAnswer }
        return try jsonString(payload)
    }
}
