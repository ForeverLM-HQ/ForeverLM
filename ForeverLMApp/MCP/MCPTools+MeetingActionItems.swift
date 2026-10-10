import Foundation

/// The meeting-series half of the Planner over MCP (planner-design.md, "A
/// meeting series on the clock"): a series' schedule, and the action items
/// read out of its sessions. Writes go through `StorageService` so SQLite,
/// `sync_metadata` and `sync_changes` move together and the Planner pane
/// republishes at once.
extension MCPDataStore {

    func setMeetingSchedule(
        groupID rawGroupID: String,
        weekdays: [Int]?,
        start: String?,
        durationMinutes: Int?,
        timezone: String?,
        clear: Bool
    ) async throws -> String {
        let groupID = rawGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupID.isEmpty else { throw MCPError.invalidInput("group_id is required.") }
        guard let metadata = try knowledgeStore().loadMeetingGroups()[groupID] else {
            throw MCPError.notFound("Meeting group not found: \(groupID). Call list_meeting_groups for current group_id values.")
        }
        let title = metadata.title ?? groupID
        if clear {
            try await notebookFileStorage.setMeetingSchedule(nil, groupID: groupID)
            return try jsonString(["updated": true, "group_id": groupID, "title": title, "schedule": NSNull()] as [String: Any])
        }
        let existing = metadata.schedule
        guard let weekdays = weekdays ?? existing?.weekdays, !weekdays.isEmpty else {
            throw MCPError.invalidInput("weekdays is required: 1 (Sunday) to 7 (Saturday), e.g. [2,3,4,5,6] for weekdays.")
        }
        guard weekdays.allSatisfy(MeetingSchedule.weekdayRange.contains) else {
            throw MCPError.invalidInput("weekdays must be between 1 (Sunday) and 7 (Saturday).")
        }
        let startMinute: Int
        if let start {
            guard let parsed = DayPlan.minute(fromClock: start) else {
                throw MCPError.invalidInput("start must be 24-hour HH:MM.")
            }
            startMinute = parsed
        } else if let existing {
            startMinute = existing.startMinute
        } else {
            throw MCPError.invalidInput("start is required: 24-hour HH:MM in the given time zone.")
        }
        guard let duration = durationMinutes ?? existing?.durationMinutes else {
            throw MCPError.invalidInput("duration_minutes is required.")
        }
        guard duration >= DayPlan.minimumBlockMinutes, startMinute + duration <= DayPlan.minutesPerDay else {
            throw MCPError.invalidInput("duration_minutes must be at least \(DayPlan.minimumBlockMinutes) and the meeting must end by midnight.")
        }
        guard let zone = (timezone ?? existing?.timezone ?? metadata.timezone), !zone.isEmpty else {
            throw MCPError.invalidInput("timezone is required: an IANA zone such as America/Los_Angeles.")
        }
        guard TimeZone(identifier: zone) != nil else {
            throw MCPError.invalidInput("timezone \"\(zone)\" is not an IANA time zone.")
        }
        let schedule = MeetingSchedule(weekdays: weekdays, startMinute: startMinute, durationMinutes: duration, timezone: zone)
        try await notebookFileStorage.setMeetingSchedule(schedule, groupID: groupID)
        return try jsonString([
            "updated": true,
            "group_id": groupID,
            "title": title,
            "schedule": Self.schedulePayload(schedule),
        ] as [String: Any])
    }

    static func schedulePayload(_ schedule: MeetingSchedule) -> [String: Any] {
        [
            "weekdays": schedule.weekdays,
            "start": DayPlan.clockString(minute: schedule.startMinute),
            "end": DayPlan.clockString(minute: schedule.endMinute),
            "duration_minutes": schedule.durationMinutes,
            "timezone": schedule.timezone,
        ]
    }

    func listMeetingActionItems(groupID rawGroupID: String?, sourceID rawSourceID: String?, latestOnly: Bool) async throws -> String {
        let groupID = rawGroupID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = rawSourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (groupID?.isEmpty == false) || (sourceID?.isEmpty == false) else {
            throw MCPError.invalidInput("Pass group_id (from list_meeting_groups) or source_id (one session).")
        }
        let store = try knowledgeStore()
        if let groupID, !groupID.isEmpty, try store.loadMeetingGroups()[groupID] == nil {
            throw MCPError.notFound("Meeting group not found: \(groupID). Call list_meeting_groups for current group_id values.")
        }
        var items = try store.loadMeetingActionItems(
            groupID: groupID?.isEmpty == false ? groupID : nil,
            sourceID: sourceID?.isEmpty == false ? sourceID : nil
        )
        if latestOnly { items = MeetingActionItems.forPlanner(items) }
        var payload: [String: Any] = [
            "action_items": items.map(meetingActionItemPayload),
            "count": items.count,
            "open_count": items.filter { !$0.isDone }.count,
        ]
        if let groupID, !groupID.isEmpty { payload["group_id"] = groupID }
        if let sourceID, !sourceID.isEmpty { payload["source_id"] = sourceID }
        return try jsonString(payload)
    }

    func setMeetingActionItemDone(itemID rawItemID: String, done: Bool) async throws -> String {
        let itemID = rawItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else { throw MCPError.invalidInput("item_id is required.") }
        guard try knowledgeStore().loadMeetingActionItem(itemID) != nil else {
            throw MCPError.notFound("Action item not found: \(itemID). Call list_meeting_action_items for current item_id values.")
        }
        let item = try await notebookFileStorage.setMeetingActionItemDone(itemID, done: done)
        return try jsonString(["updated": true, "action_item": meetingActionItemPayload(item)] as [String: Any])
    }
}
