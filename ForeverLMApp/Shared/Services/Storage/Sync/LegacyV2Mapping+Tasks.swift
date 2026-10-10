import Foundation

// MARK: - Tasks and automations (docs/cloudkit-schema-design.md §10, the `ProjectTask`, `ShareRequest`, `MeetingGroup` and `ScheduledTask` rows)

extension LegacyV2Mapping {
    /// A meeting series' action items as Tasks (`mergeMeetingActionItemsRecord`).
    static func actionItemTasks(_ items: [MeetingActionItem], groupID: String) -> [LegacyV2Record] {
        items.filter { $0.groupID == groupID }.map { item in
            let rows = TaskRows.actionItem(TaskRows.ActionItem(
                id: item.id, groupID: item.groupID, sourceID: item.sourceID, position: item.position, text: item.text,
                owner: item.owner, dueHint: item.dueHint, doneAt: item.doneAt?.timeIntervalSinceReferenceDate,
                createdAt: item.createdAt.timeIntervalSinceReferenceDate
            ))
            return LegacyV2Record(type: .task, id: item.id, fields: TaskProjection.encodeRows(rows), giving: .owns)
        }
    }

    /// An old NotebookTask: its Task, with the order key the activation plans for its board
    /// (`TaskUpkeep.replanBoard`), from the board this Mac holds with this task's place in it.
    static func notebookTask(_ payload: CloudKitNotebookTaskPayload, record: LegacyRecord, context: LegacyMappingContext) throws -> LegacyV2Record {
        let task = payload.task
        let held = try context.boardTasks(notebookID: task.notebookID)
        var board = held.filter { $0.id != task.id }
        let heldKey = held.first { $0.id == task.id }?.orderKey
        board.append(LegacyBoardTask(id: task.id, sortOrder: task.sortOrder, createdAt: task.createdAt.timeIntervalSinceReferenceDate, orderKey: heldKey))
        board.sort { ($0.sortOrder, $0.createdAt, $0.id) < ($1.sortOrder, $1.createdAt, $1.id) }
        let planned = OrderKeyPlanner.plan(board.map { (id: $0.id, key: $0.orderKey) })
        let rows = TaskRows.board(TaskRows.BoardTask(
            id: task.id, notebookID: task.notebookID, title: task.title, notes: task.notes, status: task.status.rawValue,
            assigneeUser: task.assigneeRecordName, assigneeName: task.assigneeDisplayName, dueAt: task.dueAt?.timeIntervalSinceReferenceDate,
            sourceID: task.sourceID, artifactID: task.artifactID, orderKey: planned[task.id] ?? heldKey,
            createdByUser: task.createdByRecordName, createdByName: task.createdByDisplayName,
            createdAt: task.createdAt.timeIntervalSinceReferenceDate, completedAt: task.completedAt?.timeIntervalSinceReferenceDate,
            heldKind: try context.heldTaskKind(task.id)
        ))
        var mapped = LegacyV2Record(type: .task, id: try context.wireID(.task, oldID: task.id, teamID: record.teamID), fields: TaskProjection.encodeRows(rows), giving: .owns)
        // The place on the board is planned against this Mac's held board: a creation's alone (F4).
        mapped.createOnlyFields = ["orderKey"]
        return mapped
    }

    /// An old ShareRequest: its Task.
    static func shareRequest(_ payload: CloudKitShareRequestPayload, record: LegacyRecord, context: LegacyMappingContext) throws -> LegacyV2Record {
        let request = payload.request
        let rows = TaskRows.shareRequest(TaskRows.ShareRequest(
            id: request.id, url: request.url, title: request.title, artifactID: request.artifactID,
            requesterUser: request.requestedByRecordName, requesterName: request.requestedByDisplayName, status: request.status.rawValue,
            resolverUser: request.resolvedByRecordName, resolverName: request.resolvedByDisplayName, fulfilledSourceID: request.fulfilledSourceID,
            createdAt: request.createdAt.timeIntervalSinceReferenceDate, resolvedAt: request.resolvedAt?.timeIntervalSinceReferenceDate
        ))
        return LegacyV2Record(type: .task, id: try context.wireID(.task, oldID: request.id, teamID: record.teamID), fields: TaskProjection.encodeRows(rows), giving: .owns)
    }

    /// The Automation fields an old ScheduledTask never gives: which Mac runs it is generation 2's own
    /// (the first Mac to run it under generation 2 takes it), so an old record never clears it.
    static let automationFieldsNotGiven: Set<String> = ["runnerDeviceID"]

    /// An old ScheduledTask: its Automation, the newest 20 runs in the ring the activation assigns
    /// (`AutomationRing.assignSlots`).
    static func scheduledTask(_ payload: CloudKitScheduledTaskPayload) -> LegacyV2Record {
        let task = payload.task
        let newest = payload.runs.filter { $0.taskID == task.id }
            .sorted { ($0.occurrenceAt, $0.id) > ($1.occurrenceAt, $1.id) }
            .prefix(AutomationRing.size)
        let runs = newest.reversed().enumerated().map { index, run in
            AutomationRows.Run(
                id: run.id, slot: AutomationRing.key(index), occurrenceAt: run.occurrenceAt.timeIntervalSinceReferenceDate,
                status: run.status.rawValue, sessionID: run.sessionID, message: run.message
            )
        }
        let rows = AutomationRows(
            id: task.id, title: task.title, instruction: task.instruction, notebookID: task.notebookID, cadence: task.cadence,
            weekday: task.weekday, dayOfMonth: task.dayOfMonth, hour: task.hour, minute: task.minute, timeZoneID: task.timeZoneID,
            startDate: task.startDate?.timeIntervalSinceReferenceDate, isEnabled: task.isEnabled,
            createdAt: task.createdAt.timeIntervalSinceReferenceDate, runnerDeviceID: nil, runs: runs.sorted { ($0.occurrenceAt, $0.id) < ($1.occurrenceAt, $1.id) }
        )
        var fields = AutomationProjection.encodeRows(rows)
        for field in automationFieldsNotGiven { fields.removeValue(forKey: field) }
        return LegacyV2Record(type: .automation, id: task.id, fields: fields, giving: .owns)
    }
}

/// One task of a board as this Mac holds it, for the order key a changed task takes.
struct LegacyBoardTask: Equatable, Sendable {
    let id: String
    let sortOrder: Double
    let createdAt: Double
    let orderKey: String?
}
