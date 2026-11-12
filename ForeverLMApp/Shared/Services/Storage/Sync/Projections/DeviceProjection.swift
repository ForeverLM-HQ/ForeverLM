import Foundation
import OSLog

// MARK: - The learner's devices (docs/cloudkit-schema-design.md §3.5.2)

/// One `devices` row: a Device record, this Mac's own (the only one it writes) or another device's as its
/// record arrived. Times are Cocoa seconds; `connectorHealth` is the record's map as it is (`{connector:
/// {state, lastSeenAt, lastSuccessfulSyncAt}}`, ms).
struct DeviceRow: Equatable, Sendable {
    var deviceID: String
    var platform: String
    var appVersion: String?
    var appBuild: String?
    var schemaRevision: Int64?
    var displayName: String?
    var firstSeenAt: Double?
    var lastSeenDay: String?
    var roles: Set<String> = []
    var connectorHealth: [String: SyncJSON] = [:]

    static let columns = [
        "platform", "app_version", "app_build", "schema_revision", "display_name", "first_seen_at", "last_seen_day", "roles_json",
        "connector_health_json",
    ]

    static func load(_ deviceID: String, connection: SQLiteConnection) throws -> DeviceRow? {
        var row: DeviceRow?
        try connection.query("SELECT \(columns.joined(separator: ", ")) FROM devices WHERE device_id = ?", [.text(deviceID)]) { values in
            row = DeviceRow(
                deviceID: deviceID, platform: values.text(0) ?? "mac", appVersion: values.text(1), appBuild: values.text(2),
                schemaRevision: values.integer(3), displayName: values.text(4), firstSeenAt: values.real(5), lastSeenDay: values.text(6),
                roles: Set(NotebookStateRow.list(values.text(7))),
                connectorHealth: values.text(8).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
            )
        }
        return row
    }

    /// Writes the row whole (an upsert, so the outbox records only the columns that changed).
    func save(_ connection: SQLiteConnection) throws {
        let health = connectorHealth.isEmpty ? nil : String(decoding: SyncJSON.object(connectorHealth).serialized(), as: UTF8.self)
        try connection.execute("""
            INSERT INTO devices (device_id, \(Self.columns.joined(separator: ", "))) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET \(Self.columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
        """, [
            .text(deviceID), .text(platform), .text(appVersion), .text(appBuild), .integer(schemaRevision), .text(displayName),
            .real(firstSeenAt), .text(lastSeenDay), .text(NotebookStateRow.json(roles)), .text(health),
        ])
    }
}

/// The Device record's projection (§3.5.2): `dev:<deviceID>`, private to the member and written only by
/// its own device. This Mac's row holds its connector health (was the synced `connectorHealth.*`
/// preferences), the one field this projection sends; the build fields and `lastSeenDay` are written on a
/// build change and at most weekly by the Device writer, straight onto the record. Other devices' records project into their rows, read-only here.
struct DeviceProjection: RecordProjection {
    var recordType: SyncRecordType { .device }

    var tables: [ProjectedTable] {
        let idSQL: @Sendable (String) -> String = { "'dev:' || \($0).device_id" }
        return [ProjectedTable(
            "devices", localKey: ["device_id"], keyColumns: ["device_id"], syncedColumns: DeviceRow.columns, recordTypes: [.device],
            record: { values in
                values["device_id"]?.textValue.map {
                    let id = SyncIdentity.deviceRecordID($0)
                    return RowRecord(type: .device, localID: id, personalID: id)
                }
            },
            localIDSQL: idSQL, personalIDSQL: idSQL
        )]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "devices", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "deviceID": .rowExistence(table: "devices"), "platform": Self.column("platform"), "appVersion": Self.column("app_version"),
            "appBuild": Self.column("app_build"), "schemaRevision": Self.column("schema_revision"),
            "displayName": Self.column("display_name"), "firstSeenAt": Self.column("first_seen_at"),
            "lastSeenDay": Self.column("last_seen_day"), "roles": Self.column("roles_json"),
            "connectorHealth": Self.column("connector_health_json"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .other }

    static func deviceID(ofRecord wireID: String) -> String {
        wireID.hasPrefix("dev:") ? String(wireID.dropFirst(4)) : wireID
    }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> DeviceRow? {
        try DeviceRow.load(Self.deviceID(ofRecord: record.wireID), connection: connection)
    }

    /// Only what this projection owns goes out: the id, the platform and the connector health. The build
    /// fields, the display name, `firstSeenAt`, `lastSeenDay` and `roles` belong to `MaintenanceService`'s
    /// writer (`DeviceRecord.patch`), which keeps them on the record without touching this Mac's local row;
    /// sending the local row's copies would put stale values back over its newer ones (and drop
    /// `roles.maintenance`, which the skew and compaction gates read).
    static func encodeRows(_ row: DeviceRow) -> [String: SyncJSON] {
        [
            "deviceID": .string(row.deviceID),
            "platform": .string(row.platform),
            "connectorHealth": .object(row.connectorHealth),
        ]
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let deviceID = fields["deviceID"]?.stringValue ?? Self.deviceID(ofRecord: record.wireID)
        var row = try DeviceRow.load(deviceID, connection: connection) ?? DeviceRow(deviceID: deviceID, platform: "mac")
        if let value = fields["platform"]?.stringValue { row.platform = value }
        if let value = fields["appVersion"] { row.appVersion = value.stringValue }
        if let value = fields["appBuild"] { row.appBuild = value.stringValue }
        if let value = fields["schemaRevision"] { row.schemaRevision = value.int64Value }
        if let value = fields["displayName"] { row.displayName = value.stringValue }
        if let value = fields["firstSeenAt"]?.int64Value { row.firstSeenAt = SyncTime.cocoaSeconds(milliseconds: value) }
        if let value = fields["lastSeenDay"] { row.lastSeenDay = value.stringValue }
        if let roles = fields["roles"]?.objectValue { row.roles = Set(roles.compactMap { $0.value.boolValue == true ? $0.key : nil }) }
        if let health = fields["connectorHealth"]?.objectValue { row.connectorHealth = health.filter { !$0.value.isNull } }
        try row.save(connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM devices WHERE device_id = ?", [.text(Self.deviceID(ofRecord: record.wireID))])
    }
}

// MARK: - This Mac's Device row

/// A connector's health as the Device record carries it (`Device.connectorHealth`), from the
/// `connectorHealth.<connector>.{state,lastSeenAt,lastSuccessfulSyncAt}` values generation 1 kept as
/// synced preferences (seconds since 1970) and generation 2 keeps in this Mac's `UserDefaults`.
enum ConnectorHealthMap {
    static let prefix = "connectorHealth."

    /// The map from `key → value` pairs (preference rows decoded, or `UserDefaults`).
    static func map(_ values: [String: Any]) -> [String: SyncJSON] {
        var map: [String: [String: SyncJSON]] = [:]
        for (key, value) in values where key.hasPrefix(prefix) {
            let parts = key.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            switch (parts[1], value) {
            case ("state", let state as String):
                map[parts[0], default: [:]]["state"] = .string(state)
            case ("lastSeenAt", let seconds as NSNumber), ("lastSuccessfulSyncAt", let seconds as NSNumber):
                map[parts[0], default: [:]][parts[1]] = SyncJSON(Int64((seconds.doubleValue * 1000).rounded()))
            default:
                continue
            }
        }
        return map.mapValues { SyncJSON.object($0) }
    }

    /// This Mac's connector health as `UserDefaults` holds it now.
    static func current(_ defaults: UserDefaults = .standard) -> [String: SyncJSON] {
        map(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) })
    }
}

extension KnowledgeStore {
    /// This device's id, as its stamp clock names it (`ck_clock`); nil before the device has one.
    func thisSyncDeviceID() throws -> String? {
        guard let json = try scalarText("SELECT clock_json FROM ck_clock WHERE id = 1"),
              let clock = try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8)) else { return nil }
        return clock.deviceID
    }

    /// Makes this Mac's Device row where it has none (its build, platform and first sighting), its
    /// connector health from the generation-1 rows; nil while this device has no id yet. The Device
    /// writer keeps the build fields, the display name and `lastSeenDay` from then on.
    @discardableResult
    func ensureThisDeviceRow(now: Date = Date()) throws -> DeviceRow? {
        guard let deviceID = try thisSyncDeviceID() else { return nil }
        if let held = try DeviceRow.load(deviceID, connection: self) { return held }
        var rows: [String: Any] = [:]
        try query("SELECT key, value FROM user_preferences WHERE key LIKE ?", [.text(ConnectorHealthMap.prefix + "%")]) { row in
            if let key = row.text(0), let value = row.text(1).flatMap(PreferenceStore.decodePlist) { rows[key] = value }
        }
        let info = Bundle.main.infoDictionary
        let row = DeviceRow(
            deviceID: deviceID, platform: "mac", appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String, schemaRevision: Int64(SyncSchema.schemaRevision),
            displayName: nil, firstSeenAt: now.timeIntervalSinceReferenceDate,
            lastSeenDay: PlacementDay.day(cocoaSeconds: now.timeIntervalSinceReferenceDate),
            connectorHealth: ConnectorHealthMap.map(rows)
        )
        try row.save(self)
        return row
    }

    /// Keeps this Mac's connector health on its Device row (generation 2 only); nothing while the device
    /// has no id yet.
    func saveThisDeviceConnectorHealth(_ health: [String: SyncJSON]) throws {
        try inDerivationTransaction { store in
            guard var row = try store.ensureThisDeviceRow() else { return }
            guard row.connectorHealth != health else { return }
            row.connectorHealth = health
            try row.save(store)
        }
    }
}

/// Generation 2's writer of this Mac's connector health: after the plugin bookkeeping writes the
/// `connectorHealth.*` values into `UserDefaults` (device-local under generation 2), the map goes onto
/// this Mac's Device row off the main actor, in call order.
enum ConnectorHealthSync {
    private static let storage = StorageService()
    private static let lock = AppLock()
    nonisolated(unsafe) private static var tail: Task<Void, Never>?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ConnectorHealthSync")

    static func mirror(_ defaults: UserDefaults = .standard) {
        let health = ConnectorHealthMap.current(defaults)
        lock.lock()
        let predecessor = tail
        tail = Task.detached(priority: .utility) {
            await predecessor?.value
            do {
                try await storage.performSync { try $0.saveThisDeviceConnectorHealth(health) }
            } catch {
                logger.error("Could not keep this Mac's connector health: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.unlock()
    }
}
