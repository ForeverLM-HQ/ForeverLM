import Foundation
import OSLog
import SQLite3

/// One outbox row a change covers, with the time it had when the change was made. The change's
/// acknowledgement deletes exactly these rows when their time has not moved since (§6.6 step 6).
struct OutboxRowSnapshot: Hashable, Sendable {
    let sourceTable: String
    let localKey: String
    /// The column of a `ck_outbox_fields` row; nil for the `ck_outbox` row of a removal.
    let column: String?
    let dirtyAt: Double
}

/// A record the feeder hands to the engine (private zones) or to SpaceSync (spaces): the replica's
/// raw payload patched with the changed fields, or a delete (docs/cloudkit-schema-design.md §6.6).
struct OutboxChange: Sendable {
    enum Action: Sendable, Equatable {
        case save(SyncEnvelope)
        case delete
    }

    let zoneKey: String
    let zone: SyncZoneName
    let recordType: SyncRecordType
    let wireID: String
    let recordName: String
    /// The replica's system fields (its change tag) the save goes out on; nil for a create.
    let systemFields: Data?
    let action: Action
    let priority: OutboxPriority
    /// Each changed path's stamp, minted once and pinned until sent (§6.3).
    let stamps: [StampedPath: SyncStamp]
    /// The stamp each was minted against, which the merge takes as the change's provenance
    /// (`FieldMerge.merge(mintedAgainst:)`).
    let mintedAgainst: [StampedPath: SyncStamp]
    let rows: [OutboxRowSnapshot]
}

/// Turns the Mac's outbox into records (§6.6 steps 4 to 6).
///
/// The triggers record which local rows changed and when, column by column (§6.6 step 1). The
/// feeder routes each row to the record it feeds through the projection registry: a live row by the
/// key columns it holds now, a removed row by the record key its removal kept. Rows that name one
/// record under different local keys (an entry removed and added again, which mints a new `id`) are
/// coalesced into that record, so it is encoded once from the current rows, each field takes its
/// latest event time across them, and they are acknowledged together. A record is due once its last
/// change is older than its projection's debounce; due records go out structure first, then personal
/// state, then the rest, oldest first.
///
/// At send time the projection encodes the record's current rows. A missing row follows the
/// projection's `missingRow` rules and its parents' roles (§5.7), per record and, for a set fed by
/// rows, per element. The fields are diffed against the replica's acknowledged payload: unchanged
/// fields keep their stamps, changed ones take their pinned stamp or one minted now from their event
/// time, and fields the projection does not know stay exactly as the replica holds them. An empty
/// diff drops the rows. A record goes nowhere until its zone's root (and so its salt) is held (§2.4
/// step 4), nor before the device has a server offset to stamp with (§6.3).
///
/// A row that feeds two records (a table two projections read) is dropped only once neither record
/// has anything left to send, so one record's acknowledgement never takes the other's change.
final class OutboxFeeder {
    /// Pinned stamps live in `ck_outbox_fields` under this source, one row per record path: the
    /// stamp, the stamp it was minted against (`seen`) and the event time it was minted for
    /// (`dirty_at`). A later change of the path (a newer event time) mints a new one. No projected
    /// table can carry this name.
    static let pinSource = "#stamps"
    static let rowColumn = "__row"
    private static let separator = "\u{1F}"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "OutboxFeeder")

    let connection: SQLiteConnection
    let registry: ProjectionRegistry
    let replica: ReplicaStore
    /// Where this batch placed each record so far, by `<type> U+001F <wire id>`: a child encoded after
    /// a parent the server has not acknowledged yet (an Exchange of a chat created in a space notebook)
    /// follows the parent's zone, not `Library`'s default (§4.4). Structure goes first, so the parent
    /// is placed before its children.
    private var batchPlacements: [String: SyncZoneName] = [:]

    init(connection: SQLiteConnection, registry: ProjectionRegistry) {
        self.connection = connection
        self.registry = registry
        self.replica = ReplicaStore(connection: connection)
    }

    // MARK: - The batch

    private struct UnitKey: Hashable {
        let table: String
        let localKey: String
    }

    private struct Unit {
        let key: UnitKey
        /// Each recorded column's change time; `__row` for the row's insert or removal.
        var columns: [String: Double] = [:]
        /// A removal's record key and time.
        var removal: (values: [String: SQLiteValue], dirtyAt: Double)?
        /// The routing values: the live row's, or the removal's.
        var values: [String: SQLiteValue] = [:]
        var isRemoval: Bool { removal != nil }
        var latest: Double { max(columns.values.max() ?? 0, removal?.dirtyAt ?? 0) }
    }

    private struct RecordKey: Hashable {
        let type: SyncRecordType
        let wireID: String
        /// The zone `ck_identity` names (a space copy, a moved record); nil for a personal row.
        let zoneKey: String?
    }

    private struct PendingRecord {
        let key: RecordKey
        let localID: String
        var units: [UnitKey] = []
    }

    private struct Pin {
        let dirtyAt: Double
        let stamp: SyncStamp?
        let seen: SyncStamp?
    }

    /// What a record came to in this batch.
    private enum Outcome {
        case change(OutboxChange)
        /// Nothing to send, now or later: its rows can go.
        case clean
        /// Not now (debounce, no root, no clock): its rows stay.
        case later
    }

    /// The records due at `now`, coalesced, encoded and stamped, at most `limit` of them (the room
    /// left among the engine's 1,000 pending changes). Pins and the clock are written in the same
    /// transaction; rows with nothing to send are dropped.
    func nextBatch(now: Date = Date(), limit: Int = SyncSchema.Limits.enginePendingChangesMax, scope: OutboxScope = .all) throws -> [OutboxChange] {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            let changes = try makeBatch(now: now, limit: limit, waitingForDebounce: true, handingOut: true, scope: scope)
            try connection.executeScript("COMMIT")
            return changes
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }

    /// Every record with a local change, due or not, encoded and stamped at `now` but handed to no one:
    /// what an inbound version of the record is merged with (§6.2), so nothing records a delete as on
    /// its way. Runs inside the caller's transaction (an apply).
    func pendingChanges(now: Date = Date()) throws -> [OutboxChange] {
        try makeBatch(now: now, limit: .max, waitingForDebounce: false, handingOut: false, scope: .all)
    }

    private func makeBatch(now: Date, limit: Int, waitingForDebounce: Bool, handingOut: Bool, scope: OutboxScope) throws -> [OutboxChange] {
        batchPlacements = [:]
        defer { batchPlacements = [:] }
        let tables = Dictionary(uniqueKeysWithValues: registry.mergedTables.map { ($0.name, $0) })
        let units = try loadUnits(tables)
        var unitRecords: [UnitKey: Set<RecordKey>] = [:]
        var records: [RecordKey: PendingRecord] = [:]
        var stale: [UnitKey] = []

        for (unitKey, unit) in units {
            let readers = registry.readers(of: unitKey.table)
            guard !readers.isEmpty else {
                // A table no projection reads any more: nothing can send its rows.
                stale.append(unitKey)
                continue
            }
            for reader in readers {
                guard let rowRecord = reader.table.record(unit.values) else { continue }
                let identity = try identity(type: rowRecord.type, localID: rowRecord.localID)
                let recordKey = RecordKey(type: rowRecord.type, wireID: identity?.wireID ?? rowRecord.personalID, zoneKey: identity?.zoneKey)
                records[recordKey, default: PendingRecord(key: recordKey, localID: rowRecord.localID)].units.append(unitKey)
                unitRecords[unitKey, default: []].insert(recordKey)
            }
            if unitRecords[unitKey] == nil { stale.append(unitKey) }
        }

        // Due records, structure first, oldest first.
        let nowSeconds = now.timeIntervalSinceReferenceDate
        var due: [(record: PendingRecord, projection: any RecordProjection, oldest: Double)] = []
        // A family the cutover seed has not begun waits for its pass (§13.4 step 5).
        let heldTypes = try replica.seedHeldTypes()
        for record in records.values {
            guard let projection = registry.projection(for: record.key.type), !heldTypes.contains(record.key.type) else { continue }
            let times = record.units.compactMap { units[$0]?.latest }
            guard let newest = times.max(), !waitingForDebounce || newest <= nowSeconds - projection.debounce else { continue }
            due.append((record, projection, times.min() ?? newest))
        }
        due.sort { lhs, rhs in
            if lhs.projection.priority != rhs.projection.priority { return lhs.projection.priority < rhs.projection.priority }
            if lhs.oldest != rhs.oldest { return lhs.oldest < rhs.oldest }
            return lhs.record.key.wireID < rhs.record.key.wireID
        }

        var clock = try loadClock()
        var clockMoved = false
        var salts: [String: Data?] = [:]
        var outcomes: [RecordKey: Outcome] = [:]
        var changes: [OutboxChange] = []
        for item in due {
            guard changes.count < limit else { break }
            let outcome = try encode(
                item.record, projection: item.projection, units: units, unitRecords: unitRecords,
                now: now, handingOut: handingOut, scope: scope, clock: &clock, clockMoved: &clockMoved, salts: &salts
            )
            outcomes[item.record.key] = outcome
            if case .change(let change) = outcome { changes.append(change) }
        }
        if clockMoved, let clock { try saveClock(clock, now: now) }

        // A row goes when every record it feeds has nothing to send, and a row no record reads at once.
        for (unitKey, keys) in unitRecords where keys.allSatisfy({ if case .clean? = outcomes[$0] { return true } else { return false } }) {
            try drop(unitKey)
        }
        for unitKey in stale { try drop(unitKey) }
        return changes
    }

    /// Every pending outbox row, grouped by local row.
    private func loadUnits(_ tables: [String: MergedProjectedTable]) throws -> [UnitKey: Unit] {
        var units: [UnitKey: Unit] = [:]
        try connection.query(
            "SELECT source_table, local_key, column, dirty_at FROM ck_outbox_fields WHERE source_table <> ?",
            [.text(Self.pinSource)]
        ) { row in
            let key = UnitKey(table: row.text(0) ?? "", localKey: row.text(1) ?? "")
            units[key, default: Unit(key: key)].columns[row.text(2) ?? ""] = row.real(3) ?? 0
        }
        try connection.query("SELECT source_table, local_key, record_key_json, dirty_at FROM ck_outbox", []) { row in
            let key = UnitKey(table: row.text(0) ?? "", localKey: row.text(1) ?? "")
            var values: [String: SQLiteValue] = [:]
            if let json = row.text(2), let object = (try? SyncJSON(parsing: Data(json.utf8)))?.objectValue {
                values = object.mapValues(SQLiteValue.init(json:))
            }
            units[key, default: Unit(key: key)].removal = (values, row.real(3) ?? 0)
        }
        for (key, unit) in units {
            if let removal = unit.removal {
                units[key]?.values = removal.values
            } else if let table = tables[key.table], let live = try liveValues(key, table: table) {
                units[key]?.values = live
            }
        }
        return units
    }

    /// The routing values a live row holds now; empty when the row is gone (its removal, if it was
    /// sent anywhere, is a unit of its own).
    private func liveValues(_ key: UnitKey, table: MergedProjectedTable) throws -> [String: SQLiteValue]? {
        let keyValues: [SQLiteValue]
        if table.localKey.count == 1 {
            keyValues = [.text(key.localKey)]
        } else {
            guard let parts = (try? SyncJSON(parsing: Data(key.localKey.utf8)))?.arrayValue, parts.count == table.localKey.count else { return nil }
            keyValues = parts.map(SQLiteValue.init(json:))
        }
        let columns = table.routingColumns
        let condition = table.localKey.map { "\(Self.quoted($0)) = ?" }.joined(separator: " AND ")
        var values: [String: SQLiteValue]?
        try connection.query(
            "SELECT \(columns.map(Self.quoted).joined(separator: ", ")) FROM \(Self.quoted(key.table)) WHERE \(condition) LIMIT 1",
            keyValues
        ) { row in
            var read: [String: SQLiteValue] = [:]
            for (index, column) in columns.enumerated() { read[column] = Self.value(row, Int32(index)) }
            values = read
        }
        return values
    }

    private func identity(type: SyncRecordType, localID: String) throws -> (zoneKey: String, wireID: String)? {
        var found: (zoneKey: String, wireID: String)?
        try connection.query(
            "SELECT zone_key, wire_id FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key LIMIT 1",
            [.text(type.rawValue), .text(localID)]
        ) { row in
            found = (row.text(0) ?? "", row.text(1) ?? "")
        }
        return found
    }

    // MARK: - One record

    private func encode(
        _ record: PendingRecord,
        projection: any RecordProjection,
        units: [UnitKey: Unit],
        unitRecords: [UnitKey: Set<RecordKey>],
        now: Date,
        handingOut: Bool,
        scope: OutboxScope,
        clock: inout StampClock?,
        clockMoved: inout Bool,
        salts: inout [String: Data?]
    ) throws -> Outcome {
        let type = record.key.type
        let recordUnits = record.units.compactMap { units[$0] }
        let latest = recordUnits.map(\.latest).max() ?? now.timeIntervalSinceReferenceDate

        // Rows first: a personal record is placed from the fields it will be sent with.
        let provisional = ProjectionRecordRef(
            zoneKey: record.key.zoneKey ?? ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue),
            zone: .library, type: type, wireID: record.key.wireID, localID: record.localID
        )
        let encoded = try projection.encode(provisional, connection: connection)
        guard let placed = try place(record, fields: encoded ?? [:]) else { return .later }
        let (zoneKey, zone) = placed
        guard scope.admits(zone) else { return .later }
        guard let salt = try salt(zoneKey: zoneKey, zone: zone, cache: &salts) else { return .later }
        let held = try replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: record.key.wireID)
        let heldEnvelope = try held.map { try SyncEnvelope(storedPayload: $0.payload) }
        let recordName = held?.recordName ?? RecordNaming.recordName(type: type, id: record.key.wireID, salt: salt)
        let pinKey = Self.pinKey(zoneKey: zoneKey, type: type, wireID: record.key.wireID)
        let pins = try loadPins(pinKey)

        // Nothing to send: the rows go, unless a change already handed out may still land and leave the
        // server where the local rows are not. A pin minted for an older event time than its path's
        // latest is such a change (an edit reverted while it was on its way); its acknowledgement keeps
        // the newer rows, and the record goes out again.
        func settled(_ pinsAreCurrent: Bool) throws -> Outcome {
            guard pinsAreCurrent else { return .later }
            try connection.execute(
                "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
                [.text(Self.pinSource), .text(pinKey)]
            )
            return .clean
        }
        let pinsAreCurrent = pins.allSatisfy { key, pin in
            let time = eventTime(Self.path(ofKey: key), projection: projection, units: recordUnits) ?? latest
            return abs(pin.dirtyAt - time) < 0.0005
        }

        // A delete on its way: a row that came back waits for its acknowledgement, then goes out whole.
        if encoded != nil, try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)",
            [.text(zoneKey), .text(recordName)]
        ) == 1 {
            return .later
        }

        var patch = RecordPatch(type, id: record.key.wireID)
        var paths: [StampedPath] = []
        if let encoded {
            (patch, paths) = diff(encoded, held: heldEnvelope, record: record, projection: projection, units: recordUnits)
        } else {
            // Never acknowledged: nothing to remove, unless its create may still be on its way.
            guard heldEnvelope != nil else { return try settled(pins.isEmpty) }
            switch try missingRowDecision(projection, units: recordUnits) {
            case .noWrite:
                return try settled(true)
            case .delete:
                if handingOut {
                    try connection.execute("""
                        INSERT INTO ck_pending_deletes (zone_key, record_name, record_type, wire_id, deleted_at)
                        VALUES (?, ?, ?, ?, ?) ON CONFLICT(zone_key, record_name) DO NOTHING
                    """, [.text(zoneKey), .text(recordName), .text(type.rawValue), .text(record.key.wireID), .real(latest)])
                }
                return .change(OutboxChange(
                    zoneKey: zoneKey, zone: zone, recordType: type, wireID: record.key.wireID, recordName: recordName,
                    systemFields: held?.systemFields, action: .delete, priority: projection.priority,
                    stamps: [:], mintedAgainst: [:], rows: snapshot(record, units: units, unitRecords: unitRecords)
                ))
            case .fields(let fields):
                for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
                    if let heldValue = heldEnvelope?.fields[field], SyncEnvelope.sameWireValue(heldValue, value) { continue }
                    patch.changes[field] = .value(value)
                    paths.append(StampedPath(field))
                }
            }
        }
        guard !paths.isEmpty else { return try settled(pinsAreCurrent) }

        // Stamps: pinned until sent, else minted now from each path's event time (§6.3).
        var stamps: [StampedPath: SyncStamp] = [:]
        var mintedAgainst: [StampedPath: SyncStamp] = [:]
        for path in paths {
            let time = eventTime(path, projection: projection, units: recordUnits) ?? latest
            let pin = pins[Self.pathKey(path)]
            if let pin, let stamp = pin.stamp, abs(pin.dirtyAt - time) < 0.0005 {
                stamps[path] = stamp
                if let seen = pin.seen { mintedAgainst[path] = seen }
                continue
            }
            let heldStamp = Self.stamp(at: path, in: heldEnvelope)
            // A pin replaced by a newer change may be on its way already: the new stamp passes it.
            let seen = [heldStamp, pin?.stamp].compactMap { $0 }.max { SyncStamp.compare($0, $1) < 0 }
            guard let policy = type.spec.field(path.field)?.policy, var minting = clock else { return .later }
            guard let stamp = minting.mint(policy, eventTime: SyncTime.milliseconds(cocoaSeconds: time), seen: seen,
                                           now: SyncTime.milliseconds(now))
            else { return .later }
            clock = minting
            clockMoved = true
            stamps[path] = stamp
            if let seen { mintedAgainst[path] = seen }
            try connection.execute("""
                INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at, stamp, seen) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_table, local_key, column) DO UPDATE SET
                    dirty_at = excluded.dirty_at, stamp = excluded.stamp, seen = excluded.seen
            """, [
                .text(Self.pinSource), .text(pinKey), .text(Self.pathKey(path)), .real(time),
                .text(stamp.rawValue), .text(seen?.rawValue),
            ])
        }

        var envelope = heldEnvelope ?? SyncEnvelope.new(type, id: record.key.wireID, saltID: RecordNaming.saltID(salt))
        do {
            try envelope.apply(patch) { path, _, _ in
                guard let stamp = stamps[path] else { throw OutboxFeederError.unstampedPath(path.description) }
                return stamp
            }
        } catch let error as RecordPatchError {
            // A change this build can never send (out of a terminal value): its rows go.
            Self.logger.error("\(type.rawValue, privacy: .public) \(record.key.wireID, privacy: .private) cannot be sent: \(String(describing: error), privacy: .public)")
            return try settled(true)
        }
        // A record whose stored payload is over the cap can never be sent, and one that throws at the batch
        // builder would block every send behind it: it is parked here, its rows kept, until it shrinks (M4).
        // A merge still sees its change (`handingOut` false), so an inbound version never overwrites it.
        if handingOut {
            if envelope.json.serialized().count > SyncSchema.Limits.payloadMaxBytes, (try? envelope.storedPayload()) == nil {
                try parkOversize(envelope, zoneKey: zoneKey, recordName: recordName, systemFields: held?.systemFields, now: now)
                return .later
            }
            try connection.execute(
                "DELETE FROM ck_quarantine WHERE zone_key = ? AND record_name = ? AND reason = ?",
                [.text(zoneKey), .text(recordName), .text(Self.payloadTooLargeReason)]
            )
        }
        return .change(OutboxChange(
            zoneKey: zoneKey, zone: zone, recordType: type, wireID: record.key.wireID, recordName: recordName,
            systemFields: held?.systemFields, action: .save(envelope), priority: projection.priority,
            stamps: stamps, mintedAgainst: mintedAgainst, rows: snapshot(record, units: units, unitRecords: unitRecords)
        ))
    }

    /// `ck_quarantine.reason` of a record too large to send (§3.2 rule 1).
    static let payloadTooLargeReason = "payloadTooLarge"

    /// Parks an oversize record with its plain JSON, so the garbage collection still sees the satellites it
    /// names. The engines skip a parked record, and `encode` frees it once it fits.
    private func parkOversize(_ envelope: SyncEnvelope, zoneKey: String, recordName: String, systemFields: Data?, now: Date) throws {
        try connection.execute("""
            INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, system_fields, payload, quarantined_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET reason = excluded.reason, system_fields = excluded.system_fields,
                payload = excluded.payload, quarantined_at = excluded.quarantined_at
        """, [
            .text(zoneKey), .text(recordName), .text(envelope.type), .text(Self.payloadTooLargeReason),
            .blob(systemFields), .blob(envelope.json.serialized()), .real(now.timeIntervalSinceReferenceDate),
        ])
        Self.logger.error("\(envelope.type, privacy: .public) is over the payload cap and is not sent until it is smaller")
    }

    /// The paths whose encoded value differs from the replica's, as a patch. A set or map fed by rows
    /// removes an element only for a row this device removed while its item still exists (§5.7).
    private func diff(
        _ encoded: [String: SyncJSON],
        held: SyncEnvelope?,
        record: PendingRecord,
        projection: any RecordProjection,
        units: [Unit]
    ) -> (RecordPatch, [StampedPath]) {
        var patch = RecordPatch(record.key.type, id: record.key.wireID)
        var paths: [StampedPath] = []
        for (field, value) in encoded.sorted(by: { $0.key < $1.key }) {
            guard let spec = record.key.type.spec.field(field) else { continue }
            switch spec.kind {
            case .scalar:
                if let heldValue = held?.fields[field] {
                    if SyncEnvelope.sameWireValue(heldValue, value) { continue }
                } else if value.isNull {
                    continue
                }
                patch.changes[field] = .value(value)
                paths.append(StampedPath(field))
            case .map, .set:
                guard let object = value.objectValue else { continue }
                let heldObject = held?.fields[field]?.objectValue ?? [:]
                let heldStamps: [String: SyncStamp] = if case .elements(let stamps)? = held?.stamps[field] { stamps } else { [:] }
                var elements: [String: SyncJSON] = [:]
                for (key, element) in object {
                    if let heldElement = heldObject[key], heldStamps[key] != nil, SyncEnvelope.sameWireValue(heldElement, element) { continue }
                    if heldObject[key] == nil, !Self.isPresent(element, kind: spec.kind) { continue }
                    elements[key] = element
                }
                for (key, heldElement) in heldObject where object[key] == nil && Self.isPresent(heldElement, kind: spec.kind) {
                    guard elementRemoved(field: field, element: key, projection: projection, units: units) else { continue }
                    elements[key] = spec.kind == .set ? .bool(false) : .null
                }
                guard !elements.isEmpty else { continue }
                patch.changes[field] = .elements(elements)
                paths += elements.keys.sorted().map { StampedPath(field, element: $0) }
            }
        }
        return (patch, paths)
    }

    private static func isPresent(_ value: SyncJSON, kind: SyncFieldKind) -> Bool {
        kind == .set ? value.boolValue == true : !value.isNull
    }

    /// Whether an element missing from the encoded value was removed here: for a field fed by rows,
    /// only when this device removed the element's row and none of its items is gone.
    private func elementRemoved(field: String, element: String, projection: any RecordProjection, units: [Unit]) -> Bool {
        guard case .elementRows(let table)? = projection.feeds[field] else { return true }
        guard let declaration = projection.table(named: table), declaration.holdsElements else { return false }
        return units.contains { unit in
            guard unit.key.table == table, unit.isRemoval, declaration.elementKey(unit.values) == element else { return false }
            return declaration.parents.filter { $0.role == .item }.allSatisfy { parent in
                (try? parentExists(parent, value: unit.values[parent.column])) ?? true
            }
        }
    }

    // MARK: - Missing rows (§5.7)

    private enum MissingDecision {
        case delete
        case noWrite
        case fields([String: SyncJSON])
    }

    private func missingRowDecision(_ projection: any RecordProjection, units: [Unit]) throws -> MissingDecision {
        for unit in units where unit.isRemoval {
            guard let declaration = projection.table(named: unit.key.table) else { continue }
            for parent in declaration.parents where parent.role != .other {
                let value = unit.values[parent.column]
                guard let value, value != .null else { continue }
                if try parentExists(parent, value: value) {
                    // A container that is a stub now holds no records: what leaves it goes (§5.2).
                    if parent.role == .container, try parentIsRetired(parent, value: value) { return .delete }
                    continue
                }
                switch parent.role {
                case .container:
                    // Gone: the record goes with it only when this device deleted the container.
                    if projection.missingParentNeverDeletes { return .noWrite }
                    return try deletedHere(parent, value: value) ? .delete : .noWrite
                case .item, .other:
                    return .noWrite
                }
            }
        }
        switch projection.missingRow {
        case .delete: return .delete
        case .fields(let fields): return .fields(fields)
        }
    }

    private func parentExists(_ parent: LocalParent, value: SQLiteValue?) throws -> Bool {
        guard let value, value != .null else { return true }
        return try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM \(Self.quoted(parent.table)) WHERE \(Self.quoted(parent.parentColumn)) = ?)", [value]
        ) == 1
    }

    private func parentIsRetired(_ parent: LocalParent, value: SQLiteValue) throws -> Bool {
        guard let condition = parent.retiredWhen else { return false }
        return try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM \(Self.quoted(parent.table)) WHERE \(Self.quoted(parent.parentColumn)) = ? AND (\(condition)))", [value]
        ) == 1
    }

    /// Whether this device deleted the container: its own removal is still in the outbox, or its
    /// delete is waiting for the server's acknowledgement.
    private func deletedHere(_ parent: LocalParent, value: SQLiteValue) throws -> Bool {
        if try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_outbox WHERE source_table = ? AND json_extract(record_key_json, ?) = ?)",
            [.text(parent.table), .text("$.\(parent.parentColumn)"), value]
        ) == 1 {
            return true
        }
        let localID = value.textValue ?? ""
        let wireID = try identity(type: parent.recordType, localID: localID)?.wireID ?? localID
        return try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE record_type = ? AND wire_id = ?)",
            [.text(parent.recordType.rawValue), .text(wireID)]
        ) == 1
    }

    // MARK: - The compaction gate (§3.2 rule 4)

    /// For a device back from an absence longer than the compaction horizon, after it re-fetched every
    /// zone: drops the pending edits of a set's or map's element rows last changed before `horizon`
    /// whose element the record the replica holds no longer lists (a removal marker another writer
    /// compacted meanwhile, so an old add would bring the element back). Returns the records whose
    /// rows lost an edit, so the caller notebooks the server's version over them.
    func dropStaleElementEdits(before horizon: Date) throws -> [ReplicaRecord] {
        let tables = Dictionary(uniqueKeysWithValues: registry.mergedTables.map { ($0.name, $0) })
        let limit = horizon.timeIntervalSinceReferenceDate
        var touched: [String: ReplicaRecord] = [:]
        for (unitKey, unit) in try loadUnits(tables) where unit.latest < limit {
            for reader in registry.readers(of: unitKey.table) {
                guard let element = reader.table.elementKey(unit.values),
                      let field = reader.projection.feeds.first(where: { $0.value == .elementRows(table: unitKey.table) })?.key,
                      let rowRecord = reader.table.record(unit.values)
                else { continue }
                let identity = try identity(type: rowRecord.type, localID: rowRecord.localID)
                let wireID = identity?.wireID ?? rowRecord.personalID
                let zoneKeys = identity.map { [$0.zoneKey] } ?? [SyncZone.library, SyncZone.catalog].map { "private/\($0.rawValue)" }
                guard let held = try zoneKeys.lazy.compactMap({ try self.replica.record(zoneKey: $0, recordType: rowRecord.type.rawValue, wireID: wireID) }).first,
                      let envelope = try? SyncEnvelope(storedPayload: held.payload),
                      envelope.fields[field]?.objectValue?[element] == nil
                else { continue }
                Self.logger.error("Dropped a \(rowRecord.type.rawValue, privacy: .public).\(field, privacy: .public) element edit older than the compaction horizon")
                try drop(unitKey)
                touched[held.zoneKey + Self.separator + held.recordName] = held
            }
        }
        return Array(touched.values)
    }

    // MARK: - Event times (§6.3)

    /// The latest change of the columns that feed `path`, across every row of the record; a column with
    /// no change of its own takes its row's insert time.
    private func eventTime(_ path: StampedPath, projection: any RecordProjection, units: [Unit]) -> Double? {
        eventTime(path, feed: projection.feeds[path.field], projection: projection, units: units)
    }

    private func eventTime(_ path: StampedPath, feed: FieldFeed?, projection: any RecordProjection, units: [Unit]) -> Double? {
        switch feed {
        case .anyOf(let feeds)?:
            return feeds.compactMap { eventTime(path, feed: $0, projection: projection, units: units) }.max()
        case .columns(let table, let columns)?:
            return units.filter { $0.key.table == table }.compactMap { unit in
                columns.compactMap { column in [unit.columns[column], unit.columns[Self.rowColumn]].compactMap { $0 }.max() }.max()
            }.max()
        case .rowExistence(let table)?:
            return units.filter { $0.key.table == table }.compactMap { $0.columns[Self.rowColumn] }.max()
        case .elementRows(let table)?:
            guard let element = path.element, let declaration = projection.table(named: table), declaration.holdsElements else { return nil }
            return units.filter { $0.key.table == table && declaration.elementKey($0.values) == element }
                .compactMap { $0.columns.values.max() }.max()
        case nil:
            return units.compactMap { $0.columns.values.max() }.max()
        }
    }

    private static func stamp(at path: StampedPath, in envelope: SyncEnvelope?) -> SyncStamp? {
        switch envelope?.stamps[path.field] {
        case .value(let stamp)?: return path.element == nil ? stamp : nil
        case .elements(let stamps)?: return path.element.flatMap { stamps[$0] }
        case nil: return nil
        }
    }

    // MARK: - Zone and name

    /// The record's zone: the one `ck_identity` names, else the one the replica holds it in, else where
    /// `zoneFor` places it from its fields (§4.4). Nil for a space this device does not hold.
    private func place(_ record: PendingRecord, fields: [String: SyncJSON]) throws -> (String, SyncZoneName)? {
        let batchKey = record.key.type.rawValue + Self.separator + record.key.wireID
        if let zoneKey = record.key.zoneKey {
            let zone = ProjectionZones.zone(ofKey: zoneKey)
            batchPlacements[batchKey] = zone
            return zone.map { (zoneKey, $0) }
        }
        let placement = ReplicaPlacement(connection: connection, placedInBatch: batchPlacements)
        var held = placement.zones(holding: record.key.type, id: record.key.wireID)
        // A source's or a collection's id names the personal copy and every space's copy alike (§4.3); a
        // space's copy always has its `ck_identity` row, so a row without one is the personal copy and
        // never goes to a space that holds the same id (WP15).
        if [.source, .collection].contains(record.key.type) { held = held.filter { !$0.isSpace } }
        let zone = held.first { !$0.isSpace } ?? held.first
            ?? ZonePlacement.zone(for: record.key.type, id: record.key.wireID, fields: fields, writtenIn: .library, replica: placement)
        batchPlacements[batchKey] = zone
        guard let zoneKey = try placement.zoneKey(of: zone) else { return nil }
        return (zoneKey, zone)
    }

    /// The salt that names the zone's records: `Library`'s root names `Library`, `Catalog` and
    /// `Content`; a space's own root names the space (§2.4). Nil until the root is held.
    private func salt(zoneKey: String, zone: SyncZoneName, cache: inout [String: Data?]) throws -> Data? {
        let rootZone = zone.isSpace ? zoneKey : ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue)
        if let cached = cache[rootZone] { return cached }
        var salt: Data?
        if let root = try replica.record(zoneKey: rootZone, recordName: SyncSchema.rootRecordName),
           let base64 = (try? SyncEnvelope(storedPayload: root.payload))?.fields["salt"]?.stringValue {
            salt = RecordNaming.salt(base64: base64)
        }
        cache[rootZone] = salt
        return salt
    }

    // MARK: - Rows, pins and the clock

    /// The rows a change acknowledges: those of its own. A row another record also reads stays until
    /// that one has nothing left to send either.
    private func snapshot(_ record: PendingRecord, units: [UnitKey: Unit], unitRecords: [UnitKey: Set<RecordKey>]) -> [OutboxRowSnapshot] {
        record.units.filter { unitRecords[$0]?.count == 1 }.compactMap { units[$0] }.flatMap { unit in
            unit.columns.map { OutboxRowSnapshot(sourceTable: unit.key.table, localKey: unit.key.localKey, column: $0.key, dirtyAt: $0.value) }
                + (unit.removal.map { [OutboxRowSnapshot(sourceTable: unit.key.table, localKey: unit.key.localKey, column: nil, dirtyAt: $0.dirtyAt)] } ?? [])
        }.sorted { ($0.sourceTable, $0.localKey, $0.column ?? "") < ($1.sourceTable, $1.localKey, $1.column ?? "") }
    }

    private func drop(_ unit: UnitKey) throws {
        try connection.execute("DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?", [.text(unit.table), .text(unit.localKey)])
        try connection.execute("DELETE FROM ck_outbox WHERE source_table = ? AND local_key = ?", [.text(unit.table), .text(unit.localKey)])
    }

    static func pinKey(zoneKey: String, type: SyncRecordType, wireID: String) -> String {
        [zoneKey, type.rawValue, wireID].joined(separator: separator)
    }

    static func pathKey(_ path: StampedPath) -> String {
        path.element.map { path.field + separator + $0 } ?? path.field
    }

    static func path(ofKey key: String) -> StampedPath {
        let parts = key.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
        return StampedPath(String(parts[0]), element: parts.count > 1 ? String(parts[1]) : nil)
    }

    private func loadPins(_ pinKey: String) throws -> [String: Pin] {
        var pins: [String: Pin] = [:]
        try connection.query(
            "SELECT column, dirty_at, stamp, seen FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
            [.text(Self.pinSource), .text(pinKey)]
        ) { row in
            pins[row.text(0) ?? ""] = Pin(dirtyAt: row.real(1) ?? 0, stamp: row.text(2).flatMap(SyncStamp.init), seen: row.text(3).flatMap(SyncStamp.init))
        }
        return pins
    }

    /// The device's clock (`ck_clock`); nil before it exists, and a device without one sends nothing
    /// that needs a new stamp.
    func loadClock() throws -> StampClock? {
        guard let json = try connection.scalarText("SELECT clock_json FROM ck_clock WHERE id = 1") else { return nil }
        return try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8))
    }

    func saveClock(_ clock: StampClock, now: Date = Date()) throws {
        let json = String(decoding: try JSONEncoder().encode(clock), as: UTF8.self)
        try connection.execute("""
            INSERT INTO ck_clock (id, clock_json, updated_at) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET clock_json = excluded.clock_json, updated_at = excluded.updated_at
        """, [.text(json), .real(now.timeIntervalSinceReferenceDate)])
    }

    // MARK: - The stamps a record holds now (§5.6)

    /// The stamp each of `paths` of one record holds on this device now: the acknowledged one for a
    /// path with no unsent change, and for a path with one its pinned stamp. With `mint`, a changed path
    /// with no pin gets its stamp minted and pinned at once, as an untick needs (§5.6: the pair names
    /// the stamp the change will be sent with); without, such a path is left out, and so is any path
    /// when the device has no clock yet. Runs inside the caller's transaction.
    func heldStamps(type: SyncRecordType, wireID: String, paths: [StampedPath], mint: Bool, now: Date = Date()) throws -> [StampedPath: SyncStamp] {
        guard let projection = registry.projection(for: type) else { return [:] }
        let (units, record, zoneKey) = try pendingRecord(type: type, wireID: wireID)
        let held = try replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID)
            .map { try SyncEnvelope(storedPayload: $0.payload) }
        func acknowledged(_ path: StampedPath) -> SyncStamp? { Self.stamp(at: path, in: held) }
        guard let record else {
            return Dictionary(uniqueKeysWithValues: paths.compactMap { path in acknowledged(path).map { (path, $0) } })
        }

        let recordUnits = record.units.compactMap { units[$0] }
        let provisional = ProjectionRecordRef(zoneKey: zoneKey, zone: ProjectionZones.zone(ofKey: zoneKey) ?? .library, type: type, wireID: wireID, localID: record.localID)
        var changed: Set<StampedPath> = []
        if let encoded = try projection.encode(provisional, connection: connection) {
            changed = Set(diff(encoded, held: held, record: record, projection: projection, units: recordUnits).1)
        } else if held != nil, case .fields(let fields) = try missingRowDecision(projection, units: recordUnits) {
            changed = Set(fields.compactMap { field, value in held?.fields[field].map { SyncEnvelope.sameWireValue($0, value) } == true ? nil : StampedPath(field) })
        }
        let pinKey = Self.pinKey(zoneKey: zoneKey, type: type, wireID: wireID)
        let pins = try loadPins(pinKey)
        let latest = recordUnits.map(\.latest).max() ?? now.timeIntervalSinceReferenceDate
        var clock = try loadClock()
        var result: [StampedPath: SyncStamp] = [:]
        for path in paths {
            guard changed.contains(path) else {
                if let stamp = acknowledged(path) { result[path] = stamp }
                continue
            }
            let time = eventTime(path, projection: projection, units: recordUnits) ?? latest
            if let pin = pins[Self.pathKey(path)], let stamp = pin.stamp, abs(pin.dirtyAt - time) < 0.0005 {
                result[path] = stamp
                continue
            }
            guard mint, var minting = clock, let policy = type.spec.field(path.field)?.policy else { continue }
            let seen = [acknowledged(path), pins[Self.pathKey(path)]?.stamp].compactMap { $0 }.max { SyncStamp.compare($0, $1) < 0 }
            guard let stamp = minting.mint(policy, eventTime: SyncTime.milliseconds(cocoaSeconds: time), seen: seen, now: SyncTime.milliseconds(now)) else { continue }
            clock = minting
            result[path] = stamp
            try connection.execute("""
                INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at, stamp, seen) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_table, local_key, column) DO UPDATE SET
                    dirty_at = excluded.dirty_at, stamp = excluded.stamp, seen = excluded.seen
            """, [.text(Self.pinSource), .text(pinKey), .text(Self.pathKey(path)), .real(time), .text(stamp.rawValue), .text(seen?.rawValue)])
        }
        if mint, let clock { try saveClock(clock, now: now) }
        return result
    }

    /// Pins `stamps` on paths of one record with a local change, each at the event time its path has
    /// now, so the change is sent with exactly those stamps: a twin or merged Entry copies the stamps of
    /// the Entry it replaces (§3.5.8, §5.2). A pin holds until its path changes again. Only for a record
    /// the server does not hold, since a stamp sent must be later than the one it replaces (§6.3); a
    /// path the encode does not send keeps nothing. Runs inside the caller's transaction.
    func pinVerbatim(type: SyncRecordType, wireID: String, stamps: [StampedPath: SyncStamp], now: Date = Date()) throws {
        guard !stamps.isEmpty, let projection = registry.projection(for: type) else { return }
        let (units, found, zoneKey) = try pendingRecord(type: type, wireID: wireID)
        guard let record = found,
              try replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID) == nil
        else { return }
        let recordUnits = record.units.compactMap { units[$0] }
        let latest = recordUnits.map(\.latest).max() ?? now.timeIntervalSinceReferenceDate
        let pinKey = Self.pinKey(zoneKey: zoneKey, type: type, wireID: wireID)
        for (path, stamp) in stamps.sorted(by: { Self.pathKey($0.key) < Self.pathKey($1.key) }) {
            let time = eventTime(path, projection: projection, units: recordUnits) ?? latest
            try connection.execute("""
                INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at, stamp, seen) VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(source_table, local_key, column) DO UPDATE SET
                    dirty_at = excluded.dirty_at, stamp = excluded.stamp, seen = NULL
            """, [.text(Self.pinSource), .text(pinKey), .text(Self.pathKey(path)), .real(time), .text(stamp.rawValue)])
        }
    }

    /// One record's pending rows, and the zone it goes to (`Library` when it has none).
    private func pendingRecord(type: SyncRecordType, wireID: String) throws -> (units: [UnitKey: Unit], record: PendingRecord?, zoneKey: String) {
        let tables = Dictionary(uniqueKeysWithValues: registry.mergedTables.map { ($0.name, $0) })
        let units = try loadUnits(tables)
        var record: PendingRecord?
        for (unitKey, unit) in units.sorted(by: { ($0.key.table, $0.key.localKey) < ($1.key.table, $1.key.localKey) }) {
            for reader in registry.readers(of: unitKey.table) {
                guard let rowRecord = reader.table.record(unit.values), rowRecord.type == type else { continue }
                let identity = try identity(type: type, localID: rowRecord.localID)
                guard (identity?.wireID ?? rowRecord.personalID) == wireID else { continue }
                let key = RecordKey(type: type, wireID: wireID, zoneKey: identity?.zoneKey)
                if record == nil { record = PendingRecord(key: key, localID: rowRecord.localID) }
                record?.units.append(unitKey)
            }
        }
        let fallbackZone = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue)
        let zoneKey = try record.flatMap { try place($0, fields: [:])?.0 } ?? fallbackZone
        return (units, record, zoneKey)
    }

    // MARK: - Acknowledgement (§6.6 step 6)

    /// The server took the save as `serverRecord`: it becomes the replica's row, and the change's own
    /// rows and pinned stamps go unless a later change moved them meanwhile.
    func acknowledgeSave(_ change: OutboxChange, serverRecord: ReplicaRecord) throws {
        try inTransaction {
            try replica.upsertRecord(serverRecord)
            try deleteRows(change)
            let pinKey = Self.pinKey(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID)
            for (path, stamp) in change.stamps {
                try connection.execute(
                    "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ? AND column = ? AND stamp = ?",
                    [.text(Self.pinSource), .text(pinKey), .text(Self.pathKey(path)), .text(stamp.rawValue)]
                )
            }
            try connection.execute(
                "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?",
                [.text(change.zoneKey), .text(change.recordName)]
            )
            try registry.projection(for: change.recordType)?.acknowledged(change, serverRecord: serverRecord, connection: connection)
        }
    }

    /// The server took the delete: the replica forgets the record, a stale echo of it is ignored for
    /// 30 days (§6.4), and the change's rows go.
    func acknowledgeDelete(_ change: OutboxChange, now: Date = Date()) throws {
        try inTransaction {
            try replica.deleteRecord(zoneKey: change.zoneKey, recordName: change.recordName)
            try deleteRows(change)
            // The guard's clock is the server's: a version of the record is a stale echo when the server last
            // modified it no later than this delete, and a re-create by another device is judged against the
            // server's date of the delete, not this device's clock (m3). Without an offset yet, the local clock.
            let serverNow = (try loadClock()?.serverTime(atLocal: SyncTime.milliseconds(now))).map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? now
            let until = serverNow.addingTimeInterval(Double(SyncSchema.Limits.echoSuppressionDays) * 86_400)
            try connection.execute("""
                INSERT INTO ck_echo (zone_key, record_name, change_tag, until) VALUES (?, ?, NULL, ?)
                ON CONFLICT(zone_key, record_name) DO UPDATE SET change_tag = excluded.change_tag, until = excluded.until
            """, [.text(change.zoneKey), .text(change.recordName), .real(until.timeIntervalSinceReferenceDate)])
            for sql in [
                "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?",
                "DELETE FROM ck_unprojected WHERE zone_key = ? AND record_name = ?",
            ] {
                try connection.execute(sql, [.text(change.zoneKey), .text(change.recordName)])
            }
            try connection.execute(
                "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
                [.text(Self.pinSource), .text(Self.pinKey(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID))]
            )
        }
    }

    /// The change will not be sent (the engine dropped it, or never took it): its pinned stamps go, and
    /// a delete's pending row, so the next batch decides the record afresh from its rows. Every change a
    /// batch hands out is acknowledged or released.
    func release(_ change: OutboxChange) throws {
        try inTransaction {
            let pinKey = Self.pinKey(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID)
            for (path, stamp) in change.stamps {
                try connection.execute(
                    "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ? AND column = ? AND stamp = ?",
                    [.text(Self.pinSource), .text(pinKey), .text(Self.pathKey(path)), .text(stamp.rawValue)]
                )
            }
            if change.action == .delete {
                try connection.execute(
                    "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?",
                    [.text(change.zoneKey), .text(change.recordName)]
                )
            }
        }
    }

    /// A change that will never be sent (SpaceSync refused it, §9.2): its rows, pins, pending patch and
    /// pending delete go, and the replica stays as the server holds it. A patch left behind would be offered
    /// every round and never acknowledged, and whatever waits for its acknowledgement (the late import's pass)
    /// would wait for ever (F3).
    func discard(_ change: OutboxChange) throws {
        try inTransaction {
            try deleteRows(change)
            try connection.execute(
                "DELETE FROM ck_patches WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
                [.text(change.zoneKey), .text(change.recordType.rawValue), .text(change.wireID)]
            )
            try connection.execute(
                "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
                [.text(Self.pinSource), .text(Self.pinKey(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID))]
            )
            try connection.execute(
                "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?",
                [.text(change.zoneKey), .text(change.recordName)]
            )
        }
    }

    private func deleteRows(_ change: OutboxChange) throws {
        for row in change.rows where row.column != nil {
            try connection.execute(
                "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ? AND column = ? AND dirty_at = ?",
                [.text(row.sourceTable), .text(row.localKey), .text(row.column), .real(row.dirtyAt)]
            )
        }
        for row in change.rows where row.column == nil {
            try connection.execute("""
                DELETE FROM ck_outbox WHERE source_table = ? AND local_key = ? AND dirty_at = ?
                AND NOT EXISTS (SELECT 1 FROM ck_outbox_fields WHERE source_table = ck_outbox.source_table AND local_key = ck_outbox.local_key)
            """, [.text(row.sourceTable), .text(row.localKey), .real(row.dirtyAt)])
        }
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try body()
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }

    // MARK: - SQL helpers

    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func value(_ row: SQLiteRow, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(row.statement, column) {
        case SQLITE_INTEGER: return .integer(row.integer(column) ?? 0)
        case SQLITE_FLOAT: return .real(row.real(column) ?? 0)
        case SQLITE_TEXT: return .text(row.text(column))
        case SQLITE_BLOB: return .blob(row.blob(column))
        default: return .null
        }
    }
}

/// Which zones a batch hands out (§2.3): the private engine sends `Library` and `Catalog`, SpaceSync
/// the spaces. A record outside the scope keeps its rows for the stream whose zone it is.
enum OutboxScope: Sendable, Equatable {
    case privateZones
    case spaces
    case all

    func admits(_ zone: SyncZoneName) -> Bool {
        switch self {
        case .privateZones: return !zone.isSpace
        case .spaces: return zone.isSpace
        case .all: return true
        }
    }
}

enum OutboxFeederError: Error, Equatable {
    case unstampedPath(String)
}

/// Zones by key (`ck_zones.zone_key`, `private/<zone>` or `shared/<owner>/<zone>`).
enum ProjectionZones {
    /// The zone a key names: its last component.
    static func zone(ofKey zoneKey: String) -> SyncZoneName? {
        zoneKey.split(separator: "/").last.flatMap { SyncZoneName(String($0)) }
    }
}

/// What the replica knows about where records are, as `ZonePlacement` reads it (§4.4).
struct ReplicaPlacement: ZonePlacementReplica {
    let connection: SQLiteConnection
    /// Records the feeder placed earlier in its batch and the server does not hold yet, by
    /// `<type> U+001F <wire id>`.
    var placedInBatch: [String: SyncZoneName] = [:]

    func zones(holding type: SyncRecordType, id: String) -> [SyncZoneName] {
        if let placed = placedInBatch[type.rawValue + "\u{1F}" + id] { return [placed] }
        var zones: [SyncZoneName] = []
        try? connection.query("""
            SELECT zone_key FROM ck_records
            WHERE zone_key IN (SELECT zone_key FROM ck_zones) AND record_type = ? AND wire_id = ?
            ORDER BY zone_key
        """, [.text(type.rawValue), .text(id)]) { row in
            if let zone = ProjectionZones.zone(ofKey: row.text(0) ?? "") { zones.append(zone) }
        }
        return zones
    }

    func notebookRedirects(_ location: SyncRecordLocation) -> NotebookRedirects? {
        guard let zoneKey = (try? zoneKey(of: location.zone)) ?? nil,
              let record = try? ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordType: SyncRecordType.notebook.rawValue, wireID: location.id),
              let envelope = try? SyncEnvelope(storedPayload: record.payload)
        else { return nil }
        return NotebookRedirects(
            mergedInto: envelope.fields["mergedInto"]?.stringValue,
            movedTo: envelope.fields["movedTo"]?.stringValue,
            movingTo: envelope.fields["movingTo"]?.stringValue
        )
    }

    func space(kind: String, primaryID: String) -> SyncZoneName? {
        var candidates: [String] = []
        try? connection.query("SELECT zone_key FROM ck_zones WHERE primary_id = ? ORDER BY zone_key", [.text(primaryID)]) { row in
            if let key = row.text(0) { candidates.append(key) }
        }
        for zoneKey in candidates {
            guard let root = try? ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordName: SyncSchema.rootRecordName),
                  (try? SyncEnvelope(storedPayload: root.payload))?.fields["kind"]?.stringValue == kind,
                  let zone = ProjectionZones.zone(ofKey: zoneKey)
            else { continue }
            return zone
        }
        return nil
    }

    /// The local key of a zone this device holds: the private zones by name, a space from `ck_zones`
    /// (owned spaces in the private database first). Nil for a space it does not hold.
    func zoneKey(of zone: SyncZoneName) throws -> String? {
        guard zone.isSpace else { return ReplicaZone.key(database: .private, zoneName: zone.name) }
        return try connection.scalarText(
            "SELECT zone_key FROM ck_zones WHERE zone_name = ? ORDER BY database = 'private' DESC, zone_key LIMIT 1",
            [.text(zone.name)]
        )
    }
}
