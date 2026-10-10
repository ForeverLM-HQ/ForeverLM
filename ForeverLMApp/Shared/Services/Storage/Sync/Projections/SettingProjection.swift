import CoreFoundation
import Foundation

// MARK: - A synced preference as a Setting record (docs/cloudkit-schema-design.md §3.5.3)

/// A Setting's value as typed JSON, `{"t": "bool"|"int"|"double"|"string"|"array"|"dict"|"data"|"date",
/// "v": …}` (§3.5.3), from and to the property-list value `UserDefaults` holds and `user_preferences`
/// stores (`PreferenceStore.encodePlist`). The type is the plist value's own, which keeps a Bool apart
/// from a number. Inside an array or a dict the elements are plain JSON, as the web writes them: data
/// becomes base64 text and a date its milliseconds there, and a whole number comes back as an integer.
enum SettingValueCodec {
    static func typed(_ value: Any) -> SyncJSON? {
        let pair: (String, SyncJSON)?
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                pair = ("bool", .bool(number.boolValue))
            } else if CFNumberIsFloatType(number) {
                pair = ("double", .number(number.doubleValue))
            } else {
                pair = ("int", SyncJSON(number.int64Value))
            }
        case let text as String: pair = ("string", .string(text))
        case let data as Data: pair = ("data", .string(data.base64EncodedString()))
        case let date as Date: pair = ("date", SyncJSON(SyncTime.milliseconds(date)))
        case let list as [Any]: pair = ("array", .array(list.compactMap(plain)))
        case let map as [String: Any]: pair = ("dict", .object(map.compactMapValues(plain)))
        default: pair = nil
        }
        return pair.map { .object(["t": .string($0.0), "v": $0.1]) }
    }

    /// An element of an array or dict as plain JSON.
    private static func plain(_ value: Any) -> SyncJSON? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .number(number.doubleValue) : SyncJSON(number.int64Value)
        case let text as String: return .string(text)
        case let data as Data: return .string(data.base64EncodedString())
        case let date as Date: return SyncJSON(SyncTime.milliseconds(date))
        case let list as [Any]: return .array(list.compactMap(plain))
        case let map as [String: Any]: return .object(map.compactMapValues(plain))
        default: return nil
        }
    }

    /// The property-list value of a typed value; nil for `null`, an unknown type, or a value that does
    /// not fit its type.
    static func plist(_ typed: SyncJSON) -> Any? {
        guard let object = typed.objectValue, let type = object["t"]?.stringValue, let value = object["v"] else { return nil }
        switch type {
        case "bool": return value.boolValue
        case "int": return value.int64Value.map { Int($0) }
        case "double": return value.numberValue
        case "string": return value.stringValue
        case "data": return value.stringValue.flatMap { Data(base64Encoded: $0) }
        case "date": return value.int64Value.map { Date(timeIntervalSinceReferenceDate: SyncTime.cocoaSeconds(milliseconds: $0)) }
        case "array": return value.arrayValue.map { $0.compactMap(plain) }
        case "dict": return value.objectValue.map { $0.compactMapValues(plain) }
        default: return nil
        }
    }

    private static func plain(_ value: SyncJSON) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let flag): return flag
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 { return Int(number) }
            return number
        case .string(let text): return text
        case .array(let list): return list.compactMap(plain)
        case .object(let map): return map.compactMapValues(plain)
        }
    }

    /// A stored row's value (`PreferenceStore`'s plist XML) as typed JSON; `null` for an empty value, the
    /// payload's form for "no value".
    static func typed(plistXML xml: String) -> SyncJSON? {
        guard !xml.isEmpty else { return .null }
        return PreferenceStore.decodePlist(xml).flatMap(typed)
    }
}

/// One `user_preferences` row that is a Setting.
struct SettingRow: Equatable, Sendable {
    var key: String
    var valueXML: String
    var updatedAt: Double

    static func load(_ key: String, connection: SQLiteConnection) throws -> SettingRow? {
        var row: SettingRow?
        try connection.query("SELECT value, updated_at FROM user_preferences WHERE key = ?", [.text(key)]) { values in
            row = SettingRow(key: key, valueXML: values.text(0) ?? "", updatedAt: values.real(1) ?? 0)
        }
        return row
    }
}

/// The Setting record's projection (§3.5.3): one record per synced preference key that is a Setting
/// under generation 2 (`SyncedPreferenceKeys.isSetting`), id = the key, in `Library` (account scope).
/// Records are never deleted: a key removed here sends `value: null`, and an inbound `null` removes the
/// row. A row whose value no build can read sends nothing.
///
/// A space's Setting (§9.9) is the one space-scoped key the catalog lists, `follow.<collectionID>`
/// (`SpaceFollows`): its row is `user_preferences`' `space.<spaceID>.follow.<collectionID>`, and its
/// `ck_identity` row names the space's zone and the Setting's id, so the feeder sends it into the space
/// and an inbound one lands on the same row. A space's Setting of any other key stays in the replica.
///
/// An inbound Setting writes `user_preferences` under the guard; `UserDefaults` takes it when the store
/// is hydrated after the apply (`PreferenceStore.hydrateFromStore`, called by the engine's apply in WP16).
/// The keys whose Setting arrived cleared (`value: null`: a collection deleted, a setting reset on another
/// device) and so left `user_preferences` under an apply. `UserDefaults` is read by the surfaces, and an
/// absent row cannot tell hydration "removed" from "not synced yet", so the Mac's round hook takes these
/// after the apply and removes each key whose row is still absent (`PreferenceStore.applyInboundRemoval`).
enum InboundSettingRemovals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: Set<String> = []

    static func note(_ key: String) {
        lock.withLock { _ = keys.insert(key) }
    }

    /// The keys noted since the last take.
    static func take() -> Set<String> {
        lock.withLock {
            defer { keys = [] }
            return keys
        }
    }

    /// The keys noted and not taken yet.
    static var pending: Set<String> {
        lock.withLock { keys }
    }
}

struct SettingProjection: RecordProjection {
    var recordType: SyncRecordType { .setting }

    var tables: [ProjectedTable] {
        [ProjectedTable(
            "user_preferences", localKey: ["key"], keyColumns: ["key"], syncedColumns: ["value"], recordTypes: [.setting],
            record: { values in
                guard let key = values["key"]?.textValue,
                      SyncedPreferenceKeys.isSetting(key) || SpaceFollowKey.parse(localKey: key) != nil else { return nil }
                return RowRecord(type: .setting, localID: key, personalID: key)
            },
            localIDSQL: { "\($0).key" }, personalIDSQL: { "\($0).key" }
        )]
    }

    var feeds: [String: FieldFeed] {
        [
            "key": .rowExistence(table: "user_preferences"),
            "value": .anyOf([.rowExistence(table: "user_preferences"), .columns(table: "user_preferences", ["value"])]),
            "editedAt": .columns(table: "user_preferences", ["value"]),
        ]
    }

    var missingRow: MissingRowOutcome { .fields(["value": .null]) }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .other }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> SettingRow? {
        if SpaceFollowKey.parse(localKey: record.localID) != nil {
            // A space's follow is sent where its identity puts it; a row with none (its wire id is its
            // local key) is sent nowhere, never into `Library`.
            guard record.wireID != record.localID, SpaceFollowKey.collectionID(wireKey: record.wireID) != nil,
                  var row = try SettingRow.load(record.localID, connection: connection) else { return nil }
            row.key = record.wireID
            return row
        }
        guard SyncedPreferenceKeys.isSetting(record.wireID) else { return nil }
        return try SettingRow.load(record.wireID, connection: connection)
    }

    static func encodeRows(_ row: SettingRow) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "key": .string(row.key),
            "editedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.updatedAt)),
        ]
        // A value that cannot be read is left as the record holds it (`repairUnreadablePreferences`).
        if let value = SettingValueCodec.typed(plistXML: row.valueXML) { fields["value"] = value }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        if case .space(let spaceID) = record.zone { return try applySpaceSetting(envelope, to: record, spaceID: spaceID, connection: connection) }
        let key = envelope.fields["key"]?.stringValue ?? record.wireID
        guard SyncedPreferenceKeys.isSetting(key) else { return .projected }
        let value = envelope.fields["value"] ?? .null
        if value.isNull {
            try connection.execute("DELETE FROM user_preferences WHERE key = ?", [.text(key)])
            // `UserDefaults` still holds the old value, and hydrating from the rows cannot infer a removal
            // (an absent row reads as "not synced yet"): the round's hook clears it after the apply.
            InboundSettingRemovals.note(key)
            return .projected
        }
        guard let plist = SettingValueCodec.plist(value), let xml = PreferenceStore.encodePlist(plist) else { return .projected }
        let editedAt = envelope.fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        try connection.execute("""
            INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        """, [.text(key), .text(xml), .real(editedAt ?? Date().timeIntervalSinceReferenceDate)])
        return .projected
    }

    /// A space's `follow.<collectionID>` (§9.9): its row, and the identity that ties the row to the
    /// record. A `null` value removes the row and keeps the identity, so a later follow writes the
    /// same record again.
    private func applySpaceSetting(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, spaceID: String, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard let collectionID = SpaceFollowKey.collectionID(wireKey: record.wireID) else { return .projected }
        let key = SpaceFollowKey.localKey(spaceID: spaceID, collectionID: collectionID)
        let value = envelope.fields["value"] ?? .null
        if value.isNull {
            try connection.execute("DELETE FROM user_preferences WHERE key = ?", [.text(key)])
        } else {
            // A follow is a dictionary; a value of another type stays in the replica as the record holds it.
            guard let plist = SettingValueCodec.plist(value) as? [String: Any], let xml = PreferenceStore.encodePlist(plist) else { return .projected }
            let editedAt = envelope.fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
            try connection.execute("""
                INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(key), .text(xml), .real(editedAt ?? Date().timeIntervalSinceReferenceDate)])
        }
        try connection.execute("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
        """, [.text(record.zoneKey), .text(SyncRecordType.setting.rawValue), .text(record.wireID), .text(key)])
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        if case .space(let spaceID) = record.zone {
            guard let collectionID = SpaceFollowKey.collectionID(wireKey: record.wireID) else { return }
            try connection.execute("DELETE FROM user_preferences WHERE key = ?", [.text(SpaceFollowKey.localKey(spaceID: spaceID, collectionID: collectionID))])
            return
        }
        guard SyncedPreferenceKeys.isSetting(record.wireID) else { return }
        try connection.execute("DELETE FROM user_preferences WHERE key = ?", [.text(record.wireID)])
    }
}
