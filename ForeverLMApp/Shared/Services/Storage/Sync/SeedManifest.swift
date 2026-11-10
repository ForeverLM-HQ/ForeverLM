import Foundation

// MARK: - The seed manifest and its deltas (docs/cloudkit-schema-design.md §13.4, §13.5, §13.6, R5-3)

/// One record the seed, or a later pass that created records, put in the new world: (type, id) for the
/// personal library, (space id, type, id) for a space. A reader takes every entry of the manifest and of
/// every delta as "was in the new world": a name the server no longer holds was deleted there.
struct SeedManifestEntry: Hashable, Comparable, Sendable {
    let spaceID: String?
    let type: String
    let id: String

    init(spaceID: String? = nil, type: String, id: String) {
        self.spaceID = spaceID
        self.type = type
        self.id = id
    }

    /// The entry a record of `zoneKey` is listed as; nil for `Content`, whose satellites are no records of
    /// the library.
    init?(zoneKey: String, type: String, id: String) {
        guard let zone = ProjectionZones.zone(ofKey: zoneKey) else { return nil }
        if zone.isSpace {
            self.init(spaceID: String(zone.name.dropFirst(SyncSchema.spaceZonePrefix.count)), type: type, id: id)
        } else if zone.name == SyncZone.library.rawValue || zone.name == SyncZone.catalog.rawValue {
            self.init(type: type, id: id)
        } else {
            return nil
        }
    }

    static func < (lhs: SeedManifestEntry, rhs: SeedManifestEntry) -> Bool {
        (lhs.spaceID ?? "", lhs.type, lhs.id) < (rhs.spaceID ?? "", rhs.type, rhs.id)
    }

    var json: SyncJSON {
        if let spaceID { return .array([.string(spaceID), .string(type), .string(id)]) }
        return .array([.string(type), .string(id)])
    }

    init?(json: SyncJSON) {
        guard let parts = json.arrayValue?.compactMap(\.stringValue) else { return nil }
        switch parts.count {
        case 2: self.init(type: parts[0], id: parts[1])
        case 3: self.init(spaceID: parts[0], type: parts[1], id: parts[2])
        default: return nil
        }
    }
}

/// The body of a manifest or a delta: a sorted JSON list, so two Macs listing the same records write
/// the same bytes. It travels as a gzip satellite of the personal root (`seedManifest` for the seed's,
/// `seedManifestDelta.<deviceID>.<passID>` for a pass's).
enum SeedManifestCodec {
    static func encode(_ entries: some Sequence<SeedManifestEntry>) -> Data {
        SyncJSON.object(["v": SyncJSON(1), "entries": .array(entries.sorted().map(\.json))]).serialized()
    }

    static func decode(_ body: Data) throws -> Set<SeedManifestEntry> {
        let root = try SyncJSON(parsing: body)
        guard let list = root.objectValue?["entries"]?.arrayValue else { throw SeedManifestError.unreadable }
        return Set(list.compactMap(SeedManifestEntry.init(json:)))
    }
}

enum SeedManifestError: Error, Equatable {
    case unreadable
    /// The root holds no personal library root to write into.
    case noRoot
}

/// `ck_manifest_pending`: the records a pass created and has not listed yet, under the pass's key
/// `<deviceID>.<passID>`. A pass writes a row for each create it queues; its delta's save, once the
/// creates are acknowledged, deletes them, so a crash in between resumes the listing (R5-3).
enum SeedManifestPending {
    static func seedPassKey(_ deviceID: String) -> String { "\(deviceID).seed" }

    static func add(passKey: String, zoneKey: String, type: String, wireID: String, in connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO ck_manifest_pending (pass_key, zone_key, record_type, wire_id) VALUES (?, ?, ?, ?)
            ON CONFLICT DO NOTHING
        """, [.text(passKey), .text(zoneKey), .text(type), .text(wireID)])
    }

    struct Row: Hashable, Sendable {
        let zoneKey: String
        let type: String
        let wireID: String
    }

    static func rows(passKey: String, in connection: SQLiteConnection) throws -> [Row] {
        var rows: [Row] = []
        try connection.query(
            "SELECT zone_key, record_type, wire_id FROM ck_manifest_pending WHERE pass_key = ? ORDER BY zone_key, record_type, wire_id",
            [.text(passKey)]
        ) { row in
            rows.append(Row(zoneKey: row.text(0) ?? "", type: row.text(1) ?? "", wireID: row.text(2) ?? ""))
        }
        return rows
    }

    /// Whether the replica holds the record the row names: the server took its create.
    static func isAcknowledged(_ row: Row, in connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_records WHERE zone_key = ? AND record_type = ? AND wire_id = ?)",
            [.text(row.zoneKey), .text(row.type), .text(row.wireID)]
        ) == 1
    }

    /// Drops the rows of `passKey` the server does not hold: a record the pass listed that no send created,
    /// because the row feeds a record with nothing to say (a Mark about a source with no provenance).
    static func removeUnacknowledged(passKey: String, in connection: SQLiteConnection) throws {
        for row in try rows(passKey: passKey, in: connection) where try !isAcknowledged(row, in: connection) {
            try connection.execute(
                "DELETE FROM ck_manifest_pending WHERE pass_key = ? AND zone_key = ? AND record_type = ? AND wire_id = ?",
                [.text(passKey), .text(row.zoneKey), .text(row.type), .text(row.wireID)]
            )
        }
    }

    static func remove(passKey: String, in connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_manifest_pending WHERE pass_key = ?", [.text(passKey)])
    }
}

// MARK: - Writing

/// The manifest and the deltas as satellites of the personal root, and the root fields that point at
/// them (§3.5.1 `seed.manifest`, `manifestDeltas`). The satellite is uploaded and acknowledged before
/// the root names it (bytes before pointer, §3.5.30 rule 2).
struct SeedManifestWriter {
    static let manifestRole = "seedManifest"
    static func deltaRole(passKey: String) -> String { "seedManifestDelta.\(passKey)" }

    let store: PrivateSyncLocalStore
    let blobs: BlobStore
    let writer: MaintenanceWriter

    /// What `flushDelta` found.
    enum Flush: Equatable, Sendable {
        /// The pass has nothing pending.
        case nothingPending
        /// Some creates are not acknowledged yet; nothing was written.
        case waiting(remaining: Int)
        case written(entries: Int)
        /// The server held another version of the root: the save lost, nothing was removed.
        case lost
    }

    /// The root's zone and the `Content` zone the satellites go to; nil until the root is held.
    private func zones() async throws -> (library: BlobZone, content: BlobZone)? {
        try await store.perform { state in
            guard let library = try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: state),
                  let content = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state)
            else { return nil }
            return (library, content)
        }
    }

    /// Uploads `entries` as the satellite `role` of the root and returns its FileRef.
    func upload(_ entries: some Sequence<SeedManifestEntry>, role: String) async throws -> FileRef {
        guard let zones = try await zones() else { throw SeedManifestError.noRoot }
        return try await blobs.upload(
            SeedManifestCodec.encode(entries), owner: SyncSchema.rootRecordName, ownerType: .zoneRoot, role: role,
            mime: "application/json", encoding: .gzip, into: zones.content
        )
    }

    /// The seed's manifest: every record this Mac's replica holds in `Library` and `Catalog` (what the seeder
    /// uploaded and acknowledged, and the few another device wrote meanwhile: all of it was in the new
    /// world), and what a space pass listed under `passKey`. The caller writes the FileRef into
    /// `seed.manifest` in the same save as the canary's times.
    func uploadSeedManifest(passKey: String) async throws -> (file: FileRef, entries: Int) {
        let entries = try await store.perform { state -> [SeedManifestEntry] in
            var found: [SeedManifestEntry] = []
            try state.connection.query("""
                SELECT zone_key, record_type, wire_id FROM ck_records WHERE zone_key IN (?, ?) AND record_type <> ?
            """, [.text(PrivateSyncZones.libraryKey), .text(PrivateSyncZones.key(PrivateSyncZones.catalog)), .text(SyncRecordType.zoneRoot.rawValue)]) { row in
                if let entry = SeedManifestEntry(zoneKey: row.text(0) ?? "", type: row.text(1) ?? "", id: row.text(2) ?? "") { found.append(entry) }
            }
            for row in try SeedManifestPending.rows(passKey: passKey, in: state.connection) {
                if let entry = SeedManifestEntry(zoneKey: row.zoneKey, type: row.type, id: row.wireID) { found.append(entry) }
            }
            return found
        }
        return (try await upload(entries, role: Self.manifestRole), entries.count)
    }

    /// Forgets what the pass listed that the server does not hold, once nothing is left to send: such a record
    /// was never created, so it has no place in the delta.
    func dropUncreated(passKey: String) async throws {
        try await store.perform { try SeedManifestPending.removeUnacknowledged(passKey: passKey, in: $0.connection) }
    }

    /// Lists what the pass `passKey` created, once the server holds every one of them: uploads the delta
    /// satellite, then names it in the root's `manifestDeltas` under the pass key (each pass writes only
    /// its own key, so concurrent passes never collide) and, once that save is acknowledged, removes the
    /// pending rows.
    func flushDelta(passKey: String) async throws -> Flush {
        let (entries, waiting) = try await store.perform { state -> ([SeedManifestEntry], Int) in
            let rows = try SeedManifestPending.rows(passKey: passKey, in: state.connection)
            var acknowledged: [SeedManifestEntry] = []
            var waiting = 0
            for row in rows {
                if try SeedManifestPending.isAcknowledged(row, in: state.connection) {
                    if let entry = SeedManifestEntry(zoneKey: row.zoneKey, type: row.type, id: row.wireID) { acknowledged.append(entry) }
                } else {
                    waiting += 1
                }
            }
            return (acknowledged, waiting)
        }
        if entries.isEmpty, waiting == 0 { return .nothingPending }
        guard waiting == 0 else { return .waiting(remaining: waiting) }
        guard let zones = try await zones() else { throw SeedManifestError.noRoot }
        let file = try await upload(entries, role: Self.deltaRole(passKey: passKey))
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["manifestDeltas"] = .elements([passKey: file.value])
        guard try await writer.save([MaintenanceWriter.Write(zone: zones.library, patch: patch)]).first != .lost else { return .lost }
        try await store.perform { try SeedManifestPending.remove(passKey: passKey, in: $0.connection) }
        return .written(entries: entries.count)
    }
}

// MARK: - Reading

/// Everything the new world has held that this Mac may find missing on the server: the seed's manifest
/// and every delta the root names (§13.5). A reconcile deletes a local record the server lacks when it is
/// listed here, and uploads one that is in neither.
struct SeedManifestReader {
    let store: PrivateSyncLocalStore
    let blobs: BlobStore

    func load() async throws -> Set<SeedManifestEntry> {
        guard let (root, content) = try await store.perform({ state -> (SyncEnvelope, BlobZone)? in
            guard let root = try state.replica.personalRoot()?.envelope,
                  let content = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state)
            else { return nil }
            return (root, content)
        }) else { throw SeedManifestError.noRoot }
        var files: [FileRef] = []
        if let manifest = root.fields["seed"]?.objectValue?["manifest"], let file = FileRef(json: manifest) { files.append(file) }
        let deltas = root.fields["manifestDeltas"]?.objectValue ?? [:]
        for key in deltas.keys.sorted() {
            if let file = deltas[key].flatMap(FileRef.init(json:)) { files.append(file) }
        }
        var entries = Set<SeedManifestEntry>()
        for file in files {
            entries.formUnion(try SeedManifestCodec.decode(try await blobs.fetch(file, from: content)))
        }
        return entries
    }
}
