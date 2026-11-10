import Foundation

// MARK: - Tasks: a notebook's board, a team's share requests, a meeting's action items (§3.5.27)

/// The local rows one Task record is encoded from: the three tables that stay the local truth
/// (§12.7 v162), one row each. A Task's id is the row's own id in whichever table holds it.
enum TaskRows: Equatable, Sendable {
    /// A notebook's to-do or a family assignment (`notebook_tasks`).
    case board(BoardTask)
    /// A member's request that a cited source be shared into the team (`share_requests`).
    case shareRequest(ShareRequest)
    /// What a meeting session's transcript asked someone to do (`meeting_action_items`).
    case actionItem(ActionItem)

    struct BoardTask: Equatable, Sendable {
        var id: String
        var notebookID: String
        var title: String
        var notes: String
        var status: String
        var assigneeUser: String?
        var assigneeName: String?
        var dueAt: Double?
        var sourceID: String?
        var artifactID: String?
        var orderKey: String?
        var createdByUser: String?
        var createdByName: String?
        var createdAt: Double
        var completedAt: Double?
        /// The kind the record already holds: `kind` is first-writer (S), so a later assignee never
        /// turns a to-do into an assignment.
        var heldKind: String?
    }

    struct ShareRequest: Equatable, Sendable {
        var id: String
        var url: String
        var title: String?
        var artifactID: String?
        var requesterUser: String?
        var requesterName: String?
        var status: String
        var resolverUser: String?
        var resolverName: String?
        var fulfilledSourceID: String?
        var createdAt: Double
        var resolvedAt: Double?
    }

    struct ActionItem: Equatable, Sendable {
        var id: String
        var groupID: String
        var sourceID: String
        var position: Int
        var text: String
        var owner: String?
        var dueHint: String?
        var doneAt: Double?
        var createdAt: Double
    }
}

/// The Task record's projection (§3.5.27). A team's tasks and share requests live in the space their
/// team becomes (their `ck_identity` rows, `TaskUpkeep.recordTeamIdentities`), so the feeder holds them
/// until WP15 gives the space a root; a Task arriving in a space is kept in the replica, unprojected,
/// for WP15. Share requests live only in team spaces, so in `Library` the projection writes none.
struct TaskProjection: RecordProjection {
    var recordType: SyncRecordType { .task }

    static let boardColumns = [
        "notebook_id", "title", "notes", "status", "assignee_record_name", "assignee_display_name", "due_at", "source_id",
        "artifact_id", "order_key", "created_by_record_name", "created_by_display_name", "created_at", "completed_at",
    ]
    static let shareRequestColumns = [
        "url", "title", "artifact_id", "requested_by_record_name", "requested_by_display_name", "status",
        "resolved_by_record_name", "resolved_by_display_name", "fulfilled_source_id", "created_at", "resolved_at",
    ]
    static let actionItemColumns = ["group_id", "source_id", "position", "text", "owner", "due_hint", "done_at", "created_at"]

    var tables: [ProjectedTable] {
        [
            .records("notebook_tasks", type: .task, syncedColumns: Self.boardColumns),
            .records("share_requests", type: .task, syncedColumns: Self.shareRequestColumns),
            .records("meeting_action_items", type: .task, syncedColumns: Self.actionItemColumns),
        ]
    }

    private static func feed(board: [String] = [], request: [String] = [], item: [String] = []) -> FieldFeed {
        .anyOf([
            board.isEmpty ? nil : FieldFeed.columns(table: "notebook_tasks", board),
            request.isEmpty ? nil : FieldFeed.columns(table: "share_requests", request),
            item.isEmpty ? nil : FieldFeed.columns(table: "meeting_action_items", item),
        ].compactMap { $0 })
    }

    var feeds: [String: FieldFeed] {
        [
            "kind": .anyOf([.rowExistence(table: "notebook_tasks"), .rowExistence(table: "share_requests"), .rowExistence(table: "meeting_action_items")]),
            "notebookID": Self.feed(board: ["notebook_id"]),
            "title": Self.feed(board: ["title"], request: ["title", "url"], item: ["text"]),
            "notes": Self.feed(board: ["notes"], item: ["owner", "due_hint"]),
            "status": Self.feed(board: ["status"], request: ["status"], item: ["done_at"]),
            "assignee": Self.feed(board: ["assignee_record_name", "assignee_display_name"]),
            "requester": Self.feed(request: ["requested_by_record_name", "requested_by_display_name"]),
            "dueAt": Self.feed(board: ["due_at"]),
            "about": Self.feed(board: ["source_id", "artifact_id"], request: ["url", "artifact_id"], item: ["group_id"]),
            "meetingSourceID": Self.feed(item: ["source_id"]),
            "fulfilledSourceID": Self.feed(request: ["fulfilled_source_id"]),
            "orderKey": Self.feed(board: ["order_key"], item: ["position"]),
            "createdAt": Self.feed(board: ["created_at"], request: ["created_at"], item: ["created_at"]),
            "createdBy": Self.feed(board: ["created_by_record_name", "created_by_display_name"], request: ["requested_by_record_name", "requested_by_display_name"]),
            "resolvedAt": Self.feed(board: ["completed_at"], request: ["resolved_at"], item: ["done_at"]),
            "resolvedBy": Self.feed(request: ["resolved_by_record_name", "resolved_by_display_name"]),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }

    // MARK: Reading the rows

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> TaskRows? {
        let id = record.localID
        var rows: TaskRows?
        try connection.query("""
            SELECT notebook_id, title, notes, status, assignee_record_name, assignee_display_name, due_at, source_id, artifact_id,
                   order_key, created_by_record_name, created_by_display_name, created_at, completed_at
            FROM notebook_tasks WHERE id = ?
        """, [.text(id)]) { row in
            rows = .board(TaskRows.BoardTask(
                id: id, notebookID: row.text(0) ?? "", title: row.text(1) ?? "", notes: row.text(2) ?? "", status: row.text(3) ?? "todo",
                assigneeUser: row.text(4), assigneeName: row.text(5), dueAt: row.real(6), sourceID: row.text(7), artifactID: row.text(8),
                orderKey: row.text(9), createdByUser: row.text(10), createdByName: row.text(11), createdAt: row.real(12) ?? 0,
                completedAt: row.real(13)
            ))
        }
        if case .board(var task)? = rows {
            task.heldKind = try ReplicaStore(connection: connection).record(zoneKey: record.zoneKey, recordType: SyncRecordType.task.rawValue, wireID: record.wireID)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }?.fields["kind"]?.stringValue
            return .board(task)
        }
        try connection.query("""
            SELECT url, title, artifact_id, requested_by_record_name, requested_by_display_name, status, resolved_by_record_name,
                   resolved_by_display_name, fulfilled_source_id, created_at, resolved_at
            FROM share_requests WHERE id = ?
        """, [.text(id)]) { row in
            rows = .shareRequest(TaskRows.ShareRequest(
                id: id, url: row.text(0) ?? "", title: row.text(1), artifactID: row.text(2), requesterUser: row.text(3),
                requesterName: row.text(4), status: row.text(5) ?? "open", resolverUser: row.text(6), resolverName: row.text(7),
                fulfilledSourceID: row.text(8), createdAt: row.real(9) ?? 0, resolvedAt: row.real(10)
            ))
        }
        if rows != nil { return rows }
        try connection.query("""
            SELECT group_id, source_id, position, text, owner, due_hint, done_at, created_at FROM meeting_action_items WHERE id = ?
        """, [.text(id)]) { row in
            rows = .actionItem(TaskRows.ActionItem(
                id: id, groupID: row.text(0) ?? "", sourceID: row.text(1) ?? "", position: Int(row.integer(2) ?? 0), text: row.text(3) ?? "",
                owner: row.text(4), dueHint: row.text(5), doneAt: row.real(6), createdAt: row.real(7) ?? 0
            ))
        }
        return rows
    }

    // MARK: Encoding

    static func encodeRows(_ rows: TaskRows) -> [String: SyncJSON] {
        switch rows {
        case .board(let task):
            var fields: [String: SyncJSON] = [
                "kind": .string(task.heldKind ?? (task.assigneeUser.map { !$0.isEmpty } == true ? "assignment" : "todo")),
                "notebookID": .string(task.notebookID),
                "title": .string(task.title),
                "notes": .string(task.notes),
                "status": .string(task.status),
                "assignee": person(task.assigneeUser, task.assigneeName),
                "dueAt": milliseconds(task.dueAt),
                "about": task.sourceID.map { .object(["ref": .string(ItemRef(.source, $0).rawValue)]) }
                    ?? task.artifactID.map { .object(["ref": .string(ItemRef(.artifact, $0).rawValue)]) } ?? .null,
                "createdAt": milliseconds(task.createdAt),
                "resolvedAt": task.status == "done" ? milliseconds(task.completedAt) : .null,
            ]
            if let key = task.orderKey { fields["orderKey"] = .string(key) }
            if let user = task.createdByUser, !user.isEmpty { fields["createdBy"] = person(user, task.createdByName) }
            return fields

        case .shareRequest(let request):
            var about: [String: SyncJSON] = ["url": .string(request.url)]
            if let artifact = request.artifactID { about["ref"] = .string(ItemRef(.artifact, artifact).rawValue) }
            var fields: [String: SyncJSON] = [
                "kind": .string("shareRequest"),
                "title": .string(request.title.flatMap { $0.isEmpty ? nil : $0 } ?? request.url),
                "status": .string(request.status == "open" ? "todo" : request.status),
                "about": .object(about),
                "fulfilledSourceID": request.fulfilledSourceID.map(SyncJSON.string) ?? .null,
                "resolvedBy": person(request.resolverUser, request.resolverName),
                "createdAt": milliseconds(request.createdAt),
                "resolvedAt": milliseconds(request.resolvedAt),
            ]
            if let user = request.requesterUser, !user.isEmpty {
                fields["requester"] = person(user, request.requesterName)
                fields["createdBy"] = person(user, request.requesterName)
            }
            return fields

        case .actionItem(let item):
            var fields: [String: SyncJSON] = [
                "kind": .string("actionItem"),
                "title": .string(item.text),
                "notes": ActionItemNotes.text(owner: item.owner, dueHint: item.dueHint).map(SyncJSON.string) ?? .null,
                "status": .string(item.doneAt == nil ? "todo" : "done"),
                "about": .object(["ref": .string(ItemRef(.collection, item.groupID).rawValue)]),
                "meetingSourceID": .string(item.sourceID),
                "createdAt": milliseconds(item.createdAt),
                "resolvedAt": milliseconds(item.doneAt),
            ]
            if let key = SourceOrderKeys.key(forIndex: Int64(item.position)) { fields["orderKey"] = .string(key) }
            return fields
        }
    }

    private static func person(_ user: String?, _ name: String?) -> SyncJSON {
        guard let user, !user.isEmpty else { return .null }
        return SyncPerson(user: user, name: name ?? "").value
    }

    private static func milliseconds(_ cocoaSeconds: Double?) -> SyncJSON {
        cocoaSeconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } ?? .null
    }

    // MARK: Applying

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let existing = try loadRows(record, connection: connection)
        let kind = fields["kind"]?.stringValue ?? {
            switch existing {
            case .shareRequest?: return "shareRequest"
            case .actionItem?: return "actionItem"
            default: return "todo"
            }
        }()
        switch kind {
        case "actionItem":
            try applyActionItem(fields, id: record.localID, existing: existing, connection: connection)
        case "shareRequest":
            // A share request lives in its team's space; one in `Library` has no team to belong to.
            break
        default:
            try applyBoardTask(fields, id: record.localID, existing: existing, connection: connection)
        }
        return .projected
    }

    private static func seconds(_ value: SyncJSON?) -> Double? {
        value?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
    }

    private func applyBoardTask(_ fields: [String: SyncJSON], id: String, existing: TaskRows?, connection: SQLiteConnection) throws {
        var task: TaskRows.BoardTask
        if case .board(let held)? = existing {
            task = held
        } else {
            guard let notebook = fields["notebookID"]?.stringValue else { return }
            task = TaskRows.BoardTask(id: id, notebookID: notebook, title: "", notes: "", status: "todo", createdAt: Date().timeIntervalSinceReferenceDate)
        }
        if let notebook = fields["notebookID"]?.stringValue { task.notebookID = notebook }
        if let title = fields["title"]?.stringValue { task.title = title }
        if let notes = fields["notes"] { task.notes = notes.stringValue ?? "" }
        if let status = fields["status"]?.stringValue {
            task.status = NotebookTaskStatus(rawValue: status)?.rawValue ?? "todo"
        }
        if let assignee = fields["assignee"] {
            let person = SyncPerson(json: assignee)
            task.assigneeUser = person?.user
            task.assigneeName = person?.name
        }
        if let due = fields["dueAt"] { task.dueAt = Self.seconds(due) }
        if let about = fields["about"] {
            let ref = about["ref"]?.stringValue.flatMap(ItemRef.init)
            task.sourceID = ref?.kind == .source ? ref?.id : nil
            task.artifactID = ref?.kind == .artifact ? ref?.id : nil
        }
        if let key = fields["orderKey"] { task.orderKey = key.stringValue }
        if let creator = fields["createdBy"].flatMap(SyncPerson.init(json:)) {
            task.createdByUser = creator.user
            task.createdByName = creator.name
        }
        if let created = Self.seconds(fields["createdAt"]) { task.createdAt = created }
        if fields["resolvedAt"] != nil || fields["status"] != nil {
            task.completedAt = task.status == "done" ? (Self.seconds(fields["resolvedAt"]) ?? task.completedAt ?? task.createdAt) : nil
        }
        let updated = max(task.completedAt ?? 0, task.createdAt)
        try connection.execute("""
            INSERT INTO notebook_tasks (id, notebook_id, title, notes, status, assignee_record_name, assignee_display_name, due_at, source_id,
                artifact_id, sort_order, created_by_record_name, created_by_display_name, created_at, updated_at, completed_at, order_key)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                (SELECT COUNT(*) FROM notebook_tasks WHERE notebook_id = ?2), ?11, ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT(id) DO UPDATE SET
                notebook_id = excluded.notebook_id, title = excluded.title, notes = excluded.notes, status = excluded.status,
                assignee_record_name = excluded.assignee_record_name, assignee_display_name = excluded.assignee_display_name,
                due_at = excluded.due_at, source_id = excluded.source_id, artifact_id = excluded.artifact_id,
                created_by_record_name = excluded.created_by_record_name, created_by_display_name = excluded.created_by_display_name,
                created_at = excluded.created_at, updated_at = MAX(notebook_tasks.updated_at, excluded.updated_at),
                completed_at = excluded.completed_at, order_key = excluded.order_key
        """, [
            .text(id), .text(task.notebookID), .text(task.title), .text(task.notes), .text(task.status), .text(task.assigneeUser),
            .text(task.assigneeName), .real(task.dueAt), .text(task.sourceID), .text(task.artifactID), .text(task.createdByUser),
            .text(task.createdByName), .real(task.createdAt), .real(updated), .real(task.completedAt), .text(task.orderKey),
        ])
        // Generation 1's readers order the board by `sort_order`: each row's rank in key order.
        try TaskUpkeep.deriveSortOrder(notebookID: task.notebookID, connection: connection)
    }

    private func applyActionItem(_ fields: [String: SyncJSON], id: String, existing: TaskRows?, connection: SQLiteConnection) throws {
        var item: TaskRows.ActionItem
        if case .actionItem(let held)? = existing {
            item = held
        } else {
            guard let source = fields["meetingSourceID"]?.stringValue,
                  let group = fields["about"]?["ref"]?.stringValue.flatMap(ItemRef.init), group.kind == .collection
            else { return }
            item = TaskRows.ActionItem(id: id, groupID: group.id, sourceID: source, position: 0, text: "",
                                       createdAt: Date().timeIntervalSinceReferenceDate)
            if let suffix = id.split(separator: "#").last.flatMap({ Int($0) }) { item.position = suffix }
        }
        if let title = fields["title"]?.stringValue { item.text = title }
        if let notes = fields["notes"] {
            (item.owner, item.dueHint) = ActionItemNotes.parse(notes.stringValue)
        }
        if let key = fields["orderKey"]?.stringValue, let index = SourceOrderKeys.index(ofKey: key) { item.position = Int(index) }
        if let created = Self.seconds(fields["createdAt"]) { item.createdAt = created }
        if let status = fields["status"]?.stringValue {
            item.doneAt = status == "done" ? (Self.seconds(fields["resolvedAt"]) ?? item.doneAt ?? Date().timeIntervalSinceReferenceDate) : nil
        }
        try connection.execute("""
            INSERT INTO meeting_action_items (id, group_id, source_id, position, text, owner, due_hint, done_at, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
            ON CONFLICT(id) DO UPDATE SET
                group_id = excluded.group_id, source_id = excluded.source_id, position = excluded.position, text = excluded.text,
                owner = excluded.owner, due_hint = excluded.due_hint, done_at = excluded.done_at, created_at = excluded.created_at
        """, [
            .text(id), .text(item.groupID), .text(item.sourceID), .integer(Int64(item.position)), .text(item.text), .text(item.owner),
            .text(item.dueHint), .real(item.doneAt), .real(item.createdAt),
        ])
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        for table in ["notebook_tasks", "share_requests", "meeting_action_items"] {
            try connection.execute("DELETE FROM \(table) WHERE id = ?", [.text(record.localID)])
        }
    }
}

/// An action item's owner and due hint as the Task's `notes` (§3.5.27 has no field for either: the
/// owner is a name the transcript said, not a member), one line each, so every client shows them and
/// the Mac reads them back.
enum ActionItemNotes {
    static let ownerPrefix = "Owner: "
    static let duePrefix = "Due: "

    static func text(owner: String?, dueHint: String?) -> String? {
        let lines = [owner.flatMap { $0.isEmpty ? nil : ownerPrefix + $0 }, dueHint.flatMap { $0.isEmpty ? nil : duePrefix + $0 }].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func parse(_ notes: String?) -> (owner: String?, dueHint: String?) {
        var owner: String?
        var due: String?
        for line in (notes ?? "").split(separator: "\n").map(String.init) {
            if line.hasPrefix(ownerPrefix) { owner = String(line.dropFirst(ownerPrefix.count)) }
            if line.hasPrefix(duePrefix) { due = String(line.dropFirst(duePrefix.count)) }
        }
        return (owner, due)
    }
}

/// The task rows' generation-2 columns, kept from what generation 1 wrote (`keepTaskRowsForGeneration2`)
/// and derived once at the activation (`tasksActivationDerivations`): both give the same result.
enum TaskUpkeep {
    /// Keys a notebook's board in the order generation 1 shows it (`sort_order`, then when each was made),
    /// changing only the keys out of that order.
    static func replanBoard(notebookID: String, connection: SQLiteConnection) throws {
        var ordered: [(id: String, key: String?)] = []
        try connection.query("""
            SELECT id, order_key FROM notebook_tasks WHERE notebook_id = ? ORDER BY sort_order, created_at, id
        """, [.text(notebookID)]) { row in
            if let id = row.text(0) { ordered.append((id, row.text(1))) }
        }
        for (id, key) in OrderKeyPlanner.plan(ordered).sorted(by: { $0.key < $1.key }) {
            try connection.execute("UPDATE notebook_tasks SET order_key = ? WHERE id = ?", [.text(key), .text(id)])
        }
    }

    /// `sort_order` as each row's rank in key order, so generation 1's board shows the synced order. A
    /// row with no key keeps its place after the keyed ones.
    static func deriveSortOrder(notebookID: String, connection: SQLiteConnection) throws {
        try connection.execute("""
            UPDATE notebook_tasks SET sort_order = (
                SELECT COUNT(*) FROM notebook_tasks AS other
                WHERE other.notebook_id = notebook_tasks.notebook_id AND other.order_key IS NOT NULL
                  AND (other.order_key < notebook_tasks.order_key OR (other.order_key = notebook_tasks.order_key AND other.id < notebook_tasks.id))
            )
            WHERE notebook_id = ? AND order_key IS NOT NULL
              AND sort_order IS NOT (
                SELECT COUNT(*) FROM notebook_tasks AS other
                WHERE other.notebook_id = notebook_tasks.notebook_id AND other.order_key IS NOT NULL
                  AND (other.order_key < notebook_tasks.order_key OR (other.order_key = notebook_tasks.order_key AND other.id < notebook_tasks.id))
              )
        """, [.text(notebookID)])
    }

    /// A team's tasks and every share request live in the space their team becomes (§13.7, WP15): each
    /// gets its `ck_identity` row in that zone, as the team's notebook did (`deriveWireIDs`), so the feeder
    /// holds their changes until the space has a root instead of sending them into `Library`.
    static func recordTeamIdentities(teamZones: [String: String], connection: SQLiteConnection, ids: [String]? = nil) throws {
        var rows: [(id: String, team: String)] = []
        let filter = ids.map { "AND id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ", ")))" } ?? ""
        let parameters = (ids ?? []).map(SQLiteValue.text)
        for table in ["notebook_tasks", "share_requests"] {
            try connection.query("SELECT id, team_id FROM \(table) WHERE team_id IS NOT NULL \(filter)", parameters) { row in
                if let id = row.text(0), let team = row.text(1) { rows.append((id, team)) }
            }
        }
        for row in rows {
            guard let zone = teamZones[row.team] else { continue }
            try connection.execute("""
                INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
                ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
            """, [.text(zone), .text(SyncRecordType.task.rawValue), .text(row.id), .text(row.id)])
        }
    }
}

extension KnowledgeStore {
    /// After a write to a board task or a share request: the board gets its keys (only the rows out of
    /// order take new ones), and a team's row its `ck_identity` row. Runs inside the writer's
    /// transaction.
    func keepTaskRowsForGeneration2(notebookIDs: [String], taskIDs: [String]) throws {
        for notebook in Set(notebookIDs).sorted() {
            try TaskUpkeep.replanBoard(notebookID: notebook, connection: self)
        }
        guard !taskIDs.isEmpty else { return }
        try TaskUpkeep.recordTeamIdentities(teamZones: try teamZoneKeys(), connection: self, ids: taskIDs)
    }
}
