import Foundation
import OSLog

// MARK: - The Mac's store, as an import pass reads and writes it (docs/cloudkit-schema-design.md §13.6, WP16b)

/// What a pass queued in the store: the records it patched or created (a `ck_patches` row names them
/// until the server acknowledges them), the creates its manifest delta will list, and the records it
/// deleted.
struct MigrationAppliedPass: Equatable, Sendable {
    var patched: [MigrationRecordRef] = []
    var created: [MigrationRecordRef] = []
    var deleted: [MigrationRecordRef] = []
    /// Writes a pass could not place (the zone's root is not held yet): they are planned again next time.
    var unplaced = 0
}

/// Reads the world a pass plans against, and writes its plan as patches (§13.6): RecordPatches queued in
/// `ck_patches` with the old records' own stamps, and the patched record projected under the apply guard,
/// merged with this Mac's own unsent edits as an inbound version would be, so the triggers never queue
/// it a second time and a local edit is never overwritten. Every call runs inside
/// `PrivateSyncLocalStore.perform`, where the connection belongs.
enum MigrationImportStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationImport")
    /// Writes projected in one apply transaction.
    static let batchSize = 200

    // MARK: Which records a pass looks up

    /// Every record the pass has to know about: those its mappings give, what they hang from, the
    /// Recovered Doc a differing body would make, and what the base lists for each old record.
    static func keys(for inputs: [MigrationOldRecordInput]) -> Set<MigrationRecordKey> {
        var keys = Set<MigrationRecordKey>()
        for input in inputs {
            for record in input.old.mapping?.records ?? [] {
                keys.insert(MigrationRecordKey(record.type, record.id, spaceID: record.spaceID))
                if let parent = MigrationImportPlanner.parent(of: record) { keys.insert(parent) }
                if record.type == .artifact, let hash = LegacyFieldHashes.hashes(record)["body"] {
                    keys.insert(MigrationRecordKey(.artifact, MigrationBodyRule.recoveredID(artifactID: record.id, hash: hash), spaceID: record.spaceID))
                }
            }
            for baseKey in input.base?.records.keys ?? [:].keys {
                if let key = MigrationRecordKey(baseKey: baseKey, spaceID: input.old.spaceID) { keys.insert(key) }
            }
        }
        return keys
    }

    // MARK: The world

    /// A record located in the replica: the zone it is in, the server's copy, and this Mac's pending patch.
    struct Located {
        var zoneKey: String
        var replica: ReplicaRecord?
        var patch: PendingPatch?
    }

    /// Where the replica holds a record: a personal one in whichever zone has it (a moved record's copy
    /// in a space included), a space's in that space's zone; a record this Mac created and has not had
    /// acknowledged is found by its pending patch.
    static func locate(_ key: MigrationRecordKey, _ connection: SQLiteConnection) throws -> Located? {
        let replica = ReplicaStore(connection: connection)
        var zoneKeys: [String] = []
        if let spaceID = key.spaceID {
            try connection.query("SELECT zone_key FROM ck_zones WHERE zone_name = ? ORDER BY database = 'private' DESC, zone_key", [.text(SyncSchema.spaceZonePrefix + spaceID)]) {
                zoneKeys.append($0.text(0) ?? "")
            }
        } else {
            try connection.query("""
                SELECT zone_key FROM ck_records WHERE record_type = ? AND wire_id = ?
                ORDER BY zone_key LIKE 'shared/%', zone_key
            """, [.text(key.type.rawValue), .text(key.id)]) { zoneKeys.append($0.text(0) ?? "") }
            try connection.query("""
                SELECT zone_key FROM ck_patches WHERE record_type = ? AND wire_id = ?
                ORDER BY zone_key LIKE 'shared/%', zone_key
            """, [.text(key.type.rawValue), .text(key.id)]) { zoneKeys.append($0.text(0) ?? "") }
        }
        for zoneKey in zoneKeys {
            let held = try replica.record(zoneKey: zoneKey, recordType: key.type.rawValue, wireID: key.id)
            let patch = try PendingPatch.load(zoneKey: zoneKey, type: key.type.rawValue, wireID: key.id, in: connection)
            if held != nil || patch != nil { return Located(zoneKey: zoneKey, replica: held, patch: patch) }
        }
        return nil
    }

    /// The world for `keys`: each record as this Mac holds it, the ones the manifest lists, the spaces it
    /// holds, the bodies it has edited itself, and the records only its rows hold. With `ownRows` (the
    /// refresh's and the deferred catch-up's world) a record only its rows hold is held, as the rows encode
    /// it, with no replica copy and no stamps, and the records with a change of this Mac's own that is not
    /// sent are listed (`hasLocalChange`); otherwise such a record is left to its reconcile (`isLocalOnly`).
    static func snapshot(
        keys: Set<MigrationRecordKey>, listed: Set<MigrationRecordKey>, probe: MigrationBodyEditProbe?,
        connection: SQLiteConnection, registry: ProjectionRegistry = KnowledgeStore.projectionRegistry, ownRows: Bool = false
    ) throws -> MigrationWorldSnapshot {
        var snapshot = MigrationWorldSnapshot()
        snapshot.listed = listed
        if ownRows { snapshot.localChanges = try localChanges(among: keys, connection: connection, registry: registry) }
        for key in keys {
            // A space counts only when this Mac may write to it: its own, or a joined one on a roster that says
            // read-write. A patch SpaceSync would refuse is never queued, so it can never be offered for ever
            // and hold the pass's acknowledgement (F3); the old record waits instead.
            if let spaceID = key.spaceID,
               try connection.scalarInteger("""
                   SELECT EXISTS(SELECT 1 FROM ck_zones WHERE zone_name = ? AND (database = 'private' OR permission = ?))
               """, [.text(SyncSchema.spaceZonePrefix + spaceID), .text(CloudShare.Permission.readWrite.rawValue)]) == 1 {
                snapshot.spaces.insert(spaceID)
            }
            guard let located = try locate(key, connection) else {
                if try isLocalOnly(key, registry: registry, connection: connection) {
                    if ownRows, let rows = try ownRowsEnvelope(key, saltID: "", registry: registry, connection: connection) {
                        snapshot.records[key] = MigrationHeldRecord(
                            merged: rows, inReplica: false, replicaBodyHash: rows.fields["body"].flatMap(FileRef.init(json:))?.hash, pendingBodyHash: nil
                        )
                        if key.type == .artifact, let probe, try holdsOwnBodyEdit(key.id, probe: probe) { snapshot.ownEdits.insert(key) }
                    } else {
                        snapshot.localOnly.insert(key)
                    }
                }
                continue
            }
            let replicaEnvelope = located.replica.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            let saltID = try ReplicaStore(connection: connection).zone(key: located.zoneKey)?.saltID ?? ""
            var merged = replicaEnvelope ?? SyncEnvelope.new(key.type, id: key.id, saltID: saltID)
            if let patch = located.patch { merged = patch.applied(to: merged) }
            snapshot.records[key] = MigrationHeldRecord(
                merged: merged, inReplica: located.replica != nil,
                replicaBodyHash: replicaEnvelope?.fields["body"].flatMap(FileRef.init(json:))?.hash,
                pendingBodyHash: located.patch?.changes["body"].flatMap(FileRef.init(json:))?.hash
            )
            if key.type == .artifact, key.spaceID == nil, let probe, try holdsOwnBodyEdit(key.id, probe: probe) { snapshot.ownEdits.insert(key) }
        }
        // A pass's own edit probe for records that are not in the replica yet (a Doc this Mac holds locally).
        for key in keys where key.type == .artifact && key.spaceID == nil && snapshot.records[key] == nil {
            if let probe, try holdsOwnBodyEdit(key.id, probe: probe) { snapshot.ownEdits.insert(key) }
        }
        return snapshot
    }

    private static func holdsOwnBodyEdit(_ artifactID: String, probe: MigrationBodyEditProbe) throws -> Bool {
        if let notebookID = NotesDoc.notebookID(of: artifactID) { return try probe.notesHoldOwnEdit(notebookID: notebookID) }
        return try probe.docHoldsOwnEdit(artifactID: artifactID)
    }

    /// The record as this Mac's rows encode it: a new envelope holding the encoded fields, with no stamps.
    static func ownRowsEnvelope(
        _ key: MigrationRecordKey, saltID: String, registry: ProjectionRegistry, connection: SQLiteConnection
    ) throws -> SyncEnvelope? {
        guard key.spaceID == nil, let projection = registry.projection(for: key.type) else { return nil }
        let reference = ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: key.type, wireID: key.id, localID: key.id)
        guard let fields = try projection.encode(reference, connection: connection) else { return nil }
        return SyncEnvelope(type: key.type.rawValue, id: key.id, saltID: saltID, fields: fields)
    }

    /// The records among `keys` that have a change of this Mac's own waiting in the outbox.
    private static func localChanges(
        among keys: Set<MigrationRecordKey>, connection: SQLiteConnection, registry: ProjectionRegistry
    ) throws -> Set<MigrationRecordKey> {
        // A change is a row of `ck_outbox_fields` (an edit or a create) or of `ck_outbox` (a removal).
        guard try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_outbox_fields) OR EXISTS(SELECT 1 FROM ck_outbox)") == 1 else { return [] }
        var found = Set<MigrationRecordKey>()
        for change in try OutboxFeeder(connection: connection, registry: registry).pendingChanges(now: Date()) {
            var spaceID: String?
            if case .space(let id) = change.zone { spaceID = id }
            let key = MigrationRecordKey(change.recordType, change.wireID, spaceID: spaceID)
            if keys.contains(key) { found.insert(key) }
        }
        return found
    }

    /// Whether this Mac's rows hold the record while neither the replica nor a pending patch does.
    private static func isLocalOnly(_ key: MigrationRecordKey, registry: ProjectionRegistry, connection: SQLiteConnection) throws -> Bool {
        guard key.spaceID == nil, let projection = registry.projection(for: key.type) else { return false }
        let reference = ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: key.type, wireID: key.id, localID: key.id)
        return try projection.encode(reference, connection: connection) != nil
    }

    // MARK: Writing a plan

    /// Queues the plan's writes as patches and projects them, in apply transactions of `batchSize`, then
    /// makes the deletions as local deletes outside the guard, so the triggers send them as they would the
    /// learner's own. `passKey` is `<deviceID>.<passID>`: the creates are listed under it in
    /// `ck_manifest_pending` until its delta is written.
    static func apply(
        _ plan: MigrationPassPlan, passKey: String, state: PrivateSyncLocalState, now: Date,
        registry: ProjectionRegistry = KnowledgeStore.projectionRegistry, ownRows: Bool = false
    ) throws -> MigrationAppliedPass {
        var applied = MigrationAppliedPass()
        for start in stride(from: 0, to: plan.writes.count, by: batchSize) {
            let batch = Array(plan.writes[start..<min(start + batchSize, plan.writes.count)])
            try state.replica.apply { _ in
                // This Mac's own unsent edits, encoded once for the batch: a patched record meets them as an
                // inbound version of it would (§6.2).
                var pending: [String: OutboxChange] = [:]
                for change in try state.pendingChanges(now: now) { pending[change.zoneKey + "\u{1F}" + change.recordName] = change }
                for write in batch {
                    try queue(write, passKey: passKey, state: state, pending: pending, now: now, ownRows: ownRows, registry: registry, applied: &applied)
                }
            }
        }
        for removal in plan.deletions {
            if let reference = try delete(removal, state: state, registry: registry, ownRows: ownRows) { applied.deleted.append(reference) }
        }
        return applied
    }

    private static func queue(
        _ write: MigrationWrite, passKey: String, state: PrivateSyncLocalState, pending: [String: OutboxChange], now: Date,
        ownRows: Bool, registry: ProjectionRegistry, applied: inout MigrationAppliedPass
    ) throws {
        let connection = state.connection
        let key = write.key
        let located = try locate(key, connection)
        // An old record's removal of a record only this Mac's rows hold: the server never held it, so no patch
        // is queued for it (a skeleton would be sent), and its rows go (§13.3, R5-4).
        if ownRows, write.removes, located?.replica == nil, let store = connection as? KnowledgeStore {
            if let patch = located?.patch { try PendingPatch.delete(zoneKey: patch.zoneKey, type: key.type.rawValue, wireID: key.id, in: connection) }
            if let reference = try deleteRows(of: key, store: store, registry: registry) { applied.deleted.append(reference) }
            return
        }
        let zoneKey: String
        if let located {
            zoneKey = located.zoneKey
        } else {
            let placement = ReplicaPlacement(connection: connection)
            var fields: [String: SyncJSON] = [:]
            // A record only this Mac's rows hold is placed by what those rows say (an Exchange by its chat),
            // as a patch of a few fields would not name it.
            if ownRows, !write.creates, let rows = try ownRowsEnvelope(key, saltID: "", registry: registry, connection: connection) {
                fields = rows.fields
            }
            for (field, change) in write.changes {
                switch change {
                case .value(let value): fields[field] = value
                case .elements(let elements): fields[field] = .object(elements)
                }
            }
            let zone = ZonePlacement.zone(for: key.type, id: key.id, fields: fields, writtenIn: key.spaceID.map(SyncZoneName.space) ?? .library, replica: placement)
            guard let placed = try placement.zoneKey(of: zone) else {
                applied.unplaced += 1
                return
            }
            zoneKey = placed
        }
        guard let zone = try BlobZone.resolve(zoneKey: zoneKey, in: state) else {
            applied.unplaced += 1
            return
        }

        var patch = located?.patch ?? PendingPatch(changes: [:], stamps: [:], zoneKey: zoneKey, type: key.type.rawValue, wireID: key.id)
        fold(write, into: &patch)
        guard !patch.stamps.isEmpty else { return }
        try patch.save(in: connection, now: now)

        let held = located?.replica
        let recordName = held?.recordName ?? RecordNaming.recordName(type: key.type, id: key.id, salt: zone.salt)
        let replicaEnvelope = held.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
        let server = replicaEnvelope ?? SyncEnvelope.new(key.type, id: key.id, saltID: RecordNaming.saltID(zone.salt))
        var local = server
        // A record only this Mac's rows hold (the refresh's and the deferred catch-up's world) is patched over
        // what those rows encode, so projecting it writes every column it already holds as it holds it.
        if replicaEnvelope == nil, ownRows, !write.creates,
           let rows = try ownRowsEnvelope(key, saltID: RecordNaming.saltID(zone.salt), registry: registry, connection: connection) {
            local = rows
        }
        var mintedAgainst: [StampedPath: SyncStamp] = [:]
        if let change = pending[zoneKey + "\u{1F}" + recordName], case .save(let envelope) = change.action {
            local = envelope
            mintedAgainst = change.mintedAgainst
        }
        local = patch.applied(to: local)
        let merged = replicaEnvelope == nil ? local : FieldMerge.merge(server: server, local: local, base: replicaEnvelope, mintedAgainst: mintedAgainst).merged
        try state.project(ReplicaRecord(
            zoneKey: zoneKey, recordName: recordName, recordType: key.type.rawValue, wireID: key.id,
            systemFields: held?.systemFields, payload: try merged.storedPayload(), seenPass: held?.seenPass
        ))

        let reference = MigrationRecordRef(zoneKey: zoneKey, type: key.type.rawValue, id: key.id)
        applied.patched.append(reference)
        if write.creates {
            applied.created.append(reference)
            try connection.execute("""
                INSERT INTO ck_manifest_pending (pass_key, zone_key, record_type, wire_id) VALUES (?, ?, ?, ?)
                ON CONFLICT(pass_key, zone_key, record_type, wire_id) DO NOTHING
            """, [.text(passKey), .text(zoneKey), .text(key.type.rawValue), .text(key.id)])
        }
    }

    /// Lays a write's stamped values over a record's pending patch, field by field (a map or set element
    /// by element), the later stamp winning.
    static func fold(_ write: MigrationWrite, into patch: inout PendingPatch) {
        for (field, change) in write.changes.sorted(by: { $0.key < $1.key }) {
            switch change {
            case .value(let value):
                guard let stamp = write.stamps[StampedPath(field)] else { continue }
                if case .value(let held)? = patch.stamps[field], !stamp.isLater(than: held) { continue }
                patch.changes[field] = value
                patch.stamps[field] = .value(stamp)
            case .elements(let elements):
                var values = patch.changes[field]?.objectValue ?? [:]
                var stamps: [String: SyncStamp] = if case .elements(let held)? = patch.stamps[field] { held } else { [:] }
                for (element, value) in elements.sorted(by: { $0.key < $1.key }) {
                    guard let stamp = write.stamps[StampedPath(field, element: element)] else { continue }
                    if let held = stamps[element], !stamp.isLater(than: held) { continue }
                    values[element] = value
                    stamps[element] = stamp
                }
                guard !stamps.isEmpty else { continue }
                patch.changes[field] = .object(values)
                patch.stamps[field] = .elements(stamps)
            }
        }
    }

    /// A removal of an owned record that is not a flip: its rows go through the projection's own deletion,
    /// outside the guard, so the outbox sends the delete. Per-member state keeps its rows by the
    /// projection's own rules (D18). Returns the record, nil when this Mac holds none.
    private static func delete(
        _ removal: MigrationRemoval, state: PrivateSyncLocalState, registry: ProjectionRegistry, ownRows: Bool
    ) throws -> MigrationRecordRef? {
        if ownRows, let store = state.connection as? KnowledgeStore, try locate(removal.key, store) == nil {
            return try deleteLocalOnly(removal, state: state, store: store, registry: registry)
        }
        guard let store = state.connection as? KnowledgeStore, let located = try locate(removal.key, store), let held = located.replica,
              let projection = registry.projection(for: removal.key.type)
        else { return nil }
        let reference = try ProjectionApply(store: store, registry: registry).reference(zoneKey: located.zoneKey, type: removal.key.type, wireID: removal.key.id)
        try PendingPatch.delete(zoneKey: located.zoneKey, type: removal.key.type.rawValue, wireID: removal.key.id, in: store)
        try projection.applyDeletion(reference, connection: store)
        logger.notice("An old record's deletion took \(removal.key.type.rawValue, privacy: .public) \(held.recordName, privacy: .private)")
        return MigrationRecordRef(zoneKey: located.zoneKey, type: removal.key.type.rawValue, id: removal.key.id)
    }

    /// A removal of a record only this Mac's rows hold: the server holds nothing, so no delete is sent. The
    /// rows go through the projection's own deletion inside an apply, so no trigger queues one.
    private static func deleteLocalOnly(
        _ removal: MigrationRemoval, state: PrivateSyncLocalState, store: KnowledgeStore, registry: ProjectionRegistry
    ) throws -> MigrationRecordRef? {
        try state.replica.apply { _ in try deleteRows(of: removal.key, store: store, registry: registry) }
    }

    /// The rows of a record only this Mac's rows hold, through the projection's own deletion. Runs inside an
    /// apply, so no trigger queues a delete for a record the server never held.
    private static func deleteRows(of key: MigrationRecordKey, store: KnowledgeStore, registry: ProjectionRegistry) throws -> MigrationRecordRef? {
        guard key.spaceID == nil, let projection = registry.projection(for: key.type) else { return nil }
        let reference = ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: key.type, wireID: key.id, localID: key.id)
        guard try projection.encode(reference, connection: store) != nil else { return nil }
        try projection.applyDeletion(reference, connection: store)
        logger.notice("An old record's removal took this Mac's own \(key.type.rawValue, privacy: .public)")
        return MigrationRecordRef(zoneKey: PrivateSyncZones.libraryKey, type: key.type.rawValue, id: key.id)
    }

    // MARK: Acknowledgement

    /// Whether a record's patch has been sent and acknowledged: no `ck_patches` row names it any more.
    static func isAcknowledged(_ patched: MigrationRecordRef, _ connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_patches WHERE zone_key = ? AND record_type = ? AND wire_id = ?)",
            [.text(patched.zoneKey), .text(patched.type), .text(patched.id)]
        ) != 1
    }

    /// Whether the replica no longer holds a record this pass deleted.
    static func isGone(_ deleted: MigrationRecordRef, _ connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_records WHERE zone_key = ? AND record_type = ? AND wire_id = ?)",
            [.text(deleted.zoneKey), .text(deleted.type), .text(deleted.id)]
        ) != 1
    }

    // MARK: Manifest deltas

    /// The passes whose creates are all acknowledged, with the records to list. A create that is no longer
    /// anywhere (deleted before it went out) is not listed and holds nothing back; one still pending holds
    /// its pass's delta back.
    static func completedDeltas(_ connection: SQLiteConnection) throws -> [(passKey: String, records: [MigrationRecordKey])] {
        var rows: [(pass: String, ref: MigrationRecordRef)] = []
        try connection.query("SELECT pass_key, zone_key, record_type, wire_id FROM ck_manifest_pending ORDER BY pass_key, zone_key, record_type, wire_id", []) { row in
            rows.append((row.text(0) ?? "", MigrationRecordRef(zoneKey: row.text(1) ?? "", type: row.text(2) ?? "", id: row.text(3) ?? "")))
        }
        var passes: [String: [MigrationRecordRef]] = [:]
        for row in rows { passes[row.pass, default: []].append(row.ref) }
        var completed: [(passKey: String, records: [MigrationRecordKey])] = []
        for (passKey, refs) in passes.sorted(by: { $0.key < $1.key }) {
            var listed: [MigrationRecordKey] = []
            var waiting = false
            for ref in refs {
                guard let type = SyncRecordType(rawValue: ref.type) else { continue }
                let inReplica = try connection.scalarInteger(
                    "SELECT EXISTS(SELECT 1 FROM ck_records WHERE zone_key = ? AND record_type = ? AND wire_id = ?)",
                    [.text(ref.zoneKey), .text(ref.type), .text(ref.id)]
                ) == 1
                let pending = try !isAcknowledged(ref, connection)
                if inReplica && !pending {
                    var spaceID: String?
                    if case .space(let id)? = ProjectionZones.zone(ofKey: ref.zoneKey) { spaceID = id }
                    listed.append(MigrationRecordKey(type, ref.id, spaceID: spaceID))
                } else if pending {
                    waiting = true
                }
            }
            if !waiting { completed.append((passKey, listed)) }
        }
        return completed
    }

    static func clearPending(passKey: String, _ connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_manifest_pending WHERE pass_key = ?", [.text(passKey)])
    }
}

// MARK: - This Mac's own edit of a body

/// `MigrationBodyEditProbe` on the store (§13.6, R7-3, R8-1, R8-m3): the catch-up's own test for a Doc
/// (`MigrationBodies.docOwnEdit`), and for a Notes Doc a `ck_outbox_fields` row on the notes or notes that
/// differ from the notes base.
struct StoreMigrationBodyEditProbe: MigrationBodyEditProbe, @unchecked Sendable {
    let store: KnowledgeStore

    func docHoldsOwnEdit(artifactID: String) throws -> Bool {
        try MigrationBodies.docOwnEdit(artifactID, store: store)
    }

    func notesHoldOwnEdit(notebookID: String) throws -> Bool {
        if try store.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_outbox_fields WHERE source_table = 'learning_goals' AND local_key = ? AND \"column\" = 'notes')",
            [.text(notebookID)]
        ) == 1 {
            return true
        }
        guard let base = try NotesBase.load(notebookID: notebookID, connection: store) else { return false }
        let notes = try store.scalarText("SELECT notes FROM learning_goals WHERE id = ?", [.text(notebookID)])
        return NotesDoc.text(notes) != NotesDoc.text(base)
    }
}
