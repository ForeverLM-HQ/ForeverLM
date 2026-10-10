import Foundation
import OSLog

/// Which satellites the records this Mac holds name (docs/cloudkit-schema-design.md §5.8 step 1): every
/// FileRef anywhere in a payload (a field, a map's value, a spilled field's `$file`, a Job's params),
/// with its `children`, expanded to one logical id per part. A value that only looks like a FileRef
/// counts too, which can keep a satellite longer, never delete one early.
enum SatelliteReach {
    static func contentIDs(in value: SyncJSON, into ids: inout Set<String>) {
        switch value {
        case .object(let object):
            if let file = FileRef(json: value) {
                ids.formUnion(file.satelliteIDs)
            }
            for child in object.values { contentIDs(in: child, into: &ids) }
        case .array(let items):
            for item in items { contentIDs(in: item, into: &ids) }
        default:
            break
        }
    }

    static func contentIDs(of envelope: SyncEnvelope) -> Set<String> {
        var ids = Set<String>()
        for value in envelope.fields.values { contentIDs(in: value, into: &ids) }
        return ids
    }

    /// Every satellite id the replica's records, the pending patches and this Mac's pending outbox
    /// changes name (§5.8 step 5: "its own pending FileRefs").
    static func reachable(in state: PrivateSyncLocalState, now: Date) throws -> Set<String> {
        var ids = Set<String>()
        try state.connection.query("SELECT payload FROM ck_records WHERE record_type <> ?", [.text(SyncRecordType.content.rawValue)]) { row in
            guard let payload = row.blob(0), let envelope = try? SyncEnvelope(storedPayload: payload) else { return }
            ids.formUnion(contentIDs(of: envelope))
        }
        // A record this build quarantined (an envelope version it cannot read) still names its satellites:
        // read as plain JSON, so a newer build's record keeps what it points at (F24).
        try state.connection.query("SELECT payload FROM ck_quarantine WHERE payload IS NOT NULL", []) { row in
            guard let bytes = row.blob(0) else { return }
            let text = SyncGzip.isGzip(bytes) ? (try? SyncGzip.decompress(bytes, maxBytes: SyncSchema.Limits.payloadMaxInflatedBytes)) : bytes
            guard let text, let json = try? SyncJSON(parsing: text) else { return }
            contentIDs(in: json, into: &ids)
        }
        try state.connection.query("SELECT patch_json FROM ck_patches", []) { row in
            guard let text = row.text(0), let json = try? SyncJSON(parsing: Data(text.utf8)) else { return }
            contentIDs(in: json, into: &ids)
        }
        let pending = try state.replica.apply { _ in try state.pendingChanges(now: now) }
        for change in pending {
            if case .save(let envelope) = change.action { ids.formUnion(contentIDs(of: envelope)) }
        }
        return ids
    }
}

/// What one zone's sweep did.
struct SatelliteSweepReport: Equatable, Sendable {
    var listed = 0
    var unreachable = 0
    var candidates = 0
    var deleted = 0
    /// Candidates the fresh fetch or the owner's re-read found named again.
    var kept = 0
}

/// Satellite garbage collection (docs/cloudkit-schema-design.md §5.8, D11, PD-11, R2-2, R3-m20), on the
/// maintenance-lease Mac once a day per zone it owns: private `Content` and each space it owns.
///
/// 1. List: `ck_blobs` (every satellite this account uploaded), with `Content`'s names-only walk
///    (`desiredKeys = []`) once a week; for a space, the `Content` records its walk holds.
/// 2. Mark: a satellite no record names gets `unreachable_since`; one named again loses it.
/// 3. Candidates: unreachable in two sweeps at least 7 days apart and created more than 60 days ago;
///    or, after 2 days, a superseded Doc or notes body, judged a whole body (one owner, role and file
///    `hash`) at a time: its owner's acknowledged pointer names another body of the same role, every
///    part of this one was created before the oldest part of the pointed one, every part was found
///    unreachable only after the pointer moved, and none is pinned as a pending edit's base.
/// 4. Before deleting: every change-fed zone is fetched to the end, the reachable set is built again
///    from the replica and this Mac's pending changes, each candidate's owner is read again by name,
///    and only what is still unreachable goes, 200 at a time.
extension MaintenanceService {
    static let gcSecondSweepAfter: TimeInterval = 7 * 86_400
    static let gcMinimumAge: TimeInterval = 60 * 86_400
    static let gcSupersededAfter: TimeInterval = 2 * 86_400
    static let gcContentWalkInterval: TimeInterval = 7 * 86_400
    static let gcBodyRole = "body"

    private static let gcLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SatelliteGC")

    /// The zones this Mac collects: private `Content`, and the spaces it owns (§5.8: a space's
    /// satellites are collected by its owner's maintenance Mac only).
    func collectedZones() async throws -> [String] {
        try await store.perform { state in
            var keys = [PrivateSyncZones.key(PrivateSyncZones.content)]
            try state.connection.query(
                "SELECT zone_key FROM ck_zones WHERE database = 'private' AND kind = 'space' ORDER BY zone_key", []
            ) { keys.append($0.text(0) ?? "") }
            return keys
        }
    }

    /// One sweep of one zone.
    func collectSatellites(in zoneKey: String) async throws -> SatelliteSweepReport {
        var report = SatelliteSweepReport()
        guard let zone = try await zone(zoneKey) else { return report }
        report.listed = try await listSatellites(in: zone)

        let now = clockNow()
        let sweep = now.timeIntervalSinceReferenceDate
        let reachable = try await reachableNames(in: zone, now: now)
        report.unreachable = try await store.perform { state in
            var unreachable = 0
            var rows: [(String, Bool)] = []
            try state.connection.query("SELECT record_name, pinned FROM ck_blobs WHERE zone_key = ?", [.text(zoneKey)]) { row in
                rows.append((row.text(0) ?? "", (row.integer(1) ?? 0) != 0))
            }
            for (name, pinned) in rows {
                if pinned || reachable.contains(name) {
                    try state.connection.execute("UPDATE ck_blobs SET unreachable_since = NULL WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(name)])
                } else {
                    unreachable += 1
                    try state.connection.execute(
                        "UPDATE ck_blobs SET unreachable_since = COALESCE(unreachable_since, ?) WHERE zone_key = ? AND record_name = ?",
                        [.real(sweep), .text(zoneKey), .text(name)]
                    )
                }
            }
            return unreachable
        }

        var candidates = try await candidates(in: zone, now: now)
        report.candidates = candidates.count
        guard !candidates.isEmpty else { return report }

        // Step 5: whatever was written since the sweep is in the replica before anything goes.
        guard await fetchEverything() else {
            Self.gcLogger.info("GC waits: a zone was not fetched to the end")
            return report
        }
        let fresh = try await reachableNames(in: zone, now: now)
        candidates = candidates.filter { !fresh.contains($0.recordName) }
        candidates = try await stillUnnamedByOwners(candidates, in: zone)
        report.kept = report.candidates - candidates.count
        report.deleted = try await deleteSatellites(candidates, in: zone)
        if report.deleted > 0 { Self.gcLogger.info("GC deleted \(report.deleted) satellites in \(zoneKey, privacy: .public)") }
        return report
    }

    // MARK: Listing

    /// Adds what the ledger does not know: `Content`'s names-only walk once a week, a space's `Content`
    /// records from its walk. Returns how many satellites the zone lists.
    private func listSatellites(in zone: BlobZone) async throws -> Int {
        let now = clockNow()
        if zone.isSpace {
            try await store.perform { state in
                var rows: [(String, SyncEnvelope)] = []
                try state.connection.query(
                    "SELECT record_name, payload FROM ck_records WHERE zone_key = ? AND record_type = ?",
                    [.text(zone.zoneKey), .text(SyncRecordType.content.rawValue)]
                ) { row in
                    if let payload = row.blob(1), let envelope = try? SyncEnvelope(storedPayload: payload) { rows.append((row.text(0) ?? "", envelope)) }
                }
                for (name, envelope) in rows { try Self.ledger(name, envelope: envelope, createdAt: nil, in: zone, state: state) }
            }
        } else {
            let scope = "maintenance.contentWalk.\(zone.zoneKey)"
            let due = try await store.perform { state -> Bool in
                guard let data = try state.replica.engineState(scope), let last = Double(String(decoding: data, as: UTF8.self)) else { return true }
                return now.timeIntervalSinceReferenceDate - last >= Self.gcContentWalkInterval
            }
            if due {
                var token: CloudChangeToken?
                while true {
                    let page = try await transport.zoneChanges(zone.zoneID, in: zone.database, since: token, desiredKeys: []).get()
                    let names = page.modified.map { ($0.id.recordName, $0.creationDate) }
                    try await store.perform { state in
                        for (name, created) in names { try Self.ledger(name, envelope: nil, createdAt: created, in: zone, state: state) }
                    }
                    guard page.moreComing else { break }
                    token = page.changeToken
                }
                try await store.perform { try $0.replica.setEngineState(scope, Data("\(now.timeIntervalSinceReferenceDate)".utf8), now: now) }
            }
        }
        return try await store.perform { state in
            Int(try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_blobs WHERE zone_key = ?", [.text(zone.zoneKey)]) ?? 0)
        }
    }

    /// A satellite the ledger learns from a walk: its identity when the payload is at hand, its
    /// creation date when the walk gave one. An acknowledged row keeps what it holds.
    private static func ledger(_ name: String, envelope: SyncEnvelope?, createdAt: Date?, in zone: BlobZone, state: PrivateSyncLocalState) throws {
        let fields = envelope?.fields ?? [:]
        try state.connection.execute("""
            INSERT INTO ck_blobs (zone_key, record_name, content_id, owner_id, role, part_hash, part_bytes, enc, server_created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET
                server_created_at = COALESCE(ck_blobs.server_created_at, excluded.server_created_at),
                content_id = CASE WHEN ck_blobs.content_id = '' THEN excluded.content_id ELSE ck_blobs.content_id END,
                owner_id = CASE WHEN ck_blobs.owner_id = '' THEN excluded.owner_id ELSE ck_blobs.owner_id END,
                role = CASE WHEN ck_blobs.role = '' THEN excluded.role ELSE ck_blobs.role END
        """, [
            .text(zone.zoneKey), .text(name), .text(envelope?.id ?? ""), .text(fields["ownerID"]?.stringValue ?? ""),
            .text(fields["role"]?.stringValue ?? ""), .text(fields["partHash"]?.stringValue ?? ""),
            .integer(fields["partBytes"]?.int64Value ?? 0), .text(fields["enc"]?.stringValue),
            .real(createdAt?.timeIntervalSinceReferenceDate),
        ])
    }

    private func reachableNames(in zone: BlobZone, now: Date) async throws -> Set<String> {
        let ids = try await store.perform { try SatelliteReach.reachable(in: $0, now: now) }
        return Set(ids.map { RecordNaming.recordName(type: .content, id: $0, salt: zone.salt) })
    }

    // MARK: Candidates

    struct Satellite: Hashable, Sendable {
        let recordName: String
        var owner: String
        var role: String
        var unreachableSince: Double
        var createdAt: Double?
    }

    private func candidates(in zone: BlobZone, now: Date) async throws -> [Satellite] {
        let sweep = now.timeIntervalSinceReferenceDate
        var unreachable = try await store.perform { state -> [Satellite] in
            var found: [Satellite] = []
            try state.connection.query("""
                SELECT record_name, owner_id, role, unreachable_since, server_created_at FROM ck_blobs
                WHERE zone_key = ? AND unreachable_since IS NOT NULL AND pinned = 0
            """, [.text(zone.zoneKey)]) { row in
                found.append(Satellite(recordName: row.text(0) ?? "", owner: row.text(1) ?? "", role: row.text(2) ?? "",
                                       unreachableSince: row.real(3) ?? sweep, createdAt: row.real(4)))
            }
            return found
        }
        // What the ledger does not know yet (a part another device uploaded, a walk's name) is read by
        // name once: its owner, role and creation date.
        let unknown = unreachable.filter { $0.createdAt == nil || $0.owner.isEmpty }.map(\.recordName)
        let described = try await describe(unknown, in: zone)
        for index in unreachable.indices {
            if let record = described[unreachable[index].recordName] {
                unreachable[index].owner = record.owner
                unreachable[index].role = record.role
                unreachable[index].createdAt = unreachable[index].createdAt ?? record.createdAt
            }
        }

        var chosen = unreachable.filter { satellite in
            guard let created = satellite.createdAt else { return false }
            return satellite.unreachableSince <= sweep - Self.gcSecondSweepAfter && created <= sweep - Self.gcMinimumAge
        }
        let taken = Set(chosen.map(\.recordName))
        let bodies = unreachable.filter { $0.role == Self.gcBodyRole && !taken.contains($0.recordName) && $0.unreachableSince <= sweep - Self.gcSupersededAfter }
        chosen += try await supersededBodies(bodies, in: zone)
        return chosen
    }

    /// A satellite's owner, role, file hash and creation date, read by name.
    private struct Described {
        let owner: String
        let ownerType: String
        let role: String
        let hash: String
        let parts: Int
        let createdAt: Double?
    }

    private func describe(_ names: [String], in zone: BlobZone) async throws -> [String: Described] {
        var described: [String: Described] = [:]
        for start in stride(from: 0, to: names.count, by: SyncSchema.Limits.batchMaxRecords) {
            let slice = names[start..<min(start + SyncSchema.Limits.batchMaxRecords, names.count)]
            let ids = slice.map { CloudRecordID($0, in: zone.zoneID) }
            let results = try await transport.records(ids, in: zone.database, desiredKeys: [CloudRecord.payloadKey])
            for id in ids {
                guard case .success(let record)? = results[id], let payload = record.payload,
                      let envelope = try? SyncEnvelope(storedPayload: payload)
                else { continue }
                let fields = envelope.fields
                described[id.recordName] = Described(
                    owner: fields["ownerID"]?.stringValue ?? "", ownerType: fields["ownerType"]?.stringValue ?? "",
                    role: fields["role"]?.stringValue ?? "", hash: fields["hash"]?.stringValue ?? "",
                    parts: fields["parts"]?.intValue ?? 1, createdAt: record.creationDate?.timeIntervalSinceReferenceDate
                )
            }
        }
        let known = described
        try await store.perform { state in
            for (name, item) in known {
                try state.connection.execute("""
                    UPDATE ck_blobs SET server_created_at = COALESCE(server_created_at, ?),
                        owner_id = CASE WHEN owner_id = '' THEN ? ELSE owner_id END, role = CASE WHEN role = '' THEN ? ELSE role END
                    WHERE zone_key = ? AND record_name = ?
                """, [.real(item.createdAt), .text(item.owner), .text(item.role), .text(zone.zoneKey), .text(name)])
            }
        }
        return described
    }

    /// The superseded-body fast path (R3-m20), a whole body at a time.
    private func supersededBodies(_ satellites: [Satellite], in zone: BlobZone) async throws -> [Satellite] {
        guard !satellites.isEmpty else { return [] }
        let described = try await describe(satellites.map(\.recordName), in: zone)
        var chosen: [Satellite] = []
        for (owner, parts) in Dictionary(grouping: satellites, by: \.owner) where !owner.isEmpty {
            // The owner's acknowledged pointer, and when it moved.
            guard let pointer = try await store.perform({ state -> (FileRef, Int64)? in
                var found: (FileRef, Int64)?
                try state.connection.query(
                    "SELECT payload FROM ck_records WHERE record_type = ? AND wire_id = ?", [.text(SyncRecordType.artifact.rawValue), .text(owner)]
                ) { row in
                    guard found == nil, let payload = row.blob(0), let envelope = try? SyncEnvelope(storedPayload: payload),
                          let value = envelope.fields[Self.gcBodyRole], let file = FileRef(json: value),
                          case .value(let stamp)? = envelope.stamps[Self.gcBodyRole]
                    else { return }
                    found = (file, stamp.milliseconds)
                }
                return found
            }), pointer.0.role == Self.gcBodyRole else { continue }
            let pointedNames = pointer.0.parts.map {
                RecordNaming.recordName(type: .content, id: SyncIdentity.contentID(owner: pointer.0.owner, role: pointer.0.role, partHash32: $0), salt: zone.salt)
            }
            let pointedCreated = try await describe(pointedNames, in: zone).values.compactMap(\.createdAt)
            guard pointedCreated.count == pointedNames.count, let pointedOldest = pointedCreated.min() else { continue }
            let movedAt = SyncTime.cocoaSeconds(milliseconds: pointer.1)
            let bodies = Dictionary(grouping: parts) { described[$0.recordName]?.hash ?? "" }
            for (hash, body) in bodies where !hash.isEmpty && hash != pointer.0.hash {
                // Every part of the body is listed (none is still uploading, none was found reachable),
                // every part was created before the pointed body's oldest, and was found unreachable
                // only after the pointer moved.
                let expected = body.compactMap { described[$0.recordName]?.parts }.max() ?? 0
                let created = body.compactMap { described[$0.recordName]?.createdAt }
                guard body.count == expected, created.count == expected, let newest = created.max(), newest < pointedOldest,
                      body.allSatisfy({ $0.unreachableSince >= movedAt }),
                      try await allPartsUnreachable(owner: owner, hash: hash, listed: body, in: zone)
                else { continue }
                chosen += body
            }
        }
        return chosen
    }

    /// Whether the ledger holds no other part of that body that a sweep found reachable or pinned:
    /// a body is judged whole, so one part still named or pinned keeps every part.
    private func allPartsUnreachable(owner: String, hash: String, listed: [Satellite], in zone: BlobZone) async throws -> Bool {
        let names = Set(listed.map(\.recordName))
        let others = try await store.perform { state -> [String] in
            var others: [String] = []
            try state.connection.query("""
                SELECT record_name FROM ck_blobs WHERE zone_key = ? AND owner_id = ? AND role = ? AND (unreachable_since IS NULL OR pinned = 1)
            """, [.text(zone.zoneKey), .text(owner), .text(Self.gcBodyRole)]) { others.append($0.text(0) ?? "") }
            return others.filter { !names.contains($0) }
        }
        guard !others.isEmpty else { return true }
        let described = try await describe(others, in: zone)
        return !described.values.contains { $0.hash == hash }
    }

    // MARK: Deleting

    /// Re-reads each candidate's owner by name and keeps every satellite an owner's payload names.
    private func stillUnnamedByOwners(_ candidates: [Satellite], in zone: BlobZone) async throws -> [Satellite] {
        let described = try await describe(candidates.map(\.recordName), in: zone)
        var ownerIDs: [CloudRecordID] = []
        for item in Set(described.values.map { "\($0.ownerType)\u{1F}\($0.owner)" }) {
            let parts = item.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2, let type = SyncRecordType(rawValue: parts[0]) else { continue }
            let zones = zone.isSpace ? [zone.zoneID] : PrivateSyncZones.engineZones
            for ownerZone in zones {
                ownerIDs.append(CloudRecordID(MaintenanceWriter.recordName(type, parts[1], in: zone), in: ownerZone))
            }
        }
        var named = Set<String>()
        for start in stride(from: 0, to: ownerIDs.count, by: SyncSchema.Limits.batchMaxRecords) {
            let slice = Array(ownerIDs[start..<min(start + SyncSchema.Limits.batchMaxRecords, ownerIDs.count)])
            let results = try await transport.records(slice, in: zone.database, desiredKeys: [CloudRecord.payloadKey])
            for id in slice {
                switch results[id] {
                case .success(let record)?:
                    if let payload = record.payload, let envelope = try? SyncEnvelope(storedPayload: payload) {
                        named.formUnion(SatelliteReach.contentIDs(of: envelope).map { RecordNaming.recordName(type: .content, id: $0, salt: zone.salt) })
                    }
                case .failure(let error)? where error.code == .unknownItem:
                    continue
                default:
                    // An owner that cannot be read now keeps its satellites until the next sweep.
                    return []
                }
            }
        }
        return candidates.filter { candidate in
            guard described[candidate.recordName] != nil else { return true }
            return !named.contains(candidate.recordName)
        }
    }

    private func deleteSatellites(_ satellites: [Satellite], in zone: BlobZone) async throws -> Int {
        var deleted = 0
        for start in stride(from: 0, to: satellites.count, by: SyncSchema.Limits.batchMaxRecords) {
            let slice = Array(satellites[start..<min(start + SyncSchema.Limits.batchMaxRecords, satellites.count)])
            let ids = slice.map { CloudRecordID($0.recordName, in: zone.zoneID) }
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
                    try state.connection.execute("DELETE FROM ck_blobs WHERE zone_key = ? AND record_name = ?", [.text(zone.zoneKey), .text(name)])
                    try state.replica.deleteRecord(zoneKey: zone.zoneKey, recordName: name)
                }
            }
            deleted += gone.count
        }
        return deleted
    }
}
