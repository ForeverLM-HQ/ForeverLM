import Foundation
import OSLog

/// The orphan janitor and `moveMaps` folding (docs/cloudkit-schema-design.md §5.7, §4.4, §3.5.1, D17,
/// D51, R3-m9, R4-m14), on the maintenance-lease Mac.
///
/// The janitor runs only after a round that fetched every private zone and every space to the end, so
/// a parent that has not arrived yet is never taken for a deleted one. In the zones this Mac can write
/// (`Library`, `Catalog` and the spaces it owns) it deletes, once a record has been an orphan for 7
/// days and was last written more than 7 days ago: Entries whose container is gone, Exchanges whose
/// chat is gone, Comments whose Doc is gone, Lessons and Quizzes whose course is gone; NotebookStates
/// and Enrollments 30 days after their notebook or course went; Jobs past `expiresAt` once they are
/// done, failed or cancelled (a queued Job never expires, so a capture waits for a Mac however long it
/// lags); and records named with another salt than their zone's. A parent counts as present when any
/// zone this Mac holds has it, or when `ZoneRoot.moveMaps` lists it as moved, so a late child a stale
/// device wrote into `Library` is left for re-homing (WP15b), never collected. A merged or moved
/// notebook is a stub record, never gone.
extension MaintenanceService {
    static let orphanAfter: TimeInterval = 7 * 86_400
    static let personalOrphanAfter: TimeInterval = 30 * 86_400
    /// Past this many entries the maintenance Mac folds `moveMaps` into one `folded.<n>` entry.
    static let moveMapsFoldAbove = 32
    /// `ck_engine_state` scope: when each orphan was first found, by zone key and record name.
    static let orphansScope = "maintenance.orphans"

    private static let janitorLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "OrphanJanitor")

    /// What a child names as its parent: the field, and the parent's record type from the child's own
    /// fields.
    static func parent(of envelope: SyncEnvelope) -> (type: SyncRecordType, id: String, after: TimeInterval)? {
        let fields = envelope.fields
        switch SyncRecordType(rawValue: envelope.type) {
        case .entry?:
            let kinds: [String: SyncRecordType] = ["notebook": .notebook, "goal": .goal, "lesson": .lesson, "playlist": .collection]
            guard let kind = fields["containerKind"]?.stringValue.flatMap({ kinds[$0] }), let id = fields["containerID"]?.stringValue else { return nil }
            return (kind, id, orphanAfter)
        case .exchange?:
            return fields["chatID"]?.stringValue.map { (.chat, $0, orphanAfter) }
        case .comment?:
            return fields["artifactID"]?.stringValue.map { (.artifact, $0, orphanAfter) }
        case .lesson?, .quiz?:
            return fields["courseID"]?.stringValue.map { (.course, $0, orphanAfter) }
        case .notebookState?:
            return fields["notebookID"]?.stringValue.map { (.notebook, $0, personalOrphanAfter) }
        case .enrollment?:
            return fields["courseID"]?.stringValue.map { (.course, $0, personalOrphanAfter) }
        default:
            return nil
        }
    }

    /// The newest stamp of a record: when anyone last wrote it.
    static func lastWritten(_ envelope: SyncEnvelope) -> Int64 {
        envelope.stamps.values.map { stamp -> Int64 in
            switch stamp {
            case .value(let stamp): return stamp.milliseconds
            case .elements(let stamps): return stamps.values.map(\.milliseconds).max() ?? 0
            }
        }.max() ?? 0
    }

    /// One janitor pass. Returns how many records it deleted.
    func runJanitor() async throws -> Int {
        let now = clockNow()
        if let (root, salt) = try await store.perform({ state -> (SyncEnvelope, Data)? in
            guard let root = try state.replica.personalRoot()?.envelope,
                  let salt = root.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
            else { return nil }
            return (root, salt)
        }) {
            // Every entry must be read: a parent listed only in an unreadable entry would look gone.
            guard await moveMaps.refresh(from: root, fetch: MoveMapIndex.transportFetch(transport, salt: salt)).isEmpty else {
                Self.janitorLogger.info("The janitor waits: a moveMaps entry could not be read")
                return 0
            }
        }
        let moveMaps = moveMaps
        let zoneKeys = try await store.perform { state -> [String] in
            var keys: [String] = []
            try state.connection.query("""
                SELECT zone_key FROM ck_zones WHERE database = 'private' AND (kind IN ('library', 'catalog') OR kind = 'space') ORDER BY zone_key
            """, []) { keys.append($0.text(0) ?? "") }
            return keys
        }
        let seconds = now.timeIntervalSinceReferenceDate
        let milliseconds = SyncTime.milliseconds(now)
        // Which records are orphans now, and since when.
        let (due, foreign) = try await store.perform { state -> ([String: [ReplicaRecord]], [String: [ReplicaRecord]]) in
            var since: [String: Double] = [:]
            if let data = try state.replica.engineState(Self.orphansScope), let json = try? SyncJSON(parsing: data) {
                since = (json.objectValue ?? [:]).compactMapValues(\.numberValue)
            }
            var present = Set<String>()
            try state.connection.query("SELECT record_type || char(31) || wire_id FROM ck_records", []) { present.insert($0.text(0) ?? "") }
            var stillOrphans: [String: Double] = [:]
            var due: [String: [ReplicaRecord]] = [:]
            for zoneKey in zoneKeys {
                var records: [ReplicaRecord] = []
                try state.connection.query("""
                    SELECT zone_key, record_name, record_type, wire_id, system_fields, payload, seen_pass FROM ck_records
                    WHERE zone_key = ? AND record_type IN ('Entry', 'Exchange', 'Comment', 'Lesson', 'Quiz', 'NotebookState', 'Enrollment', 'Job')
                """, [.text(zoneKey)]) { row in
                    records.append(ReplicaRecord(zoneKey: row.text(0) ?? "", recordName: row.text(1) ?? "", recordType: row.text(2) ?? "",
                                                 wireID: row.text(3) ?? "", systemFields: row.blob(4), payload: row.blob(5) ?? Data(), seenPass: row.real(6)))
                }
                for record in records {
                    guard let envelope = try? SyncEnvelope(storedPayload: record.payload) else { continue }
                    if record.recordType == SyncRecordType.job.rawValue {
                        let terminal = ["done", "failed", "cancelled"].contains(envelope.fields["status"]?.stringValue ?? "")
                        if terminal, let expires = envelope.fields["expiresAt"]?.int64Value, expires < milliseconds {
                            due[zoneKey, default: []].append(record)
                        }
                        continue
                    }
                    guard let parent = Self.parent(of: envelope),
                          !present.contains(parent.type.rawValue + "\u{1F}" + parent.id),
                          !moveMaps.moved(type: parent.type.rawValue, id: parent.id)
                    else { continue }
                    let key = zoneKey + "\u{1F}" + record.recordName
                    let first = since[key] ?? seconds
                    stillOrphans[key] = first
                    let written = SyncTime.cocoaSeconds(milliseconds: Self.lastWritten(envelope))
                    if first <= seconds - parent.after, written <= seconds - Self.orphanAfter {
                        due[zoneKey, default: []].append(record)
                    }
                }
            }
            try state.replica.setEngineState(Self.orphansScope, SyncJSON.object(stillOrphans.mapValues { SyncJSON.number($0) }).serialized(), now: now)

            var foreign: [String: [ReplicaRecord]] = [:]
            try state.connection.query(
                "SELECT zone_key, record_name, record_type, system_fields, payload FROM ck_quarantine WHERE reason = ?",
                [.text(InboundApply.foreignSaltReason)]
            ) { row in
                let zoneKey = row.text(0) ?? ""
                guard zoneKeys.contains(zoneKey) else { return }
                foreign[zoneKey, default: []].append(ReplicaRecord(zoneKey: zoneKey, recordName: row.text(1) ?? "", recordType: row.text(2) ?? "",
                                                                   wireID: "", systemFields: row.blob(3), payload: row.blob(4) ?? Data(), seenPass: nil))
            }
            return (due, foreign)
        }

        var deleted = 0
        for zoneKey in Set(due.keys).union(foreign.keys).sorted() {
            guard let zone = try await zone(zoneKey) else { continue }
            if let records = due[zoneKey], !records.isEmpty {
                let gone = try await writer.delete(records, in: zone)
                deleted += gone.count
                try await store.perform { state in
                    guard let data = try state.replica.engineState(Self.orphansScope), var since = (try? SyncJSON(parsing: data))?.objectValue else { return }
                    for name in gone { since[zoneKey + "\u{1F}" + name] = nil }
                    try state.replica.setEngineState(Self.orphansScope, SyncJSON.object(since).serialized(), now: now)
                }
            }
            if let records = foreign[zoneKey], !records.isEmpty {
                let ids = records.map { CloudRecordID($0.recordName, in: zone.zoneID) }
                let results = try await transport.modifyRecords(deleting: ids, in: zone.database)
                let gone = ids.filter { id in
                    switch results.deleted[id] {
                    case .success?: return true
                    case .failure(let error)?: return error.code == .unknownItem
                    case nil: return false
                    }
                }.map(\.recordName)
                try await store.perform { state in
                    for name in gone {
                        try state.connection.execute("DELETE FROM ck_quarantine WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(name)])
                    }
                }
                deleted += gone.count
            }
        }
        if deleted > 0 { Self.janitorLogger.info("The janitor deleted \(deleted) orphans") }
        return deleted
    }

    // MARK: moveMaps folding

    /// Folds the personal root's `moveMaps` into one `folded.<n>` entry once it holds more than 32
    /// (§3.5.1, D51): every entry is read, their moves go into one new list satellite, and one
    /// compare-and-set save of the root names it and clears the folded keys, so no pass's ids are lost
    /// and a concurrent pass's new key is never touched. Returns whether it folded.
    func foldMoveMaps(in library: BlobZone) async throws -> Bool {
        guard let root = try await store.perform({ try $0.replica.personalRoot()?.envelope }) else { return false }
        let entries = MoveMapIndex.entries(of: root)
        guard entries.count > Self.moveMapsFoldAbove else { return false }
        let fetch = MoveMapIndex.transportFetch(transport, salt: library.salt)
        var moves: [MoveMapMove] = []
        for (_, file) in entries {
            // An entry that cannot be read is never folded away.
            moves += try MoveMapIndex.decodeList(try await fetch(file))
        }
        let held = (root.fields["moveMaps"]?.objectValue ?? [:]).keys
        let next = (held.compactMap { key -> Int? in
            guard key.hasPrefix("folded.") else { return nil }
            return Int(key.dropFirst("folded.".count))
        }.max() ?? 0) + 1
        let key = "folded.\(next)"
        let list = try SyncGzip.decompress(try MoveMapIndex.encodeList(moves), maxBytes: MoveMapIndex.listMaxInflatedBytes)
        let file = try await blobs.upload(list, owner: SyncSchema.rootRecordName, ownerType: .zoneRoot, role: MoveMapIndex.role(forKey: key),
                                          mime: "application/json", encoding: .gzip, into: .personal(salt: library.salt))
        var changes: [String: SyncJSON] = [key: file.value]
        for (folded, _) in entries { changes[folded] = .null }
        let patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName, changes: ["moveMaps": .elements(changes)])
        guard try await writer.save([MaintenanceWriter.Write(zone: library, patch: patch)]).first == .saved else { return false }
        moveMaps.add(key: key, moves: moves)
        Self.janitorLogger.info("Folded \(entries.count) moveMaps entries into \(key, privacy: .public)")
        return true
    }
}
