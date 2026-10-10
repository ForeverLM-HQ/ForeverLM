import Foundation

// MARK: - This Mac's own view of the old zones, as a base (docs/cloudkit-schema-design.md §13.3, §13.4 step 0, WP16b2)

/// What the catch-ups keep of the old zones (`ck_legacy_snapshot`: per old record its change tag and, from the
/// mapping, the owner flag and a hash of each field it gave; the walk's change tokens are `ck_engine_state`
/// rows `migration.token.<database>.<zone>`), read and advanced as the base a pass compares with. The shared
/// base is the importer's; this is the Mac's own, which serves only its own catch-up and refresh (§13.4
/// step 0): a refresh runs the import pass over it, and advances it once its patches are acknowledged, so a
/// later refresh, after a relaunch or a takeover, starts from there (R5-m12).
///
/// Shards are cut from the rows as the shared base's are (`MigrationBaseShards.name(forRecordName:)`), once
/// per instance: a pass reads the whole snapshot only for the records it meets and for the guard's count.
final class OwnSnapshotBase: MigrationBaseStore, @unchecked Sendable {
    static let tokenScopePrefix = "migration.token."

    private let store: PrivateSyncLocalStore
    private let lock = NSLock()
    private var shards: [String: [String: MigrationBaseEntry]]?

    init(store: PrivateSyncLocalStore) {
        self.store = store
    }

    // MARK: Reading

    /// Whether this Mac holds a snapshot at all: a store that never walked the old zones (`fresh`, a deferred
    /// one before its catch-up, a `knowledgeMissing` one) has nothing to refresh.
    func hasSnapshot() async throws -> Bool {
        try await store.perform { state in
            let rows = try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_legacy_snapshot") ?? 0
            let tokens = try state.connection.scalarInteger(
                "SELECT COUNT(*) FROM ck_engine_state WHERE scope LIKE ?", [.text(Self.tokenScopePrefix + "%")]
            ) ?? 0
            return rows > 0 || tokens > 0
        }
    }

    func watermark() async throws -> MigrationImportWatermark? {
        try await store.perform { state in
            var tokens: [String: String] = [:]
            var zones = Set<String>()
            try state.connection.query(
                "SELECT scope, state FROM ck_engine_state WHERE scope LIKE ? ORDER BY scope", [.text(Self.tokenScopePrefix + "%")]
            ) { row in
                guard let scope = row.text(0), let data = row.blob(1), let zone = Self.zone(ofTokenScope: scope) else { return }
                tokens[zone] = data.base64EncodedString()
                zones.insert(zone)
            }
            try state.connection.query("SELECT DISTINCT old_zone FROM ck_legacy_snapshot", []) { row in
                if let zone = row.text(0) { zones.insert(zone) }
            }
            guard !zones.isEmpty else { return nil }
            return MigrationImportWatermark(zones: zones.sorted(), tokens: tokens)
        }
    }

    func shard(_ name: String) async throws -> [String: MigrationBaseEntry] {
        if let cached = lock.withLock({ shards }) { return cached[name] ?? [:] }
        let loaded = try await store.perform { state in try Self.load(state.connection) }
        lock.withLock { shards = loaded }
        return loaded[name] ?? [:]
    }

    /// Every row, split into the shards of the shared base.
    private static func load(_ connection: SQLiteConnection) throws -> [String: [String: MigrationBaseEntry]] {
        var all: [String: MigrationBaseEntry] = [:]
        try connection.query("SELECT old_zone, record_name, change_tag, field_hashes FROM ck_legacy_snapshot", []) { row in
            guard let zone = row.text(0), let name = row.text(1), let text = row.text(3),
                  let json = try? SyncJSON(parsing: Data(text.utf8)), let entry = MigrationBaseEntry(json: json, changeTag: row.text(2))
            else { return }
            all[MigrationBaseShards.entryKey(zone: zone, recordName: name)] = entry
        }
        return MigrationBaseShards.partition(all)
    }

    // MARK: Advancing

    /// The pass's entries (nil removes one) and the tokens it ended on, written in one transaction. The
    /// snapshot is this Mac's alone, so nothing can have changed it meanwhile: it always lands.
    func advance(_ update: MigrationBaseAdvance) async throws -> Bool {
        try await write(entries: update.entries, tokens: update.watermark.tokens, zones: update.watermark.zones, replacing: false)
        return true
    }

    /// Writes a walk's whole result (the deferred catch-up's): every row of the walked zones is replaced.
    func replaceAll(entries: [String: MigrationBaseEntry], tokens: [String: String], zones: [String]) async throws {
        try await write(entries: entries.mapValues { Optional($0) }, tokens: tokens, zones: zones, replacing: true)
    }

    private func write(entries: [String: MigrationBaseEntry?], tokens: [String: String], zones: [String], replacing: Bool) async throws {
        let now = Date()
        try await store.perform { state in
            try state.replica.apply { replica in
                let connection = state.connection
                if replacing {
                    for zone in zones { try connection.execute("DELETE FROM ck_legacy_snapshot WHERE old_zone = ?", [.text(zone)]) }
                }
                for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
                    guard let zone = MigrationBaseShards.zone(ofEntryKey: key), let name = MigrationBaseShards.recordName(ofEntryKey: key) else { continue }
                    guard let entry else {
                        try connection.execute("DELETE FROM ck_legacy_snapshot WHERE old_zone = ? AND record_name = ?", [.text(zone), .text(name)])
                        continue
                    }
                    try connection.execute("""
                        INSERT INTO ck_legacy_snapshot (old_zone, record_name, change_tag, field_hashes) VALUES (?, ?, ?, ?)
                        ON CONFLICT(old_zone, record_name) DO UPDATE SET change_tag = excluded.change_tag, field_hashes = excluded.field_hashes
                    """, [.text(zone), .text(name), .text(entry.changeTag), .text(String(decoding: entry.json.serialized(), as: UTF8.self))])
                }
                for zone in zones {
                    guard let token = tokens[zone].flatMap({ Data(base64Encoded: $0) }), let scope = Self.tokenScope(ofZone: zone) else { continue }
                    try replica.setEngineState(scope, token, now: now)
                }
                // A zone the pass found gone ends its tracking; its rows stay (a missing zone deletes nothing).
                var scopes: [String] = []
                try connection.query("SELECT scope FROM ck_engine_state WHERE scope LIKE ?", [.text(Self.tokenScopePrefix + "%")]) { row in
                    if let scope = row.text(0), let zone = Self.zone(ofTokenScope: scope), !zones.contains(zone) { scopes.append(scope) }
                }
                for scope in scopes { try replica.setEngineState(scope, nil) }
            }
        }
        lock.withLock { shards = nil }
    }

    // MARK: Token scopes

    /// `migration.token.<database>.<zone>` (`OldContainerZoneKey.stateKey`) as the zone the snapshot names.
    static func zone(ofTokenScope scope: String) -> String? {
        guard scope.hasPrefix(tokenScopePrefix) else { return nil }
        let rest = scope.dropFirst(tokenScopePrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let zone = String(rest[rest.index(after: dot)...])
        return zone.isEmpty ? nil : zone
    }

    static func tokenScope(ofZone zone: String) -> String? {
        MigrationOldZone(name: zone).map { OldContainerZoneKey.stateKey(database: $0.database, zoneID: $0.zoneID) }
    }
}
