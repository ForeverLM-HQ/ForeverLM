import Foundation

// MARK: - The member's own state per notebook (docs/cloudkit-schema-design.md §3.5.20, §5.6)

/// One `notebook_states` row: the member's chat ticks (each untick as the stamp pair of the Entry it
/// named, D16), the context notebooks they ticked (D52), their Notebook Collections, and their sidebar
/// and course-mode state. Keyed by the notebook's wire id, with no foreign key (D18).
struct NotebookStateRow: Equatable, Sendable {
    var notebookID: String
    var excluded: [String: String] = [:]
    var contextNotebooks: Set<String> = []
    var collections: Set<String> = []
    var sidebarKey: String?
    var pinned: Bool?
    var expanded: Bool?
    var layoutOverride: String?
    var courseID: String?
    var courseOrder: [String: String] = [:]

    /// An untick whose Entry has no stamp this device can name yet (no server offset): it reads as
    /// unticked here and is given its pair once the stamp exists (`resolvePendingUnticks`).
    static let pendingPair = "~pending"

    static func load(_ notebookID: String, connection: SQLiteConnection) throws -> NotebookStateRow? {
        var row: NotebookStateRow?
        try connection.query("""
            SELECT excluded_json, context_notebooks_json, collections_json, sidebar_key, pinned, expanded, layout_override,
                   course_id, course_order_json
            FROM notebook_states WHERE notebook_id = ?
        """, [.text(notebookID)]) { values in
            row = NotebookStateRow(
                notebookID: notebookID, excluded: Self.strings(values.text(0)), contextNotebooks: Set(Self.list(values.text(1))),
                collections: Set(Self.list(values.text(2))), sidebarKey: values.text(3), pinned: values.integer(4).map { $0 != 0 },
                expanded: values.integer(5).map { $0 != 0 }, layoutOverride: values.text(6), courseID: values.text(7),
                courseOrder: Self.strings(values.text(8))
            )
        }
        return row
    }

    /// Writes the row whole (an upsert, so the outbox records only the columns that changed).
    func save(_ connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO notebook_states (notebook_id, excluded_json, context_notebooks_json, collections_json, sidebar_key, pinned,
                                         expanded, layout_override, course_id, course_order_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(notebook_id) DO UPDATE SET
                excluded_json = excluded.excluded_json, context_notebooks_json = excluded.context_notebooks_json,
                collections_json = excluded.collections_json, sidebar_key = excluded.sidebar_key, pinned = excluded.pinned,
                expanded = excluded.expanded, layout_override = excluded.layout_override, course_id = excluded.course_id,
                course_order_json = excluded.course_order_json
        """, [
            .text(notebookID), .text(Self.json(excluded)), .text(Self.json(contextNotebooks)), .text(Self.json(collections)),
            .text(sidebarKey), .integer(pinned.map { $0 ? 1 : 0 }), .integer(expanded.map { $0 ? 1 : 0 }), .text(layoutOverride),
            .text(courseID), .text(Self.json(courseOrder)),
        ])
    }

    /// A set as stored: a sorted JSON array, NULL when empty.
    static func json(_ members: Set<String>) -> String? {
        members.isEmpty ? nil : String(decoding: SyncJSON.array(members.sorted().map(SyncJSON.string)).serialized(), as: UTF8.self)
    }

    /// A map as stored: a JSON object, NULL when empty.
    static func json(_ map: [String: String]) -> String? {
        map.isEmpty ? nil : String(decoding: SyncJSON.object(map.mapValues(SyncJSON.string)).serialized(), as: UTF8.self)
    }

    static func list(_ text: String?) -> [String] {
        (text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.arrayValue ?? []).compactMap(\.stringValue)
    }

    static func strings(_ text: String?) -> [String: String] {
        (text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
}

/// The NotebookState record's projection (§3.5.20): private to the member, created on their first
/// real change (opening a notebook writes nothing), and never deleted because its notebook went.
struct NotebookStateProjection: RecordProjection {
    var recordType: SyncRecordType { .notebookState }

    static let columns = [
        "excluded_json", "context_notebooks_json", "collections_json", "sidebar_key", "pinned", "expanded", "layout_override",
        "course_id", "course_order_json",
    ]

    var tables: [ProjectedTable] {
        let recordIDSQL: @Sendable (String) -> String = { "'ns:' || \($0).notebook_id" }
        return [ProjectedTable(
            "notebook_states", localKey: ["notebook_id"], keyColumns: ["notebook_id"], syncedColumns: Self.columns,
            recordTypes: [.notebookState],
            record: { values in
                values["notebook_id"]?.textValue.map {
                    let id = SyncIdentity.notebookStateID(notebookID: $0)
                    return RowRecord(type: .notebookState, localID: id, personalID: id)
                }
            },
            localIDSQL: recordIDSQL, personalIDSQL: recordIDSQL
        )]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "notebook_states", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "notebookID": .rowExistence(table: "notebook_states"), "excluded": Self.column("excluded_json"),
            "contextNotebooks": Self.column("context_notebooks_json"), "collections": Self.column("collections_json"),
            "sidebarKey": Self.column("sidebar_key"), "pinned": Self.column("pinned"), "expanded": Self.column("expanded"),
            "layoutOverride": Self.column("layout_override"), "courseID": Self.column("course_id"),
            "courseOrder": Self.column("course_order_json"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    static func notebookID(ofRecord wireID: String) -> String {
        wireID.hasPrefix("ns:") ? String(wireID.dropFirst(3)) : wireID
    }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> NotebookStateRow? {
        try NotebookStateRow.load(Self.notebookID(ofRecord: record.wireID), connection: connection)
    }

    static func encodeRows(_ row: NotebookStateRow) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "notebookID": .string(row.notebookID),
            "contextNotebooks": .object(Dictionary(row.contextNotebooks.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
            "collections": .object(Dictionary(row.collections.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
            "courseOrder": .object(row.courseOrder.mapValues(SyncJSON.string)),
            "sidebarKey": row.sidebarKey.map(SyncJSON.string) ?? .null,
            "pinned": row.pinned.map(SyncJSON.bool) ?? .null,
            "expanded": row.expanded.map(SyncJSON.bool) ?? .null,
            "layoutOverride": row.layoutOverride.map(SyncJSON.string) ?? .null,
            "courseID": row.courseID.map(SyncJSON.string) ?? .null,
        ]
        // An untick still waiting for its Entry's stamp holds the whole map back: no element of it is
        // sent until every pair can be named.
        if !row.excluded.values.contains(NotebookStateRow.pendingPair) {
            fields["excluded"] = .object(row.excluded.mapValues(SyncJSON.string))
        }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let notebookID = fields["notebookID"]?.stringValue ?? Self.notebookID(ofRecord: record.wireID)
        var row = try NotebookStateRow.load(notebookID, connection: connection) ?? NotebookStateRow(notebookID: notebookID)
        func members(_ field: String) -> Set<String>? {
            fields[field]?.objectValue.map { Set($0.compactMap { $0.value.boolValue == true ? $0.key : nil }) }
        }
        if let excluded = fields["excluded"]?.objectValue {
            // A pair this device is still waiting to name stays until it can.
            let waiting = row.excluded.filter { $0.value == NotebookStateRow.pendingPair }
            row.excluded = excluded.compactMapValues(\.stringValue).merging(waiting) { held, _ in held }
        }
        if let set = members("contextNotebooks") { row.contextNotebooks = set }
        if let set = members("collections") { row.collections = set }
        if let order = fields["courseOrder"]?.objectValue { row.courseOrder = order.compactMapValues(\.stringValue) }
        if let value = fields["sidebarKey"] { row.sidebarKey = value.stringValue }
        if let value = fields["pinned"] { row.pinned = value.boolValue }
        if let value = fields["expanded"] { row.expanded = value.boolValue }
        if let value = fields["layoutOverride"] { row.layoutOverride = value.stringValue }
        if let value = fields["courseID"] { row.courseID = value.stringValue }
        try row.save(connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM notebook_states WHERE notebook_id = ?", [.text(Self.notebookID(ofRecord: record.wireID))])
    }
}
