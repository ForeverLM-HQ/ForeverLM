import Foundation

// MARK: - The seed's passes over the library's rows (docs/cloudkit-schema-design.md §13.4 step 2)

/// The record families of §13.4 step 2, in the order the seed uploads them. The settings and devices go
/// right after the shared base (P0); the structure a learner sees first comes next, then the catalog,
/// the chats, and the member's own state.
enum SeedPass: String, CaseIterable, Sendable {
    case settings = "p0"
    case structure = "p1"
    case catalog = "p2"
    case chats = "p3"
    case personal = "p4"

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .structure: return "Notebooks and courses"
        case .catalog: return "Sources"
        case .chats: return "Chats"
        case .personal: return "Your reading, cards and history"
        }
    }

    /// The pass a record type belongs to.
    static func pass(of type: SyncRecordType) -> SeedPass? {
        switch type {
        case .setting, .device: return .settings
        case .notebook, .goal, .entry, .notebookState, .course, .lesson, .quiz, .enrollment, .artifact, .comment: return .structure
        case .source, .collection: return .catalog
        case .chat, .exchange: return .chats
        case .readingState, .mark, .placement, .highlight, .card, .sitting, .activityLog, .idea, .practice, .task, .job, .automation: return .personal
        case .zoneRoot, .content: return nil
        }
    }
}

/// One local table a pass walks: every row of it feeds records (§6.6 step 1), so a row is handed to the
/// outbox exactly as an INSERT trigger would have, only dated with its migrated time.
struct SeedTable: Equatable, Sendable {
    let name: String
    let pass: SeedPass

    /// The order a table's rows are taken in: the primary key's rowid, except for sources, which go
    /// notebook members first, then newest first (§13.4 step 2, P2).
    var sortSQL: String? {
        guard name == "sources" else { return nil }
        return "(CASE WHEN EXISTS(SELECT 1 FROM learning_goal_items i WHERE i.source_id = t.id) THEN 0 ELSE 4000000000 END) - CAST(COALESCE(t.date_added, 0) AS INTEGER)"
    }

    /// Every table of the registry with the pass it belongs to, passes in order and, within a pass, the
    /// order the registry lists its projections in (structure first). A table two projections read
    /// belongs to the earlier pass; a playlist's members are the catalog's.
    static func tables(in registry: ProjectionRegistry) -> [SeedTable] {
        var seen = Set<String>()
        var found: [(pass: SeedPass, index: Int, name: String)] = []
        for (index, projection) in registry.projections.enumerated() {
            for table in projection.tables where seen.insert(table.name).inserted {
                let readers = registry.readers(of: table.name)
                let passes = readers.compactMap { SeedPass.pass(of: $0.projection.recordType) }
                guard var pass = passes.min(by: { $0.order < $1.order }) else { continue }
                if table.name == "group_members" { pass = .catalog }
                found.append((pass, index, table.name))
            }
        }
        return found.sorted { ($0.pass.order, $0.index, $0.name) < ($1.pass.order, $1.index, $1.name) }.map { SeedTable(name: $0.name, pass: $0.pass) }
    }

    static func tables(of pass: SeedPass, in registry: ProjectionRegistry) -> [SeedTable] {
        tables(in: registry).filter { $0.pass == pass }
    }
}

extension SeedPass {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A row the seed took: where it is, the record each projection reading it says it feeds, and when
/// the row's content was last changed (its migrated time).
struct SeedRow: Sendable {
    let rowid: Int64
    let sort: Int64
    let localKey: String
    let values: [String: SQLiteValue]
    let time: Double
}

/// A record a seed row feeds, with the zone this Mac holds it in.
struct SeedRecordRef: Hashable, Sendable {
    let type: SyncRecordType
    let wireID: String
    /// The local id of the record's own row (`RowRecord.localID`).
    let localID: String
    /// The zone key `ck_identity` names for a copy; nil for the personal library's own rows.
    let zoneKey: String?

    /// A space copy is the space's: the seed's P1 to P4 leave it to P6 (§13.7).
    var isSpaceCopy: Bool {
        guard let zoneKey, let zone = ProjectionZones.zone(ofKey: zoneKey) else { return false }
        return zone.isSpace
    }
}

/// Reads rows in bounded batches and hands them to the outbox, as the activation's triggers would have
/// had every row been inserted after them (`__row`, §6.6 step 1), each dated with its migrated time.
struct SeedRowReader {
    let connection: SQLiteConnection
    let registry: ProjectionRegistry
    /// The time a row with no time of its own takes: the activation's catch-up walk start (§13.4 step 4).
    let fallbackTime: Double
    /// The latest time a row may be dated with, in Cocoa seconds. A later one is no migrated time: the
    /// feeder sends a record only once its newest outbox time is past, so a row dated in the future would
    /// wait in the outbox forever and the seed would pass it by.
    var now: Double = Date().timeIntervalSinceReferenceDate

    private func merged(_ table: SeedTable) throws -> MergedProjectedTable {
        guard let merged = registry.merged(table.name) else { throw SeedRowError.unknownTable(table.name) }
        return merged
    }

    /// The columns of a table that name a row's old record, and the entity generation 1 synced it as
    /// (`sync_metadata.entity_type`).
    private static let primaryEntities: [String: (entity: String, column: String)] = [
        "sources": ("source", "id"), "learning_goals": ("learningGoal", "id"), "review_sessions": ("reviewSession", "id"),
        "global_artifacts": ("artifact", "id"), "courses": ("course", "id"), "memory_items": ("memoryItem", "id"),
        "memory_attempts": ("memoryAttempt", "id"), "user_preferences": ("preference", "key"),
        "source_highlights": ("sourceHighlight", "highlight_id"),
    ]
    /// Tables whose own time columns keep Unix seconds, not Cocoa seconds (`HighlightRow`).
    private static let unixSecondsTables: Set<String> = ["source_highlights"]
    private static let referenceEntities: [(column: String, entity: String)] = [
        ("source_id", "source"), ("goal_id", "learningGoal"), ("notebook_id", "learningGoal"), ("session_id", "reviewSession"),
        ("course_id", "course"), ("artifact_id", "artifact"),
    ]
    private static let updatedColumns = ["updated_at", "modified_at", "created_at", "added_at", "date_added", "started_at", "recorded_at"]

    /// The old record a table's rows belong to: the entity generation 1 synced it as and the column that holds
    /// its logical key; nil for a table no old record owns.
    func oldRecord(of table: SeedTable) throws -> (entity: String, column: String)? {
        var columns: [String] = []
        try connection.query("SELECT name FROM pragma_table_info(\(OutboxTriggerSQL.literal(table.name)))", []) { columns.append($0.text(0) ?? "") }
        if let primary = Self.primaryEntities[table.name] { return primary }
        return Self.referenceEntities.first { columns.contains($0.column) }.map { ($0.entity, $0.column) }
    }

    /// SQL for a row's migrated time, in Cocoa seconds (§13.4 step 4): the pending old-world change this
    /// Mac kept, else the old record's modification date, else the row's own time, else the walk's start.
    /// A time is taken only when it is after the reference date and not after `now`; a table that keeps
    /// Unix seconds has its own time converted. `?` is the fallback time.
    func timeSQL(for table: SeedTable) throws -> String {
        var columns: [String] = []
        try connection.query("SELECT name FROM pragma_table_info(\(OutboxTriggerSQL.literal(table.name)))", []) { columns.append($0.text(0) ?? "") }
        let entity = try oldRecord(of: table)
        var parts: [String] = []
        let latest = "\(now)"
        // Generation 1's tables stay until the post-soak cleanup; a store without them has no old times.
        let hasOldTables = try connection.scalarInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('sync_changes', 'sync_metadata')"
        ) == 2
        if let entity, hasOldTables {
            let key = "t.\(OutboxTriggerSQL.quoted(entity.column))"
            let kind = OutboxTriggerSQL.literal(entity.entity)
            parts.append("""
                (SELECT c.changed_at FROM sync_changes c WHERE c.entity_type = \(kind) AND c.logical_key = \(key) AND c.operation = 'save' \
                AND c.changed_at > 0 AND c.changed_at <= \(latest))
                """)
            parts.append("""
                (SELECT m.user_modification_at FROM sync_metadata m WHERE m.entity_type = \(kind) AND m.logical_key = \(key) AND m.is_deleted = 0 \
                AND m.user_modification_at > 0 AND m.user_modification_at <= \(latest))
                """)
        }
        if let own = Self.updatedColumns.first(where: { columns.contains($0) }) {
            let raw = "t.\(OutboxTriggerSQL.quoted(own))"
            let column = Self.unixSecondsTables.contains(table.name) ? "(\(raw) - \(Date.timeIntervalBetween1970AndReferenceDate))" : raw
            parts.append("(CASE WHEN typeof(\(raw)) IN ('real', 'integer') AND \(column) > 0 AND \(column) <= \(latest) THEN \(column) END)")
        }
        parts.append("?")
        return parts.count == 1 ? "?" : "COALESCE(" + parts.joined(separator: ", ") + ")"
    }

    /// The next batch after `cursor` (the last row's `<sort>|<rowid>`, nil from the start): at most
    /// `limit` rows, in the table's order.
    func nextBatch(of table: SeedTable, after cursor: String?, limit: Int) throws -> [SeedRow] {
        let merged = try merged(table)
        let name = OutboxTriggerSQL.quoted(table.name)
        let routing = merged.routingColumns.map { "t.\(OutboxTriggerSQL.quoted($0))" }
        // A constant would read as a column number in ORDER BY.
        let sortSQL = table.sortSQL ?? "CAST(0 AS INTEGER)"
        var parameters: [SQLiteValue] = [.real(fallbackTime)]
        var condition = "1 = 1"
        if let cursor, let (sort, rowid) = Self.parse(cursor) {
            condition = "((\(sortSQL)), t.rowid) > (?, ?)"
            parameters += [.integer(sort), .integer(rowid)]
        }
        parameters.append(.integer(Int64(limit)))
        var rows: [SeedRow] = []
        let sql = """
            SELECT t.rowid, \(sortSQL), \(OutboxTriggerSQL.localKey(merged.localKey, "t")), \(try timeSQL(for: table)), \(routing.joined(separator: ", "))
            FROM \(name) AS t WHERE \(condition) ORDER BY \(sortSQL), t.rowid LIMIT ?
        """
        // The parameters follow the statement's own order: the time's fallback in the SELECT list, the
        // cursor's pair, then the limit.
        try connection.query(sql, parameters) { row in
            var values: [String: SQLiteValue] = [:]
            for (index, column) in merged.routingColumns.enumerated() { values[column] = OutboxFeeder.value(row, Int32(index + 4)) }
            rows.append(SeedRow(rowid: row.integer(0) ?? 0, sort: row.integer(1) ?? 0, localKey: row.text(2) ?? "", values: values, time: row.real(3) ?? fallbackTime))
        }
        return rows
    }

    static func cursor(after row: SeedRow) -> String { "\(row.sort)|\(row.rowid)" }

    private static func parse(_ cursor: String) -> (Int64, Int64)? {
        let parts = cursor.split(separator: "|")
        guard parts.count == 2, let sort = Int64(parts[0]), let rowid = Int64(parts[1]) else { return nil }
        return (sort, rowid)
    }

    // MARK: Which records a row feeds

    /// The records the table's readers say `row` feeds, each with the zone `ck_identity` names for it. A
    /// record with no `ck_identity` row of its own whose home is its container (an Exchange in its chat,
    /// §4.4) is in the container's space when the container is a space's copy: a team chat's exchanges
    /// are the space's, P6's (§13.7), as the feeder places them.
    func records(of row: SeedRow, in table: SeedTable) throws -> [SeedRecordRef] {
        var refs: [SeedRecordRef] = []
        for reader in registry.readers(of: table.name) {
            guard let rowRecord = reader.table.record(row.values) else { continue }
            let found = try identity(rowRecord.type, localID: rowRecord.localID)
                ?? containerSpace(of: rowRecord, parents: reader.table.parents, values: row.values)
            let ref = SeedRecordRef(type: rowRecord.type, wireID: found?.wireID ?? rowRecord.personalID, localID: rowRecord.localID, zoneKey: found?.zoneKey)
            if !refs.contains(ref) { refs.append(ref) }
        }
        return refs
    }

    private func identity(_ type: SyncRecordType, localID: String) throws -> (zoneKey: String, wireID: String)? {
        var found: (zoneKey: String, wireID: String)?
        try connection.query(
            "SELECT zone_key, wire_id FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1",
            [.text(type.rawValue), .text(localID)]
        ) { found = ($0.text(0) ?? "", $0.text(1) ?? "") }
        return found
    }

    /// The space zone of the container a record lives in, by its home (`SyncHome`): only for a parent its
    /// home follows, and only when that parent's own `ck_identity` row names a space.
    private func containerSpace(of record: RowRecord, parents: [LocalParent], values: [String: SQLiteValue]) throws -> (zoneKey: String, wireID: String)? {
        let home = record.type.spec.home
        guard !record.type.spec.isPrivateOnly, !home.personalIDPrefixes.contains(where: record.personalID.hasPrefix) else { return nil }
        let followed: Set<SyncRecordType>
        switch home.rule {
        case .parent(_, let parent): followed = [parent]
        case .container(_, _, let kinds): followed = Set(kinds.values)
        case .library, .current, .owner: return nil
        }
        for parent in parents where parent.role == .container && followed.contains(parent.recordType) {
            guard let parentID = values[parent.column]?.textValue, let held = try identity(parent.recordType, localID: parentID),
                  ProjectionZones.zone(ofKey: held.zoneKey)?.isSpace == true
            else { continue }
            return (held.zoneKey, record.personalID)
        }
        return nil
    }

    /// Hands the row to the outbox as an insert at its migrated time. A row the outbox already holds keeps
    /// the time it has (an edit made since the activation is newer than the migrated value).
    func enqueue(_ row: SeedRow, of table: SeedTable) throws {
        try connection.execute("""
            INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at) VALUES (?, ?, '__row', ?)
            ON CONFLICT(source_table, local_key, column) DO NOTHING
        """, [.text(table.name), .text(row.localKey), .real(row.time)])
    }

    /// Hands every row of a table to the outbox in one set-based statement, each as `enqueue` hands it: a
    /// table an activated store's trigger refresh watches for the first time (`installOutboxTriggers`),
    /// whose rows no trigger saw and no seed walked. Bounded by the table, which only a projection
    /// registered after the activation makes new (the Ideas, 2026-10-13). Returns how many rows it queued.
    @discardableResult
    func enqueueAll(of table: SeedTable) throws -> Int {
        let merged = try merged(table)
        let before = try connection.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(table.name)]) ?? 0
        // The parameters follow the statement's order: the time's fallback in the SELECT list. `WHERE true`
        // keeps SQLite from reading the upsert's ON as a join's.
        try connection.execute("""
            INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
            SELECT \(OutboxTriggerSQL.literal(table.name)), \(OutboxTriggerSQL.localKey(merged.localKey, "t")), '__row', \(try timeSQL(for: table))
            FROM \(OutboxTriggerSQL.quoted(table.name)) AS t WHERE true
            ON CONFLICT(source_table, local_key, column) DO NOTHING
        """, [.real(fallbackTime)])
        let after = try connection.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = ?", [.text(table.name)]) ?? 0
        return Int(after - before)
    }
}

enum SeedRowError: Error, Equatable {
    case unknownTable(String)
}

/// The record types whose pass the seeder has not begun, held back from every sender while it seeds
/// (§13.4 step 5): an edit made during the seed goes to the outbox, and a record of a family whose pass
/// has not begun waits for it, so the seed's priority order is never overtaken. The outbox feeder and the
/// patch sender read the same row of `ck_engine_state`; a family whose pass began is sent as it stands (the
/// feeder sends a record whole, from the rows as they are now).
enum CutoverSeedGate {
    static func types(of passes: some Sequence<SeedPass>) -> Set<SyncRecordType> {
        let wanted = Set(passes)
        return Set(SyncRecordType.allCases.filter { SeedPass.pass(of: $0).map(wanted.contains) ?? false })
    }

    static func hold(_ passes: some Sequence<SeedPass>, in connection: SQLiteConnection, now: Date = Date()) throws {
        let list = types(of: passes).map(\.rawValue).sorted().joined(separator: ",")
        try ReplicaStore(connection: connection).setEngineState(ReplicaStore.EngineScope.seedHeldTypes, list.isEmpty ? nil : Data(list.utf8), now: now)
    }
}

/// What the seed's passes leave unsent (§13.4 step 2): once every pass ran, a row the outbox still holds,
/// dated before this run of the seed began (a seeded row's migrated time, or an edit made before the run)
/// or after `now` (never due), that feeds a record of the seed's own families which neither `Library` nor
/// `Catalog` holds and whose rows encode something to send. The engine's pending count cannot see such a
/// row, since the feeder never hands it out, so a pass would go on and the seed would report complete
/// without it. A space's copies are P6's, a record that encodes nothing (an empty exchange, an unrated
/// exchange's Mark) has nothing to send, and a parked record is the quarantine's (M4): none of them counts.
enum SeedLeftovers {
    struct Found: Equatable, Sendable {
        var count = 0
        var sample: [SeedRecordRef] = []
    }

    static func unsent(registry: ProjectionRegistry, connection: SQLiteConnection, runStartedAt: Double, now: Double, sampleSize: Int = 20) throws -> Found {
        struct Unit { var values: [String: SQLiteValue]? }
        var units: [String: [String: Unit]] = [:]
        let stale = "(MIN(dirty_at) < ? OR MAX(dirty_at) > ?)"
        try connection.query("""
            SELECT source_table, local_key FROM ck_outbox_fields WHERE source_table <> ? GROUP BY source_table, local_key HAVING \(stale)
        """, [.text(OutboxFeeder.pinSource), .real(runStartedAt), .real(now)]) { row in
            units[row.text(0) ?? "", default: [:]][row.text(1) ?? ""] = Unit(values: nil)
        }
        // A removal carries its record's routing values; a live row's are read from the row.
        try connection.query("""
            SELECT source_table, local_key, MIN(record_key_json) FROM ck_outbox GROUP BY source_table, local_key HAVING \(stale)
        """, [.real(runStartedAt), .real(now)]) { row in
            let json = row.text(2).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
            units[row.text(0) ?? "", default: [:]][row.text(1) ?? ""] = Unit(values: json.mapValues(SQLiteValue.init(json:)))
        }
        guard !units.isEmpty else { return Found() }

        let reader = SeedRowReader(connection: connection, registry: registry, fallbackTime: now, now: now)
        let salt = try ReplicaStore(connection: connection).personalRoot()?.envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        let personalZones = [PrivateSyncZones.libraryKey, PrivateSyncZones.key(PrivateSyncZones.catalog)]
        var unsent: [SeedRecordRef] = []
        var seen = Set<SeedRecordRef>()
        let seeded = Dictionary(SeedTable.tables(in: registry).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (tableName, keys) in units.sorted(by: { $0.key < $1.key }) {
            guard let merged = registry.merged(tableName), let table = seeded[tableName] else { continue }
            for (localKey, unit) in keys.sorted(by: { $0.key < $1.key }) {
                guard let values = try unit.values ?? liveValues(merged, localKey: localKey, connection: connection) else { continue }
                let row = SeedRow(rowid: 0, sort: 0, localKey: localKey, values: values, time: now)
                for ref in try reader.records(of: row, in: table) where !ref.isSpaceCopy && SeedPass.pass(of: ref.type) != nil {
                    guard seen.insert(ref).inserted, try !SeedRowDecider.serverHolds(ref, in: connection),
                          try encodes(ref, registry: registry, connection: connection)
                    else { continue }
                    if let salt {
                        let name = RecordNaming.recordName(type: ref.type, id: ref.wireID, salt: salt)
                        let parked = try connection.scalarInteger(
                            "SELECT EXISTS(SELECT 1 FROM ck_quarantine WHERE zone_key IN (?, ?) AND record_name = ?)",
                            [.text(personalZones[0]), .text(personalZones[1]), .text(name)]
                        ) == 1
                        if parked { continue }
                    }
                    unsent.append(ref)
                }
            }
        }
        return Found(count: unsent.count, sample: Array(unsent.prefix(sampleSize)))
    }

    /// Whether the record's rows encode anything, read as the feeder reads a record it places.
    private static func encodes(_ ref: SeedRecordRef, registry: ProjectionRegistry, connection: SQLiteConnection) throws -> Bool {
        guard let projection = registry.projection(for: ref.type) else { return false }
        let catalog = ref.type.spec.home.rule == .current(privateZone: .catalog)
        let record = ProjectionRecordRef(
            zoneKey: catalog ? PrivateSyncZones.key(PrivateSyncZones.catalog) : PrivateSyncZones.libraryKey,
            zone: catalog ? .catalog : .library, type: ref.type, wireID: ref.wireID, localID: ref.localID
        )
        return try projection.encode(record, connection: connection) != nil
    }

    /// The routing values of the live row `localKey` names; nil when the row is gone.
    private static func liveValues(_ table: MergedProjectedTable, localKey: String, connection: SQLiteConnection) throws -> [String: SQLiteValue]? {
        let keyValues: [SQLiteValue]
        if table.localKey.count == 1 {
            keyValues = [.text(localKey)]
        } else {
            guard let parts = (try? SyncJSON(parsing: Data(localKey.utf8)))?.arrayValue, parts.count == table.localKey.count else { return nil }
            keyValues = parts.map(SQLiteValue.init(json:))
        }
        let columns = table.routingColumns
        let condition = table.localKey.map { "\(OutboxTriggerSQL.quoted($0)) = ?" }.joined(separator: " AND ")
        var values: [String: SQLiteValue]?
        try connection.query(
            "SELECT \(columns.map(OutboxTriggerSQL.quoted).joined(separator: ", ")) FROM \(OutboxTriggerSQL.quoted(table.name)) WHERE \(condition) LIMIT 1",
            keyValues
        ) { row in
            var read: [String: SQLiteValue] = [:]
            for (index, column) in columns.enumerated() { read[column] = OutboxFeeder.value(row, Int32(index)) }
            values = read
        }
        return values
    }
}
