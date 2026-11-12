import Foundation
import OSLog

/// A space as the Mac lists it (docs/cloudkit-schema-design.md §9.1): its zone, what its root says,
/// this member's place in it, and whether it went.
struct SpaceSummary: Equatable, Sendable {
    struct Gone: Equatable, Sendable {
        /// `deleted`, `left`, `saltChanged`, `purged` or `encryptedDataReset` (SpaceSync's mark).
        let reason: String
        let at: Date
    }

    let zone: SpaceZone
    let spaceID: String
    /// `team`, `family`, `notebook` or `doc`; nil while the root has not arrived.
    let kind: String?
    let name: String
    let primaryID: String?
    let permission: CloudShare.Permission
    let isShared: Bool
    let ownerName: String?
    /// The id the space's local rows carry in `team_id` (`SpaceRows.localTeamID`).
    let localTeamID: String
    let gone: Gone?

    var isOwned: Bool { zone.isOwned }
}

enum SpaceServiceError: Error, Equatable, LocalizedError {
    /// The owner has `maximumOwnedSpaces` spaces already (§2.2).
    case tooManySpaces(Int)
    case notOwner
    case unknownKind(String)
    /// The space's share could not be saved, so the space was taken back out (§5.3 step 1).
    case shareFailed(String)
    case failed(String)
    /// Generation 2's sync is not running on this Mac yet.
    case syncNotRunning

    var errorDescription: String? {
        switch self {
        case .tooManySpaces(let count):
            return "You own \(count) shared spaces, the most iCloud allows ForeverLM. Add this to one of them instead."
        case .notOwner:
            return "Only the space's owner can do that."
        case .unknownKind(let kind):
            return "ForeverLM has no kind of space called \(kind)."
        case .shareFailed(let reason):
            return "iCloud could not share the space, so it was not made: \(reason)"
        case .failed(let reason):
            return "iCloud could not change the space: \(reason)"
        case .syncNotRunning:
            return "iCloud sync is not running on this Mac yet."
        }
    }
}

/// The Mac's spaces (docs/cloudkit-schema-design.md §2.2, §2.4, §2.5, §9): it makes a space (its zone,
/// a root with a fresh salt saved by compare-and-set create, then its zone-wide share, which
/// `ShareService` saves), lists the spaces `ck_zones` holds with what their roots say, changes a
/// root (a rename, a family's plan code), deletes an owned space, and hides and finally purges a
/// space that went (30 days, §2.5, §9.6). A team or family space is mirrored into the `teams` table,
/// so the Mac's team surfaces and every `team_id` scope read it as they read a team; a team from
/// generation 1 keeps its id there (§13.7).
///
/// Generation 2 only: nothing under generation 1 reaches it, and generation 1's teams, Doc shares and
/// family plans stay on the old container (D40).
struct SpaceService {
    /// The UI warns from this many owned spaces and refuses one past the maximum (§2.2).
    static let warningOwnedSpaces = 100
    static let maximumOwnedSpaces = 250
    /// A space that went stays on this Mac, hidden, this long, for "Keep a personal copy" (§2.5, §9.6).
    static let goneKeepInterval: TimeInterval = 30 * MemoryTutorScheduler.secondsPerDay
    static let kinds: Set<String> = ["team", "family", "notebook", "doc"]

    /// `ck_engine_state` scopes of this Mac's own choices about a space.
    enum StateScope {
        /// "Download all files" for a space: bytes only, never visibility (§9.7).
        static func downloadAll(_ zoneKey: String) -> String { "space.downloadAll.\(zoneKey)" }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SpaceService")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let spaces: SpaceSync
    let shares: ShareService
    let deviceID: String
    var now: @Sendable () -> Date = { Date() }
    var makeSalt: @Sendable () -> Data = { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }
    var makeSpaceID: @Sendable () -> String = { UUID().uuidString.lowercased() }

    init(transport: CloudTransport, store: PrivateSyncLocalStore, spaces: SpaceSync, shares: ShareService, deviceID: String) {
        self.transport = transport
        self.store = store
        self.spaces = spaces
        self.shares = shares
        self.deviceID = deviceID
    }

    init(coordinator: SyncCoordinator) {
        self.init(transport: coordinator.transport, store: coordinator.store, spaces: coordinator.spaces, shares: coordinator.shares,
                  deviceID: coordinator.deviceID)
    }

    /// The running coordinator's service; generation 2 only.
    static func current() throws -> SpaceService {
        guard let coordinator = SyncCoordinator.current else { throw SpaceServiceError.syncNotRunning }
        return SpaceService(coordinator: coordinator)
    }

    // MARK: - Listing

    /// Every space this Mac holds, owned ones first, then by name; spaces that went included, with
    /// when and why.
    func list() async throws -> [SpaceSummary] {
        try await store.perform { state in try Self.summaries(state.connection) }
    }

    static func summaries(_ connection: SQLiteConnection) throws -> [SpaceSummary] {
        var keys: [String] = []
        try connection.query("SELECT zone_key FROM ck_zones WHERE kind = 'space' ORDER BY zone_key", []) { keys.append($0.text(0) ?? "") }
        let replica = ReplicaStore(connection: connection)
        var found: [SpaceSummary] = []
        for key in keys {
            guard let row = try replica.zone(key: key), let zone = SpaceZone(row), case .space(let spaceID) = zone.name else { continue }
            let root = try replica.record(zoneKey: key, recordName: SyncSchema.rootRecordName).flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            var gone: SpaceSummary.Gone?
            if let mark = try replica.engineState(SpaceSync.StateScope.gone(key)), let json = try? SyncJSON(parsing: mark) {
                gone = SpaceSummary.Gone(reason: json["reason"]?.stringValue ?? "deleted",
                                         at: Date(timeIntervalSince1970: Double(json["at"]?.int64Value ?? 0) / 1000))
            }
            found.append(SpaceSummary(
                zone: zone, spaceID: spaceID, kind: root?.fields["kind"]?.stringValue, name: root?.fields["name"]?.stringValue ?? "",
                primaryID: row.primaryID ?? root?.fields["primaryID"]?.stringValue,
                permission: zone.isOwned ? .readWrite : CloudShare.Permission(rawValue: row.permission ?? "") ?? .readOnly,
                isShared: row.shareRecordName != nil,
                ownerName: zone.isOwned ? nil : SpaceSync.ownerName(root, zone: zone),
                localTeamID: try SpaceRows.localTeamID(spaceID: spaceID, connection: connection), gone: gone
            ))
        }
        return found.sorted { lhs, rhs in
            if lhs.isOwned != rhs.isOwned { return lhs.isOwned }
            return (lhs.name.lowercased(), lhs.spaceID) < (rhs.name.lowercased(), rhs.spaceID)
        }
    }

    /// How many spaces this account owns that have not gone (§2.2).
    func ownedCount() async throws -> Int {
        try await list().filter { $0.isOwned && $0.gone == nil }.count
    }

    /// Whether a new owned space is fine, worth a warning ("consider adding this to an existing
    /// space"), or refused.
    enum Room: Equatable, Sendable {
        case fine
        case warn(Int)
        case full(Int)
    }

    static func room(owned: Int) -> Room {
        if owned >= maximumOwnedSpaces { return .full(owned) }
        return owned >= warningOwnedSpaces ? .warn(owned) : .fine
    }

    // MARK: - Making a space

    /// What a family space's root carries beside a team's (§3.5.1, §9.1).
    struct FamilyFields: Equatable, Sendable {
        var planCode: String?
        var assignmentsNotebookID: String?
    }

    /// Makes `Space-<spaceID>` (§2.4 Spaces, §5.3 step 1): the zone, then its root with a fresh salt by
    /// compare-and-set create (a root another of the owner's devices saved first is adopted when it is
    /// the same kind, so a resumed migration makes one space), then, when `share` asks, its zone-wide
    /// share; a share that cannot be saved takes the zone back out. A team or family space gets its
    /// `teams` row.
    @discardableResult
    func create(kind: String, name: String, owner: SyncPerson, primaryID: String? = nil, family: FamilyFields? = nil,
                spaceID requested: String? = nil, share: Bool = true) async throws -> SpaceSummary {
        guard Self.kinds.contains(kind) else { throw SpaceServiceError.unknownKind(kind) }
        let owned = try await ownedCount()
        if case .full(let count) = Self.room(owned: owned) { throw SpaceServiceError.tooManySpaces(count) }
        let spaceID = requested ?? makeSpaceID()
        let zoneID = CloudZoneID(SyncSchema.spaceZonePrefix + spaceID)
        let zone = SpaceZone(zoneID, in: .private)

        let made = try await transport.modifyZones(saving: [zoneID], deleting: [], in: .private)
        if case .failure(let error)? = made.saved[zoneID] { throw SpaceServiceError.failed(error.description) }

        let at = now()
        let salt = makeSalt()
        let deviceID = deviceID
        let clock = try await store.perform { try $0.replica.loadClock() }
        var minting = clock
        let mint: (SyncPolicy, SyncStamp?) throws -> SyncStamp = { policy, seen in
            if var held = minting, let stamp = held.mint(policy, eventTime: SyncTime.milliseconds(at), seen: seen, now: SyncTime.milliseconds(at)) {
                minting = held
                return stamp
            }
            return SyncStamp.provisional(policy, deviceID: deviceID)
        }
        var root = try ShareService.spaceRoot(kind: kind, name: name, owner: owner, primaryID: primaryID, salt: salt,
                                              at: SyncTime.milliseconds(at), mint: mint)
        if let family {
            var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
            if let code = family.planCode { patch.changes["familyPlanCode"] = .value(.string(code)) }
            if let notebook = family.assignmentsNotebookID { patch.changes["assignmentsNotebookID"] = .value(.string(notebook)) }
            if !patch.changes.isEmpty { try root.apply(patch) { _, policy, seen in try mint(policy, seen) } }
        }
        if let minting, minting != clock {
            try await store.perform { try $0.replica.saveClock(minting, now: at) }
        }

        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: zoneID)
        let sentAt = now()
        let result = try await transport.modifyRecords(saving: [CloudRecord(
            id: rootID, recordType: SyncRecordType.zoneRoot.rawValue, encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())]
        )], in: .private)
        let held: CloudRecord
        var adoptedRoot = false
        if let saved = result.savedRecord(rootID) {
            held = saved
        } else if let error = result.error(for: rootID), error.code == .serverRecordChanged, let server = error.serverRecord,
                  let payload = server.payload, (try? SyncEnvelope(storedPayload: payload))?.fields["kind"]?.stringValue == kind {
            held = server
            adoptedRoot = true
        } else {
            throw SpaceServiceError.failed(result.error(for: rootID)?.description ?? "no answer for the space's root")
        }
        try await hold(zone, root: held, sentAt: sentAt)

        if share {
            do {
                try await shares.share(zone, title: name, publicPermission: CloudShare.Permission.none)
            } catch {
                // Only a zone this call made is taken back out. A root another of the owner's devices saved
                // first is theirs: that device may have shared it, and its records are in it (F15).
                if !adoptedRoot {
                    _ = try? await transport.modifyZones(saving: [], deleting: [zoneID], in: .private)
                    try await forget(zone, teamID: nil)
                }
                Self.logger.error("A new space's share failed: \(String(describing: error), privacy: .public)")
                throw SpaceServiceError.shareFailed(String(describing: error))
            }
        }
        try await mirrorTeams()
        Self.logger.info("Made a space (\(kind, privacy: .public))")
        guard let summary = try await list().first(where: { $0.zone == zone }) else {
            throw SpaceServiceError.failed("the space was made but this Mac does not hold it")
        }
        return summary
    }

    /// Shares an owned space that is held but not shared: a move that stopped between making its space and
    /// sharing it leaves exactly that, and `create` does not run again for a space this Mac holds (F15).
    func ensureShared(spaceID: String, title: String) async throws {
        guard let space = try await list().first(where: { $0.isOwned && $0.gone == nil && $0.spaceID == spaceID }) else {
            throw SpaceServiceError.failed("this Mac does not hold the space")
        }
        guard !space.isShared else { return }
        do {
            try await shares.share(space.zone, title: title, publicPermission: CloudShare.Permission.none)
        } catch {
            throw SpaceServiceError.shareFailed(String(describing: error))
        }
    }

    /// The space's zone row and root as the server acknowledged them, so the feeder names its records
    /// with its salt and SpaceSync walks it.
    private func hold(_ zone: SpaceZone, root: CloudRecord, sentAt: Date) async throws {
        guard let payload = root.payload, let envelope = try? SyncEnvelope(storedPayload: payload),
              let salt = envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        else { throw SpaceServiceError.failed("the space's root carries no salt") }
        let deviceID = deviceID
        try await store.perform { state in
            let replica = state.replica
            try replica.setEngineState(SpaceSync.StateScope.gone(zone.zoneKey), nil)
            var row = try replica.zone(key: zone.zoneKey) ?? ReplicaZone(
                zoneKey: zone.zoneKey, database: .private, zoneName: zone.zoneID.zoneName, kind: SyncZone.space.rawValue.lowercased()
            )
            row.role = "owner"
            row.permission = CloudShare.Permission.readWrite.rawValue
            row.saltID = RecordNaming.saltID(salt)
            row.primaryID = envelope.fields["primaryID"]?.stringValue
            try replica.upsertZone(row)
            try replica.upsertRecord(ReplicaRecord(root, zoneKey: zone.zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
            if let serverTime = root.modificationDate { try replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID) }
        }
    }

    /// A space this Mac no longer holds: its zone row, its replica rows, its marks, its follows and, when
    /// it had one, its team's local rows (under the apply guard, so nothing is sent).
    private func forget(_ zone: SpaceZone, teamID: String?) async throws {
        try await store.perform { state in
            try state.replica.apply { replica in
                // The follows go first: they are found through the space's identities, which the purge removes.
                try SpaceFollows.forget(zoneKey: zone.zoneKey, connection: state.connection)
                if let teamID { try SpaceRows.purge(teamID: teamID, zoneKey: zone.zoneKey, connection: state.connection) }
                for table in ["ck_records", "ck_unprojected", "ck_echo", "ck_quarantine", "ck_text_bases", "ck_identity", "ck_zones"] {
                    try state.connection.execute("DELETE FROM \(table) WHERE zone_key = ?", [.text(zone.zoneKey)])
                }
                try replica.setEngineState(SpaceSync.StateScope.gone(zone.zoneKey), nil)
                try replica.setEngineState(StateScope.downloadAll(zone.zoneKey), nil)
            }
        }
    }

    /// The Doc space a Doc is shared through (§9.1 `doc`, D5): the one this account owns for it, else a
    /// new one, shared. Moving the Doc and its Comments into it is `SpaceMoveJob`'s; the Doc
    /// keeps its `notebookID`, so its notebook still lists it for the owner.
    func docSpace(forArtifact artifactID: String, title: String, owner: SyncPerson) async throws -> SpaceSummary {
        if let held = try await list().first(where: { $0.isOwned && $0.gone == nil && $0.kind == "doc" && $0.primaryID == artifactID }) {
            return held
        }
        return try await create(kind: "doc", name: title, owner: owner, primaryID: artifactID)
    }

    // MARK: - Teams

    /// Mirrors every team and family space this Mac holds into `teams` (§13.7): a new space gets a row
    /// under its space id; a team from generation 1 keeps its row and id, which now names the space's
    /// zone as the library container knows it. A member's identities move from the old container's
    /// owner name (the provisional zone) to the new one, so their team copies send into the space.
    func mirrorTeams() async throws {
        try await adoptJoinedTeams()
        let at = now().timeIntervalSinceReferenceDate
        try await store.perform { state in
            let connection = state.connection
            let before = try SpaceRows.teamZoneKeys(connection)
            for space in try Self.summaries(connection) where space.gone == nil && (space.kind == "team" || space.kind == "family") {
                let teamID = space.localTeamID
                let root = try state.replica.record(zoneKey: space.zone.zoneKey, recordName: SyncSchema.rootRecordName)
                    .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
                let planCode = root?.fields["familyPlanCode"]?.stringValue
                try connection.execute("""
                    INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, zone_owner_record_name, share_record_name,
                                       created_at, joined_at, updated_at, family_plan_code)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9, ?9, ?10)
                    ON CONFLICT(id) DO UPDATE SET
                        name = CASE WHEN excluded.name = '' THEN teams.name ELSE excluded.name END, role = excluded.role,
                        permission = excluded.permission, zone_scope = excluded.zone_scope, zone_name = excluded.zone_name,
                        zone_owner_record_name = excluded.zone_owner_record_name,
                        share_record_name = COALESCE(excluded.share_record_name, teams.share_record_name),
                        family_plan_code = excluded.family_plan_code, updated_at = excluded.updated_at
                """, [
                    .text(teamID), .text(space.name), .text(space.isOwned ? "owner" : "member"),
                    .text(space.permission == .readWrite ? "readWrite" : "readOnly"), .text(space.isOwned ? "private" : "shared"),
                    .text(space.zone.zoneID.zoneName), .text(space.isOwned ? nil : space.zone.zoneID.ownerName),
                    .text(space.isShared ? CloudRecordID.zoneShareRecordName : nil), .real(at), .text(planCode),
                ])
                if let old = before[teamID] { try SpaceRows.rehome(from: old, to: space.zone.zoneKey, connection: connection) }
            }
        }
    }

    /// A team from generation 1 that this member's Mac now holds as a joined space: its `teams` row
    /// names the space's zone under the owner as the library container knows them (user record names
    /// differ between containers), and its identities move there (§13.7 step 4). Needs no root, so it
    /// runs before the space's first walk (`SyncCoordinator.acceptShare`'s `prepare`), and the space's
    /// records land on the member's team copies, never beside them.
    func adoptJoinedTeams() async throws {
        try await store.perform { state in
            let connection = state.connection
            var zones: [SpaceZone] = []
            try connection.query("SELECT zone_key FROM ck_zones WHERE kind = 'space' AND database = 'shared' ORDER BY zone_key", []) { row in
                if let key = row.text(0), let held = try? state.replica.zone(key: key), let zone = SpaceZone(held) { zones.append(zone) }
            }
            let before = try SpaceRows.teamZoneKeys(connection)
            for zone in zones {
                guard case .space(let spaceID) = zone.name,
                      let teamID = try connection.scalarText(
                          "SELECT id FROM teams WHERE role = 'member' AND (zone_name = ? OR id = ?) ORDER BY id LIMIT 1",
                          [.text(zone.zoneID.zoneName), .text(spaceID)]
                      ), let old = before[teamID], old != zone.zoneKey
                else { continue }
                try connection.execute(
                    "UPDATE teams SET zone_scope = 'shared', zone_name = ?, zone_owner_record_name = ? WHERE id = ?",
                    [.text(zone.zoneID.zoneName), .text(zone.zoneID.ownerName), .text(teamID)]
                )
                try SpaceRows.rehome(from: old, to: zone.zoneKey, connection: connection)
            }
        }
    }

    // MARK: - Changing a root

    /// Writes `changes` into the space's root by compare-and-set, on the change tag this Mac holds;
    /// another device's write meanwhile is taken and the changes written over it again, per field.
    func updateRoot(_ space: SpaceSummary, _ changes: [String: RecordPatch.Change]) async throws {
        guard !changes.isEmpty else { return }
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: space.zone.zoneID)
        let zoneKey = space.zone.zoneKey
        var held = try await store.perform { try $0.replica.record(zoneKey: zoneKey, recordName: SyncSchema.rootRecordName) }
            .map { (payload: $0.payload, systemFields: $0.systemFields) }
        for _ in 0..<4 {
            guard let base = held, var envelope = try? SyncEnvelope(storedPayload: base.payload) else {
                throw SpaceServiceError.failed("this Mac holds no root for the space")
            }
            let at = now()
            let deviceID = deviceID
            var clock = try await store.perform { try $0.replica.loadClock() }
            var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName, changes: changes)
            patch.changes["editedAt"] = patch.changes["editedAt"] ?? .value(SyncJSON(SyncTime.milliseconds(at)))
            try envelope.apply(patch) { _, policy, seen in
                if var minting = clock, let stamp = minting.mint(policy, eventTime: SyncTime.milliseconds(at), seen: seen, now: SyncTime.milliseconds(at)) {
                    clock = minting
                    return stamp
                }
                return SyncStamp.provisional(policy, deviceID: deviceID)
            }
            if let clock { try await store.perform { try $0.replica.saveClock(clock, now: at) } }
            let result = try await transport.modifyRecords(saving: [CloudRecord(
                id: rootID, recordType: SyncRecordType.zoneRoot.rawValue,
                encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())], systemFields: base.systemFields
            )], in: space.zone.database)
            if let saved = result.savedRecord(rootID) {
                try await store.perform { try $0.replica.upsertRecord(ReplicaRecord(saved, zoneKey: zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil)) }
                try await mirrorTeams()
                return
            }
            guard let error = result.error(for: rootID), error.code == .serverRecordChanged, let server = error.serverRecord,
                  let payload = server.payload else {
                throw SpaceServiceError.failed(result.error(for: rootID)?.description ?? "no answer for the space's root")
            }
            held = (payload, server.systemFields)
            try await store.perform { try $0.replica.upsertRecord(ReplicaRecord(server, zoneKey: zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil)) }
        }
        throw SpaceServiceError.failed("the space's root kept changing")
    }

    /// Renames the space for everyone (the owner only): the root's name, and the share's title, which is
    /// what an invitee sees before accepting.
    func rename(_ space: SpaceSummary, to name: String) async throws {
        // The name is every member's: only the owner rewrites it (F19).
        guard space.isOwned else { throw SpaceServiceError.notOwner }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await updateRoot(space, ["name": .value(.string(trimmed))])
        if space.isOwned, space.isShared { try await shares.share(space.zone, title: trimmed) }
    }

    /// A family's plan code, which members' Macs present to join the plan (docs/family-design.md);
    /// nil ends it. Owner only, as generation 1's `setFamilyPlan`.
    func setFamilyPlanCode(_ space: SpaceSummary, _ code: String?) async throws {
        guard space.isOwned else { throw SpaceServiceError.notOwner }
        var changes: [String: RecordPatch.Change] = ["familyPlanCode": .value(code.map(SyncJSON.string) ?? .null)]
        if code != nil, space.kind == "team" { changes["kind"] = .value(.string("family")) }
        try await updateRoot(space, changes)
    }

    // MARK: - Deleting and going

    /// What deleting `space` destroys on this Mac, for the confirmation that lists the counts (§9.6).
    func counts(_ space: SpaceSummary) async throws -> [String: Int] {
        try await store.perform { try SpaceRows.counts(teamID: space.localTeamID, connection: $0.connection) }
    }

    /// Deletes an owned space and everything in it, for every member (§9.6 "Delete space", after the
    /// owner confirmed the counts): its zone, then its rows on this Mac.
    func delete(_ space: SpaceSummary) async throws {
        guard space.isOwned else { throw SpaceServiceError.notOwner }
        let deleted = try await transport.modifyZones(saving: [], deleting: [space.zone.zoneID], in: .private)
        if case .failure(let error)? = deleted.deleted[space.zone.zoneID], error.code != .zoneNotFound {
            throw SpaceServiceError.failed(error.description)
        }
        try await forget(space.zone, teamID: space.localTeamID)
        Self.logger.info("Deleted a space")
    }

    /// The local team ids of spaces that went within the last 30 days: their rows stay on this Mac,
    /// hidden, while the learner may still keep a personal copy (§2.5, §9.6).
    func hiddenTeamIDs() async throws -> Set<String> {
        Set(try await list().filter { $0.gone != nil }.map(\.localTeamID))
    }

    /// Spaces that went more than 30 days ago lose their rows on this Mac; returns how many.
    @discardableResult
    func purgeExpired() async throws -> Int {
        let cutoff = now().addingTimeInterval(-Self.goneKeepInterval)
        var purged = 0
        for space in try await list() {
            guard let gone = space.gone, gone.at < cutoff else { continue }
            try await forget(space.zone, teamID: space.localTeamID)
            purged += 1
        }
        if purged > 0 { Self.logger.info("Purged \(purged) spaces that went 30 days ago") }
        return purged
    }

    // MARK: - This Mac's choices

    /// "Download all files" for a space: whether this Mac fetches every satellite of the space ahead of
    /// use. Bytes only; the space's records are walked either way (§9.7). Device-local.
    func setDownloadsAllFiles(_ space: SpaceSummary, _ on: Bool) async throws {
        let key = StateScope.downloadAll(space.zone.zoneKey)
        try await store.perform { try $0.replica.setEngineState(key, on ? Data("1".utf8) : nil) }
    }

    func downloadsAllFiles(_ space: SpaceSummary) async throws -> Bool {
        let key = StateScope.downloadAll(space.zone.zoneKey)
        return try await store.perform { try $0.replica.engineState(key) } != nil
    }
}
