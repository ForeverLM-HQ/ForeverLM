import Foundation

/// One `ck_*` table: its columns with their definitions, its table constraints and its indexes.
/// The CREATE statement and the migration's probe are both built from the one column list, so
/// they cannot disagree.
struct ReplicaSchemaTable: Sendable {
    let name: String
    let columns: [(name: String, definition: String)]
    let constraints: [String]
    let indexes: [String]

    init(_ name: String, _ columns: [(String, String)], constraints: [String] = [], indexes: [String] = []) {
        self.name = name
        self.columns = columns.map { (name: $0.0, definition: $0.1) }
        self.constraints = constraints
        self.indexes = indexes
    }

    var columnNames: [String] { columns.map(\.name) }

    var createStatement: String {
        let lines = columns.map { "    \($0.name) \($0.definition)" } + constraints.map { "    \($0)" }
        return "CREATE TABLE IF NOT EXISTS \(name) (\n\(lines.joined(separator: ",\n"))\n)"
    }

    /// Selects every column and no row, so a same-named table of another shape fails the statement
    /// (and the migration that runs it rolls back) instead of being taken as this one.
    var probe: String { "SELECT \(columnNames.joined(separator: ", ")) FROM \(name) LIMIT 0" }
}

/// A zone this device holds (`ck_zones`, §2.2). `zone_key` is a local key only: `private/<zone>` for
/// the learner's own zones and `shared/<owner record name>/<zone>` for a space shared by someone else.
struct ReplicaZone: Equatable, Sendable {
    enum Database: String, Sendable { case `private`, shared }

    var zoneKey: String
    var database: Database
    var zoneName: String
    var ownerRecordName: String?
    /// `library`, `catalog`, `content` or `space` (`SyncZone`).
    var kind: String
    /// For a notebook or Doc space, the record the space was made for (§3.5.1).
    var primaryID: String? = nil
    var shareRecordName: String? = nil
    /// This member's role and permission in a space.
    var role: String? = nil
    var permission: String? = nil
    /// The zone salt's id (§2.4 step 6), once the root is known.
    var saltID: String? = nil
    /// The server change token, archived.
    var changeToken: Data? = nil
    /// When the last change fetch that reached the end of the zone started (Cocoa seconds). A record
    /// whose `seenPass` is not earlier was seen in that pass (D30).
    var lastCompletePassAt: Double? = nil

    static func key(database: Database, zoneName: String, ownerRecordName: String? = nil) -> String {
        switch database {
        case .private: return "private/\(zoneName)"
        case .shared: return "shared/\(ownerRecordName ?? "")/\(zoneName)"
        }
    }
}

/// The server's last acknowledged version of one record (`ck_records`), raw (§6.5): the payload bytes
/// exactly as the server holds them, unknown fields and all, and the CloudKit system fields (the
/// change tag) a later save goes out on.
struct ReplicaRecord: Equatable, Sendable {
    var zoneKey: String
    var recordName: String
    var recordType: String
    /// The logical id the envelope carries (`id`, §3.2 rule 2).
    var wireID: String
    var systemFields: Data?
    var payload: Data
    /// When the change-fetch pass that last delivered the record started (Cocoa seconds).
    var seenPass: Double?
}

/// The replica of the server's records, the system of record on the Mac and the iPhone (D32, D33,
/// §6.5, §6.6). The same tables live in the Mac's `knowledge.db` (local schema 154) and in the
/// iPhone's replica file, and this type reads and writes them through a `SQLiteConnection`: on the
/// Mac `KnowledgeStore`'s own connection, inside its storage-actor transaction.
///
/// An inbound apply runs in `apply(_:)`: one `BEGIN IMMEDIATE` transaction that inserts the
/// `ck_apply_guard` row, writes the replica rows and the projection rows the closure writes, deletes
/// the guard row and commits. The outbox triggers (installed by the generation-2 activation)
/// fire only while no guard row exists, so what an apply writes is never sent back; the guard is
/// never held across transactions, so a write made on any other connection, or on this one before or
/// after the apply, is always enqueued.
final class ReplicaStore {
    let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    // MARK: - Schema

    /// The `ck_*` tables both platforms hold. Times are Cocoa reference seconds (REAL), as in every
    /// other table of `knowledge.db`; stamps are the 27-character stamps of §3.2 (TEXT).
    static let sharedTables: [ReplicaSchemaTable] = [
        ReplicaSchemaTable("ck_zones", [
            ("zone_key", "TEXT PRIMARY KEY"),
            ("database", "TEXT NOT NULL"),
            ("zone_name", "TEXT NOT NULL"),
            ("owner_record_name", "TEXT"),
            ("kind", "TEXT NOT NULL"),
            ("primary_id", "TEXT"),
            ("share_record_name", "TEXT"),
            ("role", "TEXT"),
            ("permission", "TEXT"),
            ("salt_id", "TEXT"),
            ("change_token", "BLOB"),
            ("last_complete_pass_at", "REAL"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_zones_name ON ck_zones(zone_name)",
        ]),
        ReplicaSchemaTable("ck_records", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("system_fields", "BLOB"),
            ("payload", "BLOB NOT NULL"),
            ("seen_pass", "REAL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_records_wire ON ck_records(zone_key, record_type, wire_id)",
        ]),
        // A record applied before a local parent it needs, waiting for it (§5.7). The parent table's
        // readiness trigger sets `ready` when the parent row arrives.
        ReplicaSchemaTable("ck_unprojected", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("waiting_on_type", "TEXT NOT NULL"),
            ("waiting_on_id", "TEXT NOT NULL"),
            ("ready", "INTEGER NOT NULL DEFAULT 0"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name, waiting_on_type, waiting_on_id)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_unprojected_waiting ON ck_unprojected(waiting_on_type, waiting_on_id)",
            "CREATE INDEX IF NOT EXISTS idx_ck_unprojected_ready ON ck_unprojected(ready) WHERE ready = 1",
        ]),
        // RecordPatches whose stamps are their own (§6.6): every write on the iPhone; on the Mac only
        // late import's, the deferred catch-up's and listen positions read from iCloud Drive. One row
        // per record: a writer folds a new patch into the pending one, field by field by stamp.
        ReplicaSchemaTable("ck_patches", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("patch_json", "TEXT NOT NULL"),
            ("dirty_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_type, wire_id)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_patches_dirty ON ck_patches(dirty_at)",
        ]),
        // A local delete until the server acknowledges it (§6.4).
        ReplicaSchemaTable("ck_pending_deletes", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("record_type", "TEXT NOT NULL"),
            ("wire_id", "TEXT NOT NULL"),
            ("deleted_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name)"]),
        // After an acknowledged delete, a stale echo of the same version is ignored until `until`;
        // a newer server version (a deliberate re-create) is accepted (§6.4).
        ReplicaSchemaTable("ck_echo", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("change_tag", "TEXT"),
            ("until", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name)"]),
        // Every satellite this account uploaded, written on acknowledgement (§5.8, §3.5.30).
        ReplicaSchemaTable("ck_blobs", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("content_id", "TEXT NOT NULL"),
            ("owner_id", "TEXT NOT NULL"),
            ("role", "TEXT NOT NULL"),
            ("part_hash", "TEXT NOT NULL"),
            ("part_bytes", "INTEGER NOT NULL"),
            ("enc", "TEXT"),
            ("server_created_at", "REAL"),
            ("acked_at", "REAL"),
            ("unreachable_since", "REAL"),
            ("pinned", "INTEGER NOT NULL DEFAULT 0"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_blobs_owner ON ck_blobs(owner_id, role)",
        ]),
        ReplicaSchemaTable("ck_blob_jobs", [
            ("id", "INTEGER PRIMARY KEY"),
            ("direction", "TEXT NOT NULL"),
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("content_id", "TEXT NOT NULL"),
            ("local_path", "TEXT"),
            ("priority", "INTEGER NOT NULL DEFAULT 0"),
            ("state", "TEXT NOT NULL DEFAULT 'queued'"),
            ("attempts", "INTEGER NOT NULL DEFAULT 0"),
            ("last_error", "TEXT"),
            ("enqueued_at", "REAL NOT NULL"),
            ("updated_at", "REAL NOT NULL"),
        ], constraints: ["UNIQUE (direction, zone_key, record_name)"], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_ck_blob_jobs_order ON ck_blob_jobs(state, priority, enqueued_at)",
        ]),
        // A record that cannot be applied (a payload over the cap, an envelope version this build does
        // not read), kept raw (§3.2 rule 1).
        ReplicaSchemaTable("ck_quarantine", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("record_type", "TEXT"),
            ("reason", "TEXT NOT NULL"),
            ("system_fields", "BLOB"),
            ("payload", "BLOB"),
            ("quarantined_at", "REAL NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name)"]),
        // Exists only inside an apply transaction (§6.6 step 2).
        ReplicaSchemaTable("ck_apply_guard", [
            ("id", "INTEGER PRIMARY KEY CHECK (id = 1)"),
        ]),
        // The body a T field's three-way merge starts from (§6.2).
        ReplicaSchemaTable("ck_text_bases", [
            ("zone_key", "TEXT NOT NULL"),
            ("record_name", "TEXT NOT NULL"),
            ("field", "TEXT NOT NULL"),
            ("base_stamp", "TEXT NOT NULL"),
            ("base_hash", "TEXT NOT NULL"),
            ("base_text", "TEXT NOT NULL"),
        ], constraints: ["PRIMARY KEY (zone_key, record_name, field)"]),
        // CKSyncEngine's serialized state, per database scope.
        ReplicaSchemaTable("ck_engine_state", [
            ("scope", "TEXT PRIMARY KEY"),
            ("state", "BLOB NOT NULL"),
            ("updated_at", "REAL NOT NULL"),
        ]),
        // The device's `StampClock`, as JSON (§6.3).
        ReplicaSchemaTable("ck_clock", [
            ("id", "INTEGER PRIMARY KEY CHECK (id = 1)"),
            ("clock_json", "TEXT NOT NULL"),
            ("updated_at", "REAL NOT NULL"),
        ]),
    ]

    /// Creates the shared tables and their indexes where they do not exist yet. The Mac's
    /// migration 154 runs this inside its transaction; the iPhone's replica runs it at open.
    func installSharedSchema() throws {
        for table in Self.sharedTables {
            try connection.executeScript(table.createStatement)
            for index in table.indexes {
                try connection.executeScript(index)
            }
        }
    }

    // MARK: - Apply

    /// Whether an apply transaction is open on this connection: the guard row exists only inside one,
    /// and no other connection can see it uncommitted.
    var isApplying: Bool {
        get throws { try connection.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") ?? 0 > 0 }
    }

    /// Runs one inbound apply (§6.6 step 2): `BEGIN IMMEDIATE`, the guard row, `body`, the guard
    /// row's delete, `COMMIT`; any throw rolls all of it back, the guard row included. The connection
    /// hears how it ended (`replicaApplyDidEnd`), so what it changed reaches the models that hold the
    /// rows in memory only once it is committed.
    ///
    /// `body` is synchronous on purpose. Every fetch, download and decode happens before the apply
    /// starts, and nothing may suspend between `BEGIN` and `COMMIT`: a suspension would let another
    /// call on the storage actor write on this connection under the guard, and that write would never
    /// be sent. The connection must not already be inside a transaction.
    func apply<T>(_ body: (ReplicaStore) throws -> T) throws -> T {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try connection.execute("INSERT INTO ck_apply_guard (id) VALUES (1)")
            let result = try body(self)
            try connection.execute("DELETE FROM ck_apply_guard")
            try connection.executeScript("COMMIT")
            connection.replicaApplyDidEnd(committed: true)
            return result
        } catch {
            try? connection.executeScript("ROLLBACK")
            connection.replicaApplyDidEnd(committed: false)
            throw error
        }
    }

    // MARK: - Records

    func upsertRecord(_ record: ReplicaRecord) throws {
        try connection.execute("""
            INSERT INTO ck_records (zone_key, record_name, record_type, wire_id, system_fields, payload, seen_pass)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET
                record_type = excluded.record_type,
                wire_id = excluded.wire_id,
                system_fields = excluded.system_fields,
                payload = excluded.payload,
                seen_pass = excluded.seen_pass
        """, [
            .text(record.zoneKey), .text(record.recordName), .text(record.recordType), .text(record.wireID),
            .blob(record.systemFields), .blob(record.payload), .real(record.seenPass),
        ])
    }

    func record(zoneKey: String, recordName: String) throws -> ReplicaRecord? {
        try records(where: "zone_key = ? AND record_name = ?", [.text(zoneKey), .text(recordName)]).first
    }

    /// The record of one logical id in one zone, if the replica holds it.
    func record(zoneKey: String, recordType: String, wireID: String) throws -> ReplicaRecord? {
        try records(
            where: "zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(recordType), .text(wireID)]
        ).first
    }

    func deleteRecord(zoneKey: String, recordName: String) throws {
        try connection.execute(
            "DELETE FROM ck_records WHERE zone_key = ? AND record_name = ?",
            [.text(zoneKey), .text(recordName)]
        )
    }

    private func records(where condition: String, _ parameters: [SQLiteValue]) throws -> [ReplicaRecord] {
        var found: [ReplicaRecord] = []
        try connection.query("""
            SELECT zone_key, record_name, record_type, wire_id, system_fields, payload, seen_pass
            FROM ck_records WHERE \(condition)
        """, parameters) { row in
            found.append(ReplicaRecord(
                zoneKey: row.text(0) ?? "",
                recordName: row.text(1) ?? "",
                recordType: row.text(2) ?? "",
                wireID: row.text(3) ?? "",
                systemFields: row.blob(4),
                payload: row.blob(5) ?? Data(),
                seenPass: row.real(6)
            ))
        }
        return found
    }

    // MARK: - Zones

    func upsertZone(_ zone: ReplicaZone) throws {
        try connection.execute("""
            INSERT INTO ck_zones (
                zone_key, database, zone_name, owner_record_name, kind, primary_id, share_record_name,
                role, permission, salt_id, change_token, last_complete_pass_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key) DO UPDATE SET
                database = excluded.database,
                zone_name = excluded.zone_name,
                owner_record_name = excluded.owner_record_name,
                kind = excluded.kind,
                primary_id = excluded.primary_id,
                share_record_name = excluded.share_record_name,
                role = excluded.role,
                permission = excluded.permission,
                salt_id = excluded.salt_id,
                change_token = excluded.change_token,
                last_complete_pass_at = excluded.last_complete_pass_at
        """, [
            .text(zone.zoneKey), .text(zone.database.rawValue), .text(zone.zoneName), .text(zone.ownerRecordName),
            .text(zone.kind), .text(zone.primaryID), .text(zone.shareRecordName), .text(zone.role),
            .text(zone.permission), .text(zone.saltID), .blob(zone.changeToken), .real(zone.lastCompletePassAt),
        ])
    }

    func zone(key: String) throws -> ReplicaZone? {
        var found: ReplicaZone?
        try connection.query("""
            SELECT zone_key, database, zone_name, owner_record_name, kind, primary_id, share_record_name,
                   role, permission, salt_id, change_token, last_complete_pass_at
            FROM ck_zones WHERE zone_key = ?
        """, [.text(key)]) { row in
            guard let database = row.text(1).flatMap(ReplicaZone.Database.init(rawValue:)) else { return }
            found = ReplicaZone(
                zoneKey: row.text(0) ?? key,
                database: database,
                zoneName: row.text(2) ?? "",
                ownerRecordName: row.text(3),
                kind: row.text(4) ?? "",
                primaryID: row.text(5),
                shareRecordName: row.text(6),
                role: row.text(7),
                permission: row.text(8),
                saltID: row.text(9),
                changeToken: row.blob(10),
                lastCompletePassAt: row.real(11)
            )
        }
        return found
    }
}

extension SQLiteConnection {
    /// The device's stamp clock (`ck_clock`); nil before it exists.
    func loadStampClock() throws -> StampClock? {
        guard let json = try scalarText("SELECT clock_json FROM ck_clock WHERE id = 1") else { return nil }
        return try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8))
    }

    func saveStampClock(_ clock: StampClock, now: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(clock), as: UTF8.self)
        try execute("""
            INSERT INTO ck_clock (id, clock_json, updated_at) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET clock_json = excluded.clock_json, updated_at = excluded.updated_at
        """, [.text(json), .real(now.timeIntervalSinceReferenceDate)])
    }
}
