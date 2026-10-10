import Foundation

// MARK: - Sending the patches a Mac queued (docs/cloudkit-schema-design.md §6.6, §13.6)

/// The Mac's `ck_patches` rows as the changes the private engine and SpaceSync send: late import's patches,
/// stamped with the old records' modification dates, and listen positions read from iCloud Drive files. The
/// outbox feeder sends rows the triggers recorded and nothing else, which is why the first package that
/// writes patches on the Mac adds this (WP4c's open item). It is the Mac twin of the phone's
/// `MobilePatchOutbox`.
///
/// Each patch goes onto the raw payload the replica holds (a new envelope for a record made here) and is
/// sent on its change tag. A record that also has a change from the outbox gets both in one save, field by
/// field by stamp (§6.6); a record whose delete is on its way waits. An acknowledgement takes exactly the
/// paths the save carried, so a patch folded in while it was out survives it.
struct MacPatchOutbox {
    let connection: SQLiteConnection

    private var replica: ReplicaStore { ReplicaStore(connection: connection) }

    static func debounce(_ type: SyncRecordType) -> TimeInterval {
        switch type {
        case .readingState, .sitting: return 30
        case .activityLog: return 300
        default: return 2
        }
    }

    static func priority(_ type: SyncRecordType) -> OutboxPriority {
        type.spec.isPrivateOnly ? .personal : .structure
    }

    /// The feeder's changes with the patches laid over the records they name, and the patches of records
    /// the feeder has nothing for, at most `limit` changes in all.
    func changes(now: Date, limit: Int, scope: OutboxScope, alongside feeder: [OutboxChange]) throws -> [OutboxChange] {
        let nowSeconds = now.timeIntervalSinceReferenceDate
        var rows: [(zoneKey: String, type: SyncRecordType, wireID: String)] = []
        try connection.query("SELECT zone_key, record_type, wire_id, dirty_at FROM ck_patches ORDER BY dirty_at, zone_key, wire_id", []) { row in
            guard let type = SyncRecordType(rawValue: row.text(1) ?? ""), (row.real(3) ?? 0) <= nowSeconds - Self.debounce(type) else { return }
            rows.append((row.text(0) ?? "", type, row.text(2) ?? ""))
        }
        guard !rows.isEmpty else { return feeder }
        // A family the cutover seed has not begun waits for its pass, patches as outbox rows (§13.4 step 5).
        let heldTypes = try replica.seedHeldTypes()
        rows.removeAll { heldTypes.contains($0.type) }
        var result = feeder
        var salts: [String: Data?] = [:]
        for row in rows {
            guard let zone = ProjectionZones.zone(ofKey: row.zoneKey), scope.admits(zone),
                  let patch = try PendingPatch.load(zoneKey: row.zoneKey, type: row.type.rawValue, wireID: row.wireID, in: connection),
                  !patch.stamps.isEmpty
            else { continue }
            if let index = result.firstIndex(where: { $0.zoneKey == row.zoneKey && $0.recordType == row.type && $0.wireID == row.wireID }) {
                if let merged = Self.lay(patch, over: result[index]) { result[index] = merged }
                continue
            }
            guard result.count < limit else { break }
            if salts[row.zoneKey] == nil { salts[row.zoneKey] = try salt(zoneKey: row.zoneKey, zone: zone) }
            guard let salt = salts[row.zoneKey] ?? nil, let change = try save(patch, zone: zone, salt: salt) else { continue }
            result.append(change)
        }
        return result
    }

    /// One record's save: the replica's raw payload (a new envelope for a record made here) with the
    /// pending patch laid over it. Waits while a delete of the record is still on its way.
    private func save(_ patch: PendingPatch, zone: SyncZoneName, salt: Data) throws -> OutboxChange? {
        guard let type = SyncRecordType(rawValue: patch.type) else { return nil }
        let held = try replica.record(zoneKey: patch.zoneKey, recordType: patch.type, wireID: patch.wireID)
        let recordName = held?.recordName ?? RecordNaming.recordName(type: type, id: patch.wireID, salt: salt)
        if try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)", [.text(patch.zoneKey), .text(recordName)]
        ) == 1 {
            return nil
        }
        let base: SyncEnvelope
        if let held {
            guard let decoded = try? SyncEnvelope(storedPayload: held.payload) else { return nil }
            base = decoded
        } else {
            base = SyncEnvelope.new(type, id: patch.wireID, saltID: RecordNaming.saltID(salt))
        }
        var envelope = patch.applied(to: base)
        envelope.rev = SyncSchema.schemaRevision
        return OutboxChange(
            zoneKey: patch.zoneKey, zone: zone, recordType: type, wireID: patch.wireID, recordName: recordName, systemFields: held?.systemFields,
            action: .save(envelope), priority: Self.priority(type), stamps: Self.flattened(patch.stamps), mintedAgainst: [:], rows: []
        )
    }

    /// The patch's paths laid over a change the feeder made for the same record, each where its stamp is
    /// later than the change's.
    static func lay(_ patch: PendingPatch, over change: OutboxChange) -> OutboxChange? {
        guard case .save(var envelope) = change.action else { return nil }
        var stamps = change.stamps
        for (field, stamp) in patch.stamps.sorted(by: { $0.key < $1.key }) {
            switch stamp {
            case .value(let patched):
                let path = StampedPath(field)
                var current = stamps[path]
                if current == nil, case .value(let held)? = envelope.stamps[field] { current = held }
                if let current, !patched.isLater(than: current) { continue }
                envelope.fields[field] = patch.changes[field] ?? .null
                envelope.stamps[field] = .value(patched)
                stamps[path] = patched
            case .elements(let elements):
                var values = envelope.fields[field]?.objectValue ?? [:]
                var held: [String: SyncStamp] = if case .elements(let existing)? = envelope.stamps[field] { existing } else { [:] }
                for (element, patched) in elements.sorted(by: { $0.key < $1.key }) {
                    let path = StampedPath(field, element: element)
                    if let current = stamps[path] ?? held[element], !patched.isLater(than: current) { continue }
                    values[element] = patch.changes[field]?.objectValue?[element] ?? .null
                    held[element] = patched
                    stamps[path] = patched
                }
                envelope.fields[field] = .object(values)
                envelope.stamps[field] = .elements(held)
            }
        }
        envelope.rev = SyncSchema.schemaRevision
        return OutboxChange(
            zoneKey: change.zoneKey, zone: change.zone, recordType: change.recordType, wireID: change.wireID, recordName: change.recordName,
            systemFields: change.systemFields, action: .save(envelope), priority: change.priority, stamps: stamps,
            mintedAgainst: change.mintedAgainst, rows: change.rows
        )
    }

    /// The salt names are made with: the personal root's for the private zones, a space's own root's.
    private func salt(zoneKey: String, zone: SyncZoneName) throws -> Data? {
        let rootKey = zone.isSpace ? zoneKey : PrivateSyncZones.libraryKey
        guard let root = try replica.record(zoneKey: rootKey, recordName: SyncSchema.rootRecordName),
              let envelope = try? SyncEnvelope(storedPayload: root.payload)
        else { return nil }
        return envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
    }

    // MARK: Settling

    /// A save landed: the paths it carried leave the pending patch, unless written again since.
    static func settle(_ change: OutboxChange, in connection: SQLiteConnection) throws {
        guard case .save = change.action,
              var patch = try PendingPatch.load(zoneKey: change.zoneKey, type: change.recordType.rawValue, wireID: change.wireID, in: connection)
        else { return }
        for (path, sent) in change.stamps {
            switch patch.stamps[path.field] {
            case .value(let held)? where path.element == nil && held == sent:
                patch.stamps[path.field] = nil
                patch.changes[path.field] = nil
            case .elements(var held)? where path.element.map({ held[$0] == sent }) == true:
                guard let element = path.element else { continue }
                held[element] = nil
                var values = patch.changes[path.field]?.objectValue ?? [:]
                values[element] = nil
                patch.stamps[path.field] = held.isEmpty ? nil : .elements(held)
                patch.changes[path.field] = held.isEmpty ? nil : .object(values)
            default:
                continue
            }
        }
        if patch.stamps.isEmpty {
            try PendingPatch.delete(zoneKey: patch.zoneKey, type: patch.type, wireID: patch.wireID, in: connection)
        } else {
            try patch.save(in: connection, now: Date())
        }
    }

    static func flattened(_ stamps: [String: SyncFieldStamp]) -> [StampedPath: SyncStamp] {
        var paths: [StampedPath: SyncStamp] = [:]
        for (field, stamp) in stamps {
            switch stamp {
            case .value(let stamp): paths[StampedPath(field)] = stamp
            case .elements(let elements): for (element, stamp) in elements { paths[StampedPath(field, element: element)] = stamp }
            }
        }
        return paths
    }
}
