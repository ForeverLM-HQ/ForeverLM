import Foundation

// MARK: - A source's place on the Schedule (docs/cloudkit-schema-design.md §3.5.21)

/// One placement as the Schedule's tables hold it: the `scheduled_sources` row (one per source) and the
/// goals it serves (`scheduled_source_goals`). Under generation 2 the row's id is the record's,
/// `pl:<source wire id>`, and `source_id` the source's wire id, so one local row feeds one record
/// (D18); the activation re-keys generation 1's rows. Times are Cocoa seconds; `planned_at` is the day's
/// local midnight plus the order within the day in seconds (`learningGoalItemPlannedDate`).
struct PlacementRows: Equatable, Sendable {
    var id: String
    var sourceID: String
    var plannedAt: Double
    var addedAt: Double
    var completedAt: Double?
    var isAutomatic: Bool
    var goalIDs: Set<String>

    static func load(_ id: String, connection: SQLiteConnection) throws -> PlacementRows? {
        var rows: PlacementRows?
        try connection.query(
            "SELECT source_id, planned_at, added_at, completed_at, is_automatic FROM scheduled_sources WHERE id = ?", [.text(id)]
        ) { row in
            rows = PlacementRows(
                id: id, sourceID: row.text(0) ?? "", plannedAt: row.real(1) ?? 0, addedAt: row.real(2) ?? 0, completedAt: row.real(3),
                isAutomatic: (row.integer(4) ?? 0) != 0, goalIDs: []
            )
        }
        guard var found = rows else { return nil }
        try connection.query("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ?", [.text(id)]) { row in
            if let goal = row.text(0) { found.goalIDs.insert(goal) }
        }
        return found
    }
}

/// The day and the order within it a placement is planned at, as the wire names them: a calendar day in
/// the learner's time zone, and the fractional key of the order (`SourceOrderKeys`: the n-th key for n
/// seconds past midnight, so keys sort as the Mac's offsets do).
enum PlacementDay {
    static func day(cocoaSeconds: Double, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSinceReferenceDate: cocoaSeconds))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func offset(cocoaSeconds: Double, calendar: Calendar = .current) -> Int64 {
        let date = Date(timeIntervalSinceReferenceDate: cocoaSeconds)
        return Int64(max(0, min(86_399, date.timeIntervalSince(calendar.startOfDay(for: date)).rounded(.down))))
    }

    /// The local midnight of a `YYYY-MM-DD` day.
    static func start(of day: String, calendar: Calendar = .current) -> Double? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return calendar.startOfDay(for: date).timeIntervalSinceReferenceDate
    }

    static func orderKey(offset: Int64) -> String? { SourceOrderKeys.key(forIndex: offset) }
}

/// The Placement record's projection (§3.5.21): one per source, private to the member, never deleted
/// (a source taken off the Schedule is `state = removed`) and never touched because its source went.
/// `origin` is `automatic` for a placement the Schedule made itself, else `manual`.
struct PlacementProjection: RecordProjection {
    var recordType: SyncRecordType { .placement }

    static let columns = ["source_id", "planned_at", "added_at", "completed_at", "is_automatic"]

    var tables: [ProjectedTable] {
        [
            ProjectedTable(
                "scheduled_sources", localKey: ["id"], keyColumns: ["id"], syncedColumns: Self.columns, recordTypes: [.placement],
                record: { values in Self.record(values["id"]) },
                localIDSQL: { "\($0).id" }, personalIDSQL: { "\($0).id" }
            ),
            ProjectedTable(
                "scheduled_source_goals", localKey: ["scheduled_source_id", "goal_id"], keyColumns: ["scheduled_source_id"],
                syncedColumns: [], elementColumn: "goal_id", recordTypes: [.placement],
                record: { values in Self.record(values["scheduled_source_id"]) },
                localIDSQL: { "\($0).scheduled_source_id" }, personalIDSQL: { "\($0).scheduled_source_id" }
            ),
        ]
    }

    /// A row's record: a placement keyed by its record id. A row generation 1 keyed otherwise feeds none.
    private static func record(_ value: SQLiteValue?) -> RowRecord? {
        guard let id = value?.textValue, id.hasPrefix("pl:") else { return nil }
        return RowRecord(type: .placement, localID: id, personalID: id)
    }

    private static func column(_ names: String...) -> FieldFeed { .columns(table: "scheduled_sources", names) }

    var feeds: [String: FieldFeed] {
        [
            "sourceID": Self.column("source_id"), "state": .rowExistence(table: "scheduled_sources"),
            "day": Self.column("planned_at"), "orderKey": Self.column("planned_at"),
            "goalIDs": .elementRows(table: "scheduled_source_goals"), "origin": Self.column("is_automatic"),
            "completedAt": Self.column("completed_at"), "addedAt": Self.column("added_at"),
        ]
    }

    var missingRow: MissingRowOutcome { .fields(["state": .string("removed")]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> PlacementRows? {
        try PlacementRows.load(record.wireID, connection: connection)
    }

    static func encodeRows(_ rows: PlacementRows) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "sourceID": .string(rows.sourceID),
            "state": .string("active"),
            "day": .string(PlacementDay.day(cocoaSeconds: rows.plannedAt)),
            "goalIDs": .object(Dictionary(rows.goalIDs.map { ($0, SyncJSON.bool(true)) }, uniquingKeysWith: { first, _ in first })),
            "origin": .string(rows.isAutomatic ? "automatic" : "manual"),
            "completedAt": rows.completedAt.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } ?? .null,
            "addedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.addedAt)),
        ]
        if let key = PlacementDay.orderKey(offset: PlacementDay.offset(cocoaSeconds: rows.plannedAt)) { fields["orderKey"] = .string(key) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let id = record.wireID
        let fields = envelope.fields
        if fields["state"]?.stringValue == "removed" {
            try connection.execute("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?", [.text(id)])
            try connection.execute("DELETE FROM scheduled_sources WHERE id = ?", [.text(id)])
            return .projected
        }
        let held = try PlacementRows.load(id, connection: connection)
        let now = Date().timeIntervalSinceReferenceDate
        let sourceID = fields["sourceID"]?.stringValue ?? held?.sourceID ?? String(id.dropFirst(3))
        // A row generation 1 keyed otherwise for the same source takes this record's id, goals and all.
        if held == nil, let other = try connection.scalarText("SELECT id FROM scheduled_sources WHERE source_id = ? AND id <> ?", [.text(sourceID), .text(id)]) {
            try KnowledgeStore.rekeyPlacement(from: other, to: id, connection: connection)
        }
        var plannedAt = held?.plannedAt ?? now
        if let day = fields["day"]?.stringValue, let start = PlacementDay.start(of: day) {
            let keyOffset = fields["orderKey"]?.stringValue.flatMap(SourceOrderKeys.index(ofKey:))
            let heldOffset = held.flatMap { PlacementDay.day(cocoaSeconds: $0.plannedAt) == day ? PlacementDay.offset(cocoaSeconds: $0.plannedAt) : nil }
            plannedAt = start + Double(min(max(keyOffset ?? heldOffset ?? 0, 0), 86_399))
        }
        let added = fields["addedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? held?.addedAt ?? now
        let completed: Double? = fields["completedAt"].map { $0.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } } ?? held?.completedAt
        let automatic = fields["origin"].map { $0.stringValue == "automatic" } ?? held?.isAutomatic ?? false
        try connection.execute("""
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at, is_automatic)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id, planned_at = excluded.planned_at, added_at = excluded.added_at,
                completed_at = excluded.completed_at, updated_at = excluded.updated_at, is_automatic = excluded.is_automatic
        """, [.text(id), .text(sourceID), .real(plannedAt), .real(added), .real(completed), .real(now), .real(now), .integer(automatic ? 1 : 0)])
        if let goals = fields["goalIDs"]?.objectValue {
            for (goal, member) in goals {
                if member.boolValue == true {
                    try connection.execute("""
                        INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES (?, ?, ?)
                        ON CONFLICT(scheduled_source_id, goal_id) DO NOTHING
                    """, [.text(id), .text(goal), .real(now)])
                } else {
                    try connection.execute("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ? AND goal_id = ?", [.text(id), .text(goal)])
                }
            }
        }
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?", [.text(record.wireID)])
        try connection.execute("DELETE FROM scheduled_sources WHERE id = ?", [.text(record.wireID)])
    }
}

extension KnowledgeStore {
    /// Moves a placement row to another id with its goals and its activity days.
    static func rekeyPlacement(from old: String, to new: String, connection: SQLiteConnection) throws {
        try connection.execute("UPDATE scheduled_source_goals SET scheduled_source_id = ? WHERE scheduled_source_id = ?", [.text(new), .text(old)])
        try connection.execute("UPDATE source_activity_days SET scheduled_source_id = ? WHERE scheduled_source_id = ?", [.text(new), .text(old)])
        try connection.execute("UPDATE scheduled_sources SET id = ? WHERE id = ?", [.text(new), .text(old)])
    }
}
