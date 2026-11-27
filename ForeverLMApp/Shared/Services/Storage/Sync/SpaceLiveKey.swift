import Foundation
import Security

// MARK: - Live team Pages: a space's live key (docs/teams-design.md, "Live team Pages")

/// What an editor needs to join a team Page's live room: the space's live key, the page's id as
/// every member's replica names it (its wire id), the relay, and the name teammates see on this
/// writer's caret. The editor derives the page's own key and the room's name from these
/// (`Web/ArtifactEditor/src/live-room.js`); the relay never sees the key.
struct ArtifactLivePage: Equatable, Sendable {
    static let relayURL = "wss://live.foreverlm.com"

    let spaceKey: String
    let pageID: String
    let name: String
    var relayURL: String = Self.relayURL
}

/// The two spellings of a space's live key: the Setting's id in the space's zone, `pageLive.key`,
/// and the `user_preferences` row the Mac keeps it in, `space.<spaceID>.pageLiveKey`, as a space's
/// follows are kept (`SpaceFollowKey`). One key per space: every Page in the space stretches it with
/// its own id, so a member who can read the space can join any of its Pages, and nobody else can.
enum SpaceLiveKey {
    static let wireKey = "pageLive.key"
    static let localPrefix = "space."
    private static let localSuffix = ".pageLiveKey"

    static func localKey(spaceID: String) -> String { localPrefix + spaceID + localSuffix }

    static func spaceID(localKey: String) -> String? {
        guard localKey.hasPrefix(localPrefix), localKey.hasSuffix(localSuffix),
              localKey.count > localPrefix.count + localSuffix.count else { return nil }
        return String(localKey.dropFirst(localPrefix.count).dropLast(localSuffix.count))
    }

    /// A fresh key: 32 random bytes, base64url without padding.
    static func makeKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether a value can be a key: base64url of at least 32 bytes.
    static func isKey(_ value: String) -> Bool {
        value.count >= 43 && value.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: Reads

    /// The space's live key as this Mac holds it: its row, else the Setting the replica holds (one
    /// that arrived before this build projected it).
    static func key(spaceID: String, connection: SQLiteConnection) throws -> String? {
        if let xml = try connection.scalarText("SELECT value FROM user_preferences WHERE key = ?", [.text(localKey(spaceID: spaceID))]),
           let value = PreferenceStore.decodePlist(xml) as? String, isKey(value) {
            return value
        }
        guard let zoneKey = try ReplicaPlacement(connection: connection).zoneKey(of: .space(spaceID)),
              let held = try ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordType: SyncRecordType.setting.rawValue, wireID: wireKey),
              let envelope = try? SyncEnvelope(storedPayload: held.payload),
              let typed = envelope.fields["value"], let value = SettingValueCodec.plist(typed) as? String, isKey(value) else { return nil }
        return value
    }

    /// The space a team Page lives in and its id there, or nil for a page of the learner's own
    /// library. A space's page may have a local id of its own on this Mac (`SpaceLocalID`); the
    /// room is named for the id every member shares.
    static func placement(artifactID: String, connection: SQLiteConnection) throws -> (spaceID: String, wireID: String, zoneKey: String)? {
        var found: (String, String, String)?
        try connection.query(
            "SELECT zone_key, wire_id FROM ck_identity WHERE record_type = ? AND local_id = ? ORDER BY zone_key",
            [.text(SyncRecordType.artifact.rawValue), .text(artifactID)]
        ) { row in
            guard found == nil, let zoneKey = row.text(0), let wireID = row.text(1),
                  case .space(let spaceID) = ProjectionZones.zone(ofKey: zoneKey) else { return }
            found = (spaceID, wireID, zoneKey)
        }
        if let found { return found }
        try connection.query(
            "SELECT zone_key FROM ck_records WHERE record_type = ? AND wire_id = ? ORDER BY zone_key",
            [.text(SyncRecordType.artifact.rawValue), .text(artifactID)]
        ) { row in
            guard found == nil, let zoneKey = row.text(0), case .space(let spaceID) = ProjectionZones.zone(ofKey: zoneKey) else { return }
            found = (spaceID, artifactID, zoneKey)
        }
        return found
    }

    // MARK: Writes

    /// The space's live key, made now when the space has none and this member may write into it.
    /// Two members making one at the same moment each send theirs; the Setting's last writer wins,
    /// and an editor that hears the key change joins the new room.
    static func ensure(spaceID: String, store: KnowledgeStore, at date: Date = Date()) throws -> String? {
        if let held = try key(spaceID: spaceID, connection: store) { return held }
        guard let zoneKey = try ReplicaPlacement(connection: store).zoneKey(of: .space(spaceID)),
              try DocSpaces.canWrite(zoneKey: zoneKey, connection: store),
              try ReplicaStore(connection: store).engineState(SpaceSync.StateScope.gone(zoneKey)) == nil,
              let key = makeKey(), let xml = PreferenceStore.encodePlist(key) else { return nil }
        let local = localKey(spaceID: spaceID)
        try store.inDerivationTransaction { store in
            try store.recordIdentity(zoneKey: zoneKey, recordType: SyncRecordType.setting.rawValue, wireID: wireKey, localID: local)
            try store.execute("""
                INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(local), .text(xml), .real(date.timeIntervalSinceReferenceDate)])
        }
        return key
    }

    /// The editor's way into a team Page's room, or nil for a page of the learner's own library (or a
    /// space this Mac cannot make a key for, read-only, until a writer has made one).
    static func livePage(artifactID: String, name: String, store: KnowledgeStore) throws -> ArtifactLivePage? {
        guard let placement = try placement(artifactID: artifactID, connection: store),
              let key = try ensure(spaceID: placement.spaceID, store: store) else { return nil }
        return ArtifactLivePage(spaceKey: key, pageID: placement.wireID, name: name)
    }
}
