import Foundation

// MARK: - A space's refresh of a followed Collection (docs/cloudkit-schema-design.md §3.5.5, §9.9, PD-15)

/// What a space says about refreshing one of its Collections: whether the feed's new items are imported
/// into the space, and which member's Mac does it. Following is per member (`Mark(following)`), so
/// copying a followed collection into a space never makes every member's Mac import its feed; a space
/// is refreshed only through this explicit Setting, which names one Mac.
struct SpaceFollow: Equatable, Sendable {
    let spaceID: String
    let collectionID: String
    let autoImport: Bool
    /// The device id of the one Mac that refreshes the Collection for the space; nil names none.
    let runnerDeviceID: String?
    let updatedAt: Date
}

/// The two spellings of a space follow's key: the Setting's id in the space's zone, and the key of the
/// `user_preferences` row the Mac keeps it in (§3.5.3 gives a space Setting no table of its own).
/// The local key is no synced preference, so `PreferenceStore` never reads or
/// writes it; the Setting projection feeds it, and `ck_identity` names its zone and wire id.
enum SpaceFollowKey {
    /// The Setting's id: `follow.<collectionID>`.
    static let wirePrefix = "follow."
    /// The local key: `space.<spaceID>.follow.<collectionID>`.
    static let localPrefix = "space."
    private static let localInfix = ".follow."

    static func wireKey(collectionID: String) -> String { wirePrefix + collectionID }

    static func collectionID(wireKey: String) -> String? {
        guard wireKey.hasPrefix(wirePrefix), wireKey.count > wirePrefix.count else { return nil }
        return String(wireKey.dropFirst(wirePrefix.count))
    }

    static func localKey(spaceID: String, collectionID: String) -> String {
        localPrefix + spaceID + localInfix + collectionID
    }

    static func parse(localKey: String) -> (spaceID: String, collectionID: String)? {
        guard localKey.hasPrefix(localPrefix), let infix = localKey.range(of: localInfix, range: localKey.index(localKey.startIndex, offsetBy: localPrefix.count)..<localKey.endIndex) else {
            return nil
        }
        let spaceID = String(localKey[localKey.index(localKey.startIndex, offsetBy: localPrefix.count)..<infix.lowerBound])
        let collectionID = String(localKey[infix.upperBound...])
        return spaceID.isEmpty || collectionID.isEmpty ? nil : (spaceID, collectionID)
    }
}

enum SpaceFollowError: Error, Equatable, LocalizedError {
    case unknownSpace
    /// The space went (deleted, left, purged): its rows are kept hidden, never changed.
    case spaceGone
    case readOnly
    /// This Mac holds no such Collection in the space.
    case unknownCollection
    /// Only a podcast show, a YouTube channel or a playlist has a feed to follow.
    case notFollowable(String)

    var errorDescription: String? {
        switch self {
        case .unknownSpace: return "This Mac does not hold that space."
        case .spaceGone: return "That space is gone, so it cannot be changed."
        case .readOnly: return "You can read this space but not change it."
        case .unknownCollection: return "This Mac has not received that collection from the space yet."
        case .notFollowable(let kind): return "A \(kind) has no feed to follow."
        }
    }
}

/// A space's follows as the Mac holds them (§3.5.5, §9.9): one `user_preferences` row each, keyed by
/// `SpaceFollowKey.localKey`, holding the Setting's value, `{autoImport, runnerDeviceID}`, as a property
/// list.
enum SpaceFollows {
    /// The kinds of Collection that have a feed (§3.5.5 `feed`).
    static let followableKinds: Set<String> = ["podcastShow", "youtubeChannel", "playlist"]

    // MARK: Value

    static func plist(autoImport: Bool, runnerDeviceID: String?) -> [String: Any] {
        var value: [String: Any] = ["autoImport": autoImport]
        if let runnerDeviceID, !runnerDeviceID.isEmpty { value["runnerDeviceID"] = runnerDeviceID }
        return value
    }

    /// The value a stored row holds; nil when the row is no dictionary.
    static func decode(valueXML: String) -> (autoImport: Bool, runnerDeviceID: String?)? {
        guard let value = PreferenceStore.decodePlist(valueXML) as? [String: Any] else { return nil }
        let runner = (value["runnerDeviceID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (value["autoImport"] as? Bool ?? false, runner)
    }

    // MARK: Reads

    /// Every follow the Mac holds, ordered by space and collection; `spaceID` limits it to one space.
    /// A row this Mac cannot read as a follow is left out.
    static func all(spaceID: String? = nil, connection: SQLiteConnection) throws -> [SpaceFollow] {
        var follows: [SpaceFollow] = []
        try connection.query(
            "SELECT key, value, updated_at FROM user_preferences WHERE substr(key, 1, ?) = ? ORDER BY key",
            [.integer(Int64(SpaceFollowKey.localPrefix.count)), .text(SpaceFollowKey.localPrefix)]
        ) { row in
            guard let key = row.text(0), let ids = SpaceFollowKey.parse(localKey: key), spaceID == nil || ids.spaceID == spaceID,
                  let value = decode(valueXML: row.text(1) ?? "") else { return }
            follows.append(SpaceFollow(
                spaceID: ids.spaceID, collectionID: ids.collectionID, autoImport: value.autoImport, runnerDeviceID: value.runnerDeviceID,
                updatedAt: Date(timeIntervalSinceReferenceDate: row.real(2) ?? 0)
            ))
        }
        return follows
    }

    static func follow(spaceID: String, collectionID: String, connection: SQLiteConnection) throws -> SpaceFollow? {
        try all(spaceID: spaceID, connection: connection).first { $0.collectionID == collectionID }
    }

    /// The follows this Mac runs: those that import and name `deviceID`, in spaces that have not gone.
    /// The refresh itself is a later package's; it asks here which Collections are its to refresh.
    static func running(onDevice deviceID: String, connection: SQLiteConnection) throws -> [SpaceFollow] {
        let replica = ReplicaStore(connection: connection)
        return try all(connection: connection).filter { follow in
            guard follow.autoImport, follow.runnerDeviceID == deviceID else { return false }
            guard let zoneKey = try ReplicaPlacement(connection: connection).zoneKey(of: .space(follow.spaceID)) else { return false }
            return try replica.engineState(SpaceSync.StateScope.gone(zoneKey)) == nil
        }
    }

    // MARK: Writes (generation 2)

    /// Makes the space follow `collectionID` as given: the row, and the identity that puts its Setting
    /// in the space's zone. The Setting is sent by the space's own sync like any other change. Refused
    /// for a space this Mac does not hold, one that went, one the member may only read, a Collection
    /// the space's replica does not hold and one without a feed.
    static func set(
        spaceID: String, collectionID: String, autoImport: Bool, runnerDeviceID: String?, at date: Date = Date(),
        store: KnowledgeStore
    ) throws {
        let zoneKey = try writableZoneKey(spaceID: spaceID, connection: store)
        let replica = ReplicaStore(connection: store)
        guard let held = try replica.record(zoneKey: zoneKey, recordType: SyncRecordType.collection.rawValue, wireID: collectionID),
              let envelope = try? SyncEnvelope(storedPayload: held.payload) else { throw SpaceFollowError.unknownCollection }
        let kind = envelope.fields["kind"]?.stringValue ?? ""
        guard followableKinds.contains(kind) else { throw SpaceFollowError.notFollowable(kind) }
        guard let xml = PreferenceStore.encodePlist(plist(autoImport: autoImport, runnerDeviceID: runnerDeviceID)) else { return }
        let key = SpaceFollowKey.localKey(spaceID: spaceID, collectionID: collectionID)
        try store.inDerivationTransaction { store in
            try store.recordIdentity(
                zoneKey: zoneKey, recordType: SyncRecordType.setting.rawValue, wireID: SpaceFollowKey.wireKey(collectionID: collectionID), localID: key
            )
            try store.execute("""
                INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(key), .text(xml), .real(date.timeIntervalSinceReferenceDate)])
        }
    }

    /// Ends the space's follow: the row goes, and the Setting is cleared to `null` for everyone (a
    /// Setting is never deleted, §3.5.3); its identity stays, so the clearing reaches the space.
    static func clear(spaceID: String, collectionID: String, store: KnowledgeStore) throws {
        _ = try writableZoneKey(spaceID: spaceID, connection: store)
        try store.inDerivationTransaction { store in
            try store.execute("DELETE FROM user_preferences WHERE key = ?", [.text(SpaceFollowKey.localKey(spaceID: spaceID, collectionID: collectionID))])
        }
    }

    /// Removes the rows of a space's Settings, which only the space's identities name. Runs under the
    /// apply guard, as the space's other rows are removed, so nothing is sent.
    static func forget(zoneKey: String, connection: SQLiteConnection) throws {
        try connection.execute(
            "DELETE FROM user_preferences WHERE key IN (SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = ?)",
            [.text(zoneKey), .text(SyncRecordType.setting.rawValue)]
        )
    }

    /// The zone key of a space this member may change.
    private static func writableZoneKey(spaceID: String, connection: SQLiteConnection) throws -> String {
        guard let zoneKey = try ReplicaPlacement(connection: connection).zoneKey(of: .space(spaceID)),
              let zone = try ReplicaStore(connection: connection).zone(key: zoneKey) else { throw SpaceFollowError.unknownSpace }
        let replica = ReplicaStore(connection: connection)
        guard try replica.engineState(SpaceSync.StateScope.gone(zoneKey)) == nil else { throw SpaceFollowError.spaceGone }
        if zone.role != "owner", zone.permission == CloudShare.Permission.readOnly.rawValue { throw SpaceFollowError.readOnly }
        return zoneKey
    }
}

extension KnowledgeStore {
    /// Every space follow this Mac holds (`spaceID` limits it to one space).
    func spaceFollows(spaceID: String? = nil) throws -> [SpaceFollow] {
        try SpaceFollows.all(spaceID: spaceID, connection: self)
    }

    /// The follows that name this Mac as their runner and import.
    func spaceFollowsRunning(onDevice deviceID: String) throws -> [SpaceFollow] {
        try SpaceFollows.running(onDevice: deviceID, connection: self)
    }

    func setSpaceFollow(spaceID: String, collectionID: String, autoImport: Bool, runnerDeviceID: String?, at date: Date = Date()) throws {
        try SpaceFollows.set(spaceID: spaceID, collectionID: collectionID, autoImport: autoImport, runnerDeviceID: runnerDeviceID, at: date, store: self)
    }

    func clearSpaceFollow(spaceID: String, collectionID: String) throws {
        try SpaceFollows.clear(spaceID: spaceID, collectionID: collectionID, store: self)
    }
}
