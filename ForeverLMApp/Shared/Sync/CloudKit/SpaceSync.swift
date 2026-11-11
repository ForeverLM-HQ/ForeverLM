import Foundation
import OSLog

/// One space zone this device holds: an owned one in its private database, or one shared with it in
/// its shared database under the owner's name (§2.2).
struct SpaceZone: Hashable, Sendable {
    let zoneKey: String
    let zoneID: CloudZoneID
    let database: CloudDatabaseScope

    var isOwned: Bool { database == .private }
    var name: SyncZoneName { SyncZoneName(zoneID.zoneName) ?? .space("") }

    init(_ zoneID: CloudZoneID, in database: CloudDatabaseScope) {
        self.zoneID = zoneID
        self.database = database
        zoneKey = database == .private
            ? ReplicaZone.key(database: .private, zoneName: zoneID.zoneName)
            : ReplicaZone.key(database: .shared, zoneName: zoneID.zoneName, ownerRecordName: zoneID.ownerName)
    }

    init?(_ row: ReplicaZone) {
        guard row.kind == SyncZone.space.rawValue.lowercased(), SyncZoneName(row.zoneName)?.isSpace == true else { return nil }
        if row.database == .shared {
            guard let owner = row.ownerRecordName else { return nil }
            self.init(CloudZoneID(row.zoneName, ownerName: owner), in: .shared)
        } else {
            self.init(CloudZoneID(row.zoneName), in: .private)
        }
    }
}

/// Every space on this device (docs/cloudkit-schema-design.md §2.2, §2.3, §6.2, §9.2, §9.7, D13): a
/// light walk of each space zone with `desiredKeys = ["payload"]`, so no satellite's `data` or
/// `asset` rides a change feed, and a compare-and-set sender for the space records the outbox hands
/// out. The private engine never touches a space zone, and spaces never go through CKSyncEngine.
///
/// - Zones: owned spaces come from the private database's zone changes, joined ones from the shared
///   database's, each with a token of its own; a feed read from nil that no longer lists a held space
///   finds it gone. A space gone (deleted by its owner, left, or access lost) keeps its local rows for
///   the space packages to hide or copy (§9.6); its replica forgets the records that were not moved.
/// - Walk: a space's root is read first and its salt adopted; then its changes page by page, applied
///   through the private engine's inbound rules (merge with pending changes, echoes, other salts).
///   The zone-wide share in the feed gives this member's permission. After a pass from nil, and once
///   a week, the replica audit sweeps what such a pass never reports (§2.3).
/// - Send: `SpaceWriteGuard` decides before anything goes out: a read-only member's write, a personal
///   type or a private chat kind is refused and its rows dropped, the server's version projected back;
///   a refused field is left out and the rest sent (§9.2). Saves are compare-and-set; a conflict merges
///   as the engine's does. A record `moveMaps` lists as moved out of its space, met as `unknownItem`
///   or `zoneNotFound`, has its pending fields applied, with their stamps, to its copy (§4.4, §6.2).
///   A member's write over the owner's quota pauses writes and names the owner (§2.5).
/// - Push: a shared-database push (`flm-shared-db`) walks the joined spaces; a private-database push
///   checks which zones changed, and one that names nothing but `Content` (satellite uploads) is
///   coalesced to one check per 30 seconds (§2.3).
///
/// Generation 2 only: `SyncCoordinator` makes it, and nothing does under generation 1.
actor SpaceSync {
    struct Configuration: Sendable {
        var pendingMax = SyncSchema.Limits.enginePendingChangesMax
        var batchMaxRecords = SyncSchema.Limits.batchMaxRecords
        var batchMaxBytes = SyncSchema.Limits.batchMaxBytes
        var conflictRoundsMax = 5
        var refusalsMax = 3
        var auditInterval: TimeInterval = 7 * 86_400
        var fetchPageSize: Int? = nil
        /// Private-database pushes that name only `Content` are checked at most this often (§2.3).
        var contentWakeInterval: TimeInterval = 30
    }

    /// What a private-database push found.
    struct PrivateChanges: Equatable, Sendable {
        /// `Library` or `Catalog` changed: the private engine fetches.
        var engineZones = false
        var spaces: [SpaceZone] = []
        /// Nothing but `Content` changed.
        var contentOnly = false
        /// The push came within 30 seconds of a check that found only `Content`, and was not checked.
        var coalesced = false
    }

    /// The shared database's one subscription (D36).
    static let sharedSubscriptionID = "flm-shared-db"
    static let walkKeys = [CloudRecord.payloadKey]

    /// `ck_engine_state` scopes SpaceSync keeps.
    enum StateScope {
        static func databaseToken(_ database: CloudDatabaseScope) -> String { "spaces.\(database.rawValue).database" }
        static let subscription = "spaces.subscription"
        /// A space that went, with why and when, until the space packages act on it (§9.6).
        static func gone(_ zoneKey: String) -> String { "space.gone.\(zoneKey)" }
        static let gonePrefix = "space.gone."
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SpaceSync")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let moveMaps: MoveMapIndex
    let deviceID: String
    let configuration: Configuration
    private let pacer: @Sendable (CloudDatabaseScope) async -> SyncPacer
    private let clock: @Sendable () -> Date

    private var user: String?
    private var subscribed = false
    private var onScreen: String?
    private var lastOpened: [String: Date] = [:]
    private var conflictRounds: [String: Int] = [:]
    private var refusals: [String: Int] = [:]
    private var forgotHandedOutDeletes = false
    private var lastPrivateCheck: (at: Date, contentOnly: Bool)?
    /// Changes waiting to go out after the last send pass, for the pacer's small-record backlog.
    private(set) var pendingCount = 0
    /// Whose iCloud storage refused the last write into a space, while writes wait for it (§2.5).
    private(set) var quotaOwner: String?

    init(transport: CloudTransport, store: PrivateSyncLocalStore, moveMaps: MoveMapIndex, deviceID: String,
         configuration: Configuration = Configuration(), pacer: @escaping @Sendable (CloudDatabaseScope) async -> SyncPacer,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.store = store
        self.moveMaps = moveMaps
        self.deviceID = deviceID
        self.configuration = configuration
        self.pacer = pacer
        self.clock = clock
    }

    /// The space on screen is walked first, then the others by when they were last opened (§2.2).
    func setPriority(onScreen zoneKey: String?, lastOpened: [String: Date]) {
        onScreen = zoneKey
        self.lastOpened = lastOpened
    }

    // MARK: - A round

    /// The zone lists of both databases, every space's changes, then what is pending.
    /// Returns whether every space was walked to the end (`walk`), which work that needs every zone fetched
    /// waits for.
    @discardableResult
    func sync() async throws -> Bool {
        try await prepare()
        try await refreshZones()
        var walkedAll = true
        for zone in try await heldSpaces() { if try await !walk(zone) { walkedAll = false } }
        try await sendChanges()
        return walkedAll
    }

    /// The account's user record name and the shared database's subscription, once; the moves the
    /// personal root lists.
    func prepare() async throws {
        if !forgotHandedOutDeletes {
            forgotHandedOutDeletes = true
            // A delete handed out before a quit can never be acknowledged by this process, and while its row
            // stays, a record the learner brought back under the same name waits for it for ever (M7). The
            // private engine does the same for its own zones.
            let keys = PrivateSyncZones.all.map { PrivateSyncZones.key($0) }
            try await store.perform { state in
                try state.connection.execute(
                    "DELETE FROM ck_pending_deletes WHERE zone_key NOT IN (\(keys.map { _ in "?" }.joined(separator: ", ")))", keys.map { .text($0) }
                )
            }
        }
        if user == nil { user = try await transport.userRecordName() }
        if !subscribed, let sharing = transport as? CloudSharingTransport {
            let saved = try await store.perform { try $0.replica.engineState(StateScope.subscription) } != nil
            if !saved {
                try await sharing.saveDatabaseSubscription(Self.sharedSubscriptionID, in: .shared)
                let now = clock()
                try await store.perform { try $0.replica.setEngineState(StateScope.subscription, Data(Self.sharedSubscriptionID.utf8), now: now) }
            }
            subscribed = true
        }
        try await refreshMoveMaps()
    }

    /// Reads the moves the personal root lists (D51).
    func refreshMoveMaps() async throws {
        try await moveMaps.refreshFromPersonalRoot(store: store, transport: transport)
    }

    /// The moves as the server's personal root lists them now, before a lost record is judged.
    private func refreshMoveMapsFromServer() async throws {
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: PrivateSyncZones.library)
        guard case .success(let record) = try await transport.record(rootID, in: .private, desiredKeys: [CloudRecord.payloadKey]),
              let payload = record.payload, let root = try? SyncEnvelope(storedPayload: payload),
              let salt = root.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        else { return }
        await moveMaps.refresh(from: root, fetch: MoveMapIndex.transportFetch(transport, salt: salt))
    }

    // MARK: - Zones

    /// The spaces this device holds and has not lost, the one on screen first, then by last opened.
    func heldSpaces() async throws -> [SpaceZone] {
        let zones = try await store.perform { state -> [SpaceZone] in
            var keys: [String] = []
            try state.connection.query("SELECT zone_key FROM ck_zones WHERE kind = 'space' ORDER BY zone_key", []) { keys.append($0.text(0) ?? "") }
            return try keys.compactMap { key in
                guard try state.replica.engineState(StateScope.gone(key)) == nil, let row = try state.replica.zone(key: key) else { return nil }
                return SpaceZone(row)
            }
        }
        let onScreen = onScreen
        let lastOpened = lastOpened
        return zones.sorted { lhs, rhs in
            if (lhs.zoneKey == onScreen) != (rhs.zoneKey == onScreen) { return lhs.zoneKey == onScreen }
            let left = lastOpened[lhs.zoneKey] ?? .distantPast
            let right = lastOpened[rhs.zoneKey] ?? .distantPast
            return left != right ? left > right : lhs.zoneKey < rhs.zoneKey
        }
    }

    /// The spaces that went, with why (`deleted`, `left`, `saltChanged`), for the space packages (§9.6).
    func goneSpaces() async throws -> [String: String] {
        try await store.perform { state in
            var gone: [String: String] = [:]
            try state.connection.query("SELECT scope, state FROM ck_engine_state WHERE substr(scope, 1, ?) = ?",
                                       [.integer(Int64(StateScope.gonePrefix.count)), .text(StateScope.gonePrefix)]) { row in
                gone[String((row.text(0) ?? "").dropFirst(StateScope.gonePrefix.count))] = String(decoding: row.blob(1) ?? Data(), as: UTF8.self)
            }
            return gone
        }
    }

    /// Reads both databases' zone changes; returns the spaces that changed.
    @discardableResult
    func refreshZones() async throws -> [SpaceZone] {
        var changed: [SpaceZone] = []
        for database in CloudDatabaseScope.allCases {
            changed += try await refreshZones(in: database).spaces
        }
        return changed
    }

    private func refreshZones(in database: CloudDatabaseScope) async throws -> PrivateChanges {
        let scope = StateScope.databaseToken(database)
        var token = try await store.perform { try $0.replica.engineState(scope) }.map(CloudChangeToken.init(data:))
        var fromNil = token == nil
        var listed = Set<String>()
        var found = PrivateChanges()
        var names = Set<String>()
        while true {
            let changes: CloudDatabaseChanges
            do {
                changes = try await request(database, writes: false) { [transport, token] in
                    try await transport.databaseChanges(in: database, since: token, resultsLimit: nil)
                }
            } catch let error as CloudError where error.code == .changeTokenExpired && token != nil {
                token = nil
                fromNil = true
                continue
            }
            for zoneID in changes.modifiedZones {
                names.insert(zoneID.zoneName)
                guard SyncZoneName(zoneID.zoneName)?.isSpace == true else { continue }
                let zone = SpaceZone(zoneID, in: database)
                listed.insert(zone.zoneKey)
                try await hold(zone)
                found.spaces.append(zone)
            }
            for deletion in changes.deletedZones where SyncZoneName(deletion.zoneID.zoneName)?.isSpace == true {
                try await spaceGone(SpaceZone(deletion.zoneID, in: database), reason: deletion.reason == .deleted ? "deleted" : deletion.reason.rawValue)
            }
            let next = changes.changeToken.data
            try await store.perform { try $0.replica.setEngineState(scope, next) }
            guard changes.moreComing else { break }
            token = changes.changeToken
        }
        if fromNil {
            // A feed read from nil lists every zone and no deletion: a held space it leaves out is gone.
            for zone in try await heldSpaces() where zone.database == database && !listed.contains(zone.zoneKey) {
                try await spaceGone(zone, reason: "deleted")
            }
        }
        let engineNames: Set<String> = [SyncZone.library.rawValue, SyncZone.catalog.rawValue]
        found.engineZones = !names.isDisjoint(with: engineNames)
        found.contentOnly = names == [SyncZone.content.rawValue]
        return found
    }

    /// Writes the zone's `ck_zones` row when it is new, and forgets that it went if it comes back.
    private func hold(_ zone: SpaceZone) async throws {
        try await store.perform { state in
            let replica = state.replica
            try replica.setEngineState(StateScope.gone(zone.zoneKey), nil)
            guard try replica.zone(key: zone.zoneKey) == nil else { return }
            try replica.upsertZone(ReplicaZone(
                zoneKey: zone.zoneKey, database: zone.isOwned ? .private : .shared, zoneName: zone.zoneID.zoneName,
                ownerRecordName: zone.isOwned ? nil : zone.zoneID.ownerName, kind: SyncZone.space.rawValue.lowercased(),
                role: zone.isOwned ? "owner" : "member", permission: zone.isOwned ? CloudShare.Permission.readWrite.rawValue : nil
            ))
        }
    }

    /// A space that went: its replica forgets every record no move took elsewhere (a moved record
    /// keeps its row and the root its salt, so a pending write can still go to the copy), its token and
    /// passes go, and the gone mark tells the space packages, which keep or hide its local rows (§9.6).
    func spaceGone(_ zone: SpaceZone, reason: String) async throws {
        do {
            try await refreshMoveMapsFromServer()
        } catch {
            Self.logger.error("Refreshing the move maps before a space went failed: \(String(describing: error), privacy: .public)")
        }
        let now = clock()
        let moveMaps = moveMaps
        try await store.perform { state in
            let connection = state.connection
            var rows: [(name: String, type: String, wireID: String)] = []
            try connection.query("SELECT record_name, record_type, wire_id FROM ck_records WHERE zone_key = ?", [.text(zone.zoneKey)]) {
                rows.append(($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? ""))
            }
            #if os(macOS)
            // Someone else's space: what it laid onto this Mac's own rows goes with it, a Doc shared
            // with this account and its Comments (`DocSpaces`; Comments first, their Doc is their parent).
            // An owned space that went was emptied by a move back, or deleted here with its rows.
            if !zone.isOwned {
                try state.replica.apply { _ in
                    for type in [SyncRecordType.comment, .artifact] {
                        for row in rows where row.type == type.rawValue {
                            try state.projectDeletion(zoneKey: zone.zoneKey, recordName: row.name, type: type, wireID: row.wireID)
                        }
                    }
                }
            }
            #endif
            try connection.executeScript("BEGIN IMMEDIATE")
            do {
                for row in rows where row.name != SyncSchema.rootRecordName
                    && moveMaps.retarget(type: row.type, id: row.wireID, from: zone.zoneID.zoneName) == nil {
                    try state.replica.deleteRecord(zoneKey: zone.zoneKey, recordName: row.name)
                }
                for table in ["ck_unprojected", "ck_echo", "ck_quarantine", "ck_text_bases"] {
                    try connection.execute("DELETE FROM \(table) WHERE zone_key = ?", [.text(zone.zoneKey)])
                }
                try connection.execute("UPDATE ck_zones SET change_token = NULL, last_complete_pass_at = NULL WHERE zone_key = ?", [.text(zone.zoneKey)])
                let mark = SyncJSON.object(["reason": .string(reason), "at": SyncJSON(SyncTime.milliseconds(now))]).serialized()
                try state.replica.setEngineState(StateScope.gone(zone.zoneKey), mark, now: now)
                try connection.executeScript("COMMIT")
            } catch {
                try? connection.executeScript("ROLLBACK")
                throw error
            }
        }
        Self.logger.info("A space went (\(reason, privacy: .public))")
    }

    private func isGone(_ zoneKey: String) async throws -> Bool {
        try await store.perform { try $0.replica.engineState(StateScope.gone(zoneKey)) != nil }
    }

    // MARK: - Walking a space

    /// Reads the space's root (and with it its salt) when this device has none, then its changes to
    /// the end; after a pass from nil, and weekly, the audit sweeps what the pass could not report.
    ///
    /// Returns whether the walk reached the end of the space's changes: false when a request failed or a
    /// root is not there yet, so work that needs every zone fetched (the janitor, GC, duplicate resolution,
    /// the cover backfill) is not run on the strength of a round in which one space did not (F16). A space
    /// that went counts as walked: nothing in it is left to fetch.
    @discardableResult
    func walk(_ zone: SpaceZone) async throws -> Bool {
        if try await isGone(zone.zoneKey) { return true }
        guard try await adoptRoot(zone) else { return try await isGone(zone.zoneKey) }
        var token = try await store.perform { try $0.replica.zone(key: zone.zoneKey)?.changeToken }.map(CloudChangeToken.init(data:))
        var passStart = clock()
        var fromNil = token == nil
        var restarted = false
        var completed = false
        var reachedEnd = false
        walking: while true {
            let result: Result<CloudZoneChanges, CloudError>
            do {
                let since = token
                result = try await request(zone.database, writes: false) { [transport, configuration] in
                    try await transport.zoneChanges(zone.zoneID, in: zone.database, since: since, desiredKeys: SpaceSync.walkKeys,
                                                    resultsLimit: configuration.fetchPageSize)
                }
            } catch let error as CloudError {
                Self.logger.error("Walking a space failed: \(error.description, privacy: .public)")
                return false
            }
            switch result {
            case .failure(let error) where error.code == .changeTokenExpired:
                guard !restarted else { return false }
                restarted = true
                token = nil
                fromNil = true
                passStart = clock()
            case .failure(let error) where [.zoneNotFound, .userDeletedZone].contains(error.code):
                try await spaceGone(zone, reason: "deleted")
                return true
            case .failure(let error):
                Self.logger.error("A space's changes failed: \(error.description, privacy: .public)")
                return false
            case .success(var page):
                var keepToken = false
                if !page.failed.isEmpty {
                    let failed = Array(page.failed.keys)
                    let refetched = try await request(zone.database, writes: false) { [transport] in
                        try await transport.records(failed, in: zone.database, desiredKeys: SpaceSync.walkKeys)
                    }
                    for outcome in refetched.values {
                        switch outcome {
                        case .success(let record): page.modified.append(record)
                        case .failure(let error) where error.code == .unknownItem: break
                        case .failure: keepToken = true
                        }
                    }
                }
                for share in page.modified.compactMap(\.share) { try await applyShare(share, to: zone) }
                let complete = fromNil && !page.moreComing && !keepToken
                if try await absorb(page, zoneKey: zone.zoneKey, passStart: passStart, storeToken: !keepToken, complete: complete) != nil {
                    try await spaceGone(zone, reason: "saltChanged")
                    return true
                }
                if keepToken || !page.moreComing {
                    completed = complete
                    reachedEnd = !keepToken
                    break walking
                }
                token = page.changeToken
            }
        }
        if !zone.isOwned, try await store.perform({ try $0.replica.zone(key: zone.zoneKey)?.permission }) == nil {
            // The feed did not carry the share's roster: it is read by name.
            let shareID = CloudRecordID(CloudRecordID.zoneShareRecordName, in: zone.zoneID)
            if case .success(let record) = try await request(zone.database, writes: false, { [transport] in
                try await transport.record(shareID, in: zone.database, desiredKeys: nil)
            }), let share = record.share {
                try await applyShare(share, to: zone)
            }
        }
        let now = clock()
        let interval = configuration.auditInterval
        let due = try await store.perform { try ReplicaAudit.isDue(zoneKey: zone.zoneKey, in: $0, now: now, interval: interval) }
        if completed || due {
            let audit = ReplicaAudit(transport: transport, store: store, moveMaps: moveMaps, clock: clock, pageSize: configuration.fetchPageSize)
            do {
                try await audit.run(zone.zoneID, in: zone.database, zoneKey: zone.zoneKey)
            } catch {
                Self.logger.error("A space's audit could not finish: \(String(describing: error), privacy: .public)")
            }
        }
        return reachedEnd
    }

    /// Reads the space's root by name when this device holds none, and adopts its salt. False while
    /// the space has no root yet (its owner is still making it) or when it went.
    private func adoptRoot(_ zone: SpaceZone) async throws -> Bool {
        if try await store.perform({ try $0.replica.zone(key: zone.zoneKey)?.saltID }) != nil { return true }
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: zone.zoneID)
        let fetched = try await request(zone.database, writes: false) { [transport] in
            try await transport.record(rootID, in: zone.database, desiredKeys: SpaceSync.walkKeys)
        }
        switch fetched {
        case .success(let root):
            guard let payload = root.payload, let envelope = try? SyncEnvelope(storedPayload: payload),
                  let salt = envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:)),
                  envelope.fields["saltID"]?.stringValue == RecordNaming.saltID(salt)
            else {
                Self.logger.error("A space's root carries no salt this build reads")
                return false
            }
            try await store.perform { state in
                let replica = state.replica
                try replica.upsertRecord(ReplicaRecord(root, zoneKey: zone.zoneKey, wireID: SyncSchema.rootRecordName, seenPass: nil))
                guard var row = try replica.zone(key: zone.zoneKey) else { return }
                row.saltID = RecordNaming.saltID(salt)
                if let primaryID = envelope.fields["primaryID"]?.stringValue { row.primaryID = primaryID }
                try replica.upsertZone(row)
            }
            return true
        case .failure(let error) where error.code == .unknownItem:
            return false
        case .failure(let error) where [.zoneNotFound, .userDeletedZone].contains(error.code):
            try await spaceGone(zone, reason: "deleted")
            return false
        case .failure(let error):
            throw error
        }
    }

    /// The zone-wide share in a space's feed: this member's permission and the share's record name.
    private func applyShare(_ share: CloudShare, to zone: SpaceZone) async throws {
        guard !zone.isOwned, let me = share.currentUser else { return }
        try await store.perform { state in
            guard var row = try state.replica.zone(key: zone.zoneKey) else { return }
            row.permission = me.permission.rawValue
            row.shareRecordName = CloudRecordID.zoneShareRecordName
            try state.replica.upsertZone(row)
        }
    }

    /// Applies one page in one transaction, as the private engine applies its own (§6.2, §6.4).
    private func absorb(_ page: CloudZoneChanges, zoneKey: String, passStart: Date, storeToken: Bool, complete: Bool) async throws -> PurgeHandler.Event? {
        let now = clock()
        let moveMaps = moveMaps
        return try await store.perform { state -> PurgeHandler.Event? in
            try state.replica.apply { replica -> PurgeHandler.Event? in
                let applied = try InboundApply(state: state, now: now, passStart: passStart, moveMaps: moveMaps)
                for record in page.modified {
                    if let event = try applied.absorbFetched(record, zoneKey: zoneKey) { return event }
                }
                for deletion in page.deleted {
                    try applied.absorbDeletion(deletion, zoneKey: zoneKey)
                }
                if var zone = try replica.zone(key: zoneKey) {
                    if storeToken { zone.changeToken = page.changeToken.data }
                    if complete { zone.lastCompletePassAt = passStart.timeIntervalSinceReferenceDate }
                    try replica.upsertZone(zone)
                }
                return nil
            }
        }
    }

    // MARK: - Pushes

    /// A push from the shared database walks the joined spaces that changed.
    func handleSharedPush() async throws {
        try await prepare()
        for zone in try await refreshZones(in: .shared).spaces { try await walk(zone) }
    }

    /// A push from the private database: which zones changed. The owned spaces among them are walked
    /// here; the caller hands `Library` and `Catalog` to the private engine. A push within 30 seconds
    /// of a check that found nothing but `Content` is not checked again (§2.3).
    func handlePrivatePush() async throws -> PrivateChanges {
        let now = clock()
        if let last = lastPrivateCheck, last.contentOnly, now.timeIntervalSince(last.at) < configuration.contentWakeInterval {
            return PrivateChanges(coalesced: true)
        }
        try await prepare()
        let changes = try await refreshZones(in: .private)
        lastPrivateCheck = (now, changes.contentOnly)
        for zone in changes.spaces { try await walk(zone) }
        return changes
    }

    // MARK: - Sending

    /// What the guard made of one change.
    enum Guarded {
        case send(OutboxChange)
        /// Refused whole: rows dropped, the server's version projected back.
        case refuse(SpaceWriteGuard.Refusal)
        /// Only refused fields changed: rows dropped, the local values stay.
        case nothingLeft
    }

    /// Sends the space records the outbox hands out, zone by zone, until a pass makes no progress.
    func sendChanges() async throws {
        try await prepare()
        for _ in 0..<configuration.pendingMax {
            let now = clock()
            let limit = configuration.pendingMax
            let changes = try await store.perform { state -> [OutboxChange] in
                try state.drainReady()
                // The batch first: encoding frees a parked oversize record that has shrunk.
                let due = try state.nextChanges(now: now, limit: limit, scope: .spaces)
                var parked = Set<String>()
                try state.connection.query("SELECT zone_key || char(31) || record_name FROM ck_quarantine", []) { parked.insert($0.text(0) ?? "") }
                return due.filter { !parked.contains($0.zoneKey + "\u{1F}" + $0.recordName) }
            }
            pendingCount = changes.count
            guard !changes.isEmpty else { return }
            var progressed = false
            for zoneKey in Set(changes.map(\.zoneKey)).sorted() {
                progressed = try await send(changes.filter { $0.zoneKey == zoneKey }, zoneKey: zoneKey) || progressed
            }
            if !progressed { return }
        }
    }

    /// One zone's changes: guarded, then sent in batches of at most 200 records and 800 KiB.
    private func send(_ changes: [OutboxChange], zoneKey: String) async throws -> Bool {
        let now = clock()
        let (row, root) = try await store.perform { state -> (ReplicaZone?, SyncEnvelope?) in
            (try state.replica.zone(key: zoneKey),
             try state.replica.record(zoneKey: zoneKey, recordName: SyncSchema.rootRecordName).flatMap { try? SyncEnvelope(storedPayload: $0.payload) })
        }
        guard let row, let zone = SpaceZone(row) else {
            try await release(changes)
            return false
        }
        if try await isGone(zoneKey) {
            return try await settleGone(changes, zone: zone)
        }
        if let minimum = root?.fields["minClientRevision"]?.intValue, minimum > SyncSchema.schemaRevision {
            // The space asks for a newer build (§12.5): nothing goes to it until an update.
            try await release(changes)
            return false
        }
        // A joined space is written only on a roster that says read-write: one that has not been read yet
        // holds the changes until the walk has (a refusal would discard the member's edit), and anything but
        // read-write is read-only (F18).
        var permission: SpaceWriteGuard.Writer.Permission = .readWrite
        if !zone.isOwned {
            switch row.permission {
            case CloudShare.Permission.readWrite.rawValue: permission = .readWrite
            case nil:
                try await release(changes)
                return false
            default: permission = .readOnly
            }
        }
        let writer = SpaceWriteGuard.Writer(user: user ?? "", permission: permission, isOwner: zone.isOwned)
        var sendable: [OutboxChange] = []
        var progressed = false
        for change in changes {
            let held = try await store.perform { try $0.replica.record(zoneKey: change.zoneKey, recordName: change.recordName) }
            let heldEnvelope = held.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            switch Self.guarded(change, held: heldEnvelope, writer: writer) {
            case .send(let allowed):
                sendable.append(allowed)
            case .refuse(let refusal):
                Self.logger.error("A write into a space was refused: \(refusal.description, privacy: .public)")
                try await refuse(change, held: held, now: now)
                progressed = true
            case .nothingLeft:
                try await store.perform { try $0.discard(change) }
                progressed = true
            }
        }

        var index = 0
        while index < sendable.count {
            let pacer = await pacer(zone.database)
            guard await pacer.request(.spaces, writes: true).isGo else {
                await pacer.withdraw(.spaces)
                try await release(Array(sendable[index...]))
                return progressed
            }
            var batch: [OutboxChange] = []
            var saves: [CloudRecord] = []
            var deletes: [CloudRecordID] = []
            var bytes = 0
            let limit = min(configuration.batchMaxRecords, await pacer.batchSize(.spaces))
            filling: while index < sendable.count, batch.count < limit {
                let change = sendable[index]
                let id = CloudRecordID(change.recordName, in: zone.zoneID)
                switch change.action {
                case .save(let envelope):
                    let payload = try envelope.storedPayload()
                    if !batch.isEmpty, bytes + payload.count > configuration.batchMaxBytes { break filling }
                    bytes += payload.count
                    saves.append(CloudRecord(id: id, recordType: change.recordType.rawValue,
                                             encryptedFields: [CloudRecord.payloadKey: .bytes(payload)], systemFields: change.systemFields))
                case .delete:
                    deletes.append(id)
                }
                batch.append(change)
                index += 1
            }
            let sentAt = clock()
            let results: CloudModifyResults
            do {
                let (saving, deleting) = (saves, deletes)
                results = try await transport.modifyRecords(saving: saving, deleting: deleting, in: zone.database)
            } catch let error as CloudError {
                await refused(error, zone: zone, root: root)
                try await release(Array(sendable[(index - batch.count)...]))
                return progressed
            }
            await pacer.succeeded(.spaces)
            let outcome = try await handleSent(batch, results: results, zone: zone, root: root, sentAt: sentAt)
            progressed = outcome.progressed || progressed
            if outcome.stop {
                try await release(Array(sendable[index...]))
                return progressed
            }
        }
        if progressed { quotaOwner = nil }
        return progressed
    }

    /// The guard's word on one change (§9.2).
    static func guarded(_ change: OutboxChange, held: SyncEnvelope?, writer: SpaceWriteGuard.Writer) -> Guarded {
        let type = change.recordType.rawValue
        guard case .save(var envelope) = change.action else {
            let refusals = SpaceWriteGuard.refusals(deleting: type, fields: held?.fields ?? [:], by: writer)
            return refusals.first.map(Guarded.refuse) ?? .send(change)
        }
        var stripped: [String] = []
        for refusal in SpaceWriteGuard.refusals(writing: type, fields: envelope.fields, by: writer) {
            switch refusal {
            case .privateKindsOnlyField(_, let field), .memberLocalField(_, let field):
                stripped.append(field)
            case .personalSatellite(_, let field) where change.recordType != .content:
                stripped.append(field)
            default:
                return .refuse(refusal)
            }
        }
        guard !stripped.isEmpty else { return .send(change) }
        for field in stripped {
            envelope.fields[field] = held?.fields[field]
            envelope.stamps[field] = held?.stamps[field]
        }
        Self.logger.error("Left out of a space write: \(stripped.sorted().joined(separator: ","), privacy: .public)")
        if let held, envelope.fields == held.fields, envelope.stamps == held.stamps { return .nothingLeft }
        return .send(change.with(action: .save(envelope)))
    }

    /// A refused change: its rows go, and the server's version, if there is one, is projected back
    /// over what was written locally.
    private func refuse(_ change: OutboxChange, held: ReplicaRecord?, now: Date) async throws {
        try await store.perform { state in
            try state.discard(change)
            if let held {
                try state.replica.apply { _ in try state.project(held) }
            }
        }
    }

    private func release(_ changes: [OutboxChange]) async throws {
        guard !changes.isEmpty else { return }
        try await store.perform { state in
            for change in changes { try state.release(change) }
        }
    }

    /// A refusal of a whole request: the pacer hears it, and a member's write over the owner's quota
    /// names the owner (§2.5).
    private func refused(_ error: CloudError, zone: SpaceZone, root: SyncEnvelope?) async {
        var owner: String?
        if error.code == .quotaExceeded {
            owner = Self.ownerName(root, zone: zone)
            quotaOwner = owner
        }
        await pacer(zone.database).refused(.spaces, with: error, owner: owner)
        Self.logger.error("A space send failed: \(error.description, privacy: .public)")
    }

    /// The space owner as members know them: the root's `owner` name, else their user record name.
    /// Nil for a space this account owns.
    static func ownerName(_ root: SyncEnvelope?, zone: SpaceZone) -> String? {
        guard !zone.isOwned else { return nil }
        let person = root?.fields["owner"].flatMap(SyncPerson.init(json:))
        return person?.name.flatMap { $0.isEmpty ? nil : $0 } ?? person?.user ?? zone.zoneID.ownerName
    }

    /// What a request's results do (§6.2). Returns whether anything settled, and whether to stop.
    private func handleSent(_ changes: [OutboxChange], results: CloudModifyResults, zone: SpaceZone, root: SyncEnvelope?,
                            sentAt: Date) async throws -> (progressed: Bool, stop: Bool) {
        var progressed = false
        let lost = changes.filter { change in
            let code = results.error(for: CloudRecordID(change.recordName, in: zone.zoneID))?.code
            return code == .zoneNotFound || code == .userDeletedZone || (code == .unknownItem && change.action != .delete)
        }
        if !lost.isEmpty { try await refreshMoveMapsFromServer() }
        if lost.contains(where: { results.error(for: CloudRecordID($0.recordName, in: zone.zoneID))?.code != .unknownItem }) {
            try await spaceGone(zone, reason: "deleted")
            _ = try await settleGone(lost, zone: zone)
            return (true, true)
        }
        for change in changes {
            let id = CloudRecordID(change.recordName, in: zone.zoneID)
            switch (change.action, results.saved[id], results.deleted[id]) {
            case (.save, .success(let record)?, _):
                let acknowledged = ReplicaRecord(record, zoneKey: change.zoneKey, wireID: change.wireID, seenPass: sentAt.timeIntervalSinceReferenceDate)
                let deviceID = deviceID
                try await store.perform { state in
                    try state.acknowledgeSave(change, serverRecord: acknowledged)
                    if let serverTime = record.modificationDate { try state.replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID) }
                }
                conflictRounds[change.zoneKey + change.recordName] = nil
                refusals[change.zoneKey + change.recordName] = nil
                progressed = true
            case (.delete, _, .success?):
                let now = clock()
                try await store.perform { try $0.acknowledgeDelete(change, now: now) }
                progressed = true
            case (.delete, _, .failure(let error)?) where error.code == .unknownItem:
                let now = clock()
                try await store.perform { try $0.acknowledgeDelete(change, now: now) }
                progressed = true
            case (_, .failure(let error)?, _), (_, _, .failure(let error)?):
                switch error.code {
                case .serverRecordChanged:
                    if let server = error.serverRecord { progressed = try await resolveConflict(change, server: server) || progressed }
                case .unknownItem:
                    try await lostRecord(change, zone: zone)
                    progressed = true
                case .permissionFailure:
                    // CloudKit says this member may only read: refused from now on, here too.
                    try await store.perform { state in
                        guard var row = try state.replica.zone(key: zone.zoneKey) else { return }
                        row.permission = CloudShare.Permission.readOnly.rawValue
                        try state.replica.upsertZone(row)
                    }
                    let held = try await store.perform { try $0.replica.record(zoneKey: change.zoneKey, recordName: change.recordName) }
                    try await refuse(change, held: held, now: clock())
                    progressed = true
                case .quotaExceeded, .requestRateLimited, .zoneBusy, .serviceUnavailable:
                    await refused(error, zone: zone, root: root)
                    try await release([change])
                    return (progressed, true)
                default:
                    Self.logger.error("A space record was not saved: \(error.description, privacy: .public)")
                    // A record the server turns away for good is parked after `refusalsMax` tries, so it never
                    // stands at the head of the zone's changes for ever (M6); until then it counts as progress,
                    // so the pass goes on to try it again.
                    let key = change.zoneKey + change.recordName
                    let count = (refusals[key] ?? 0) + 1
                    if PrivateSyncEngine.countsAsRefusal(error), count >= configuration.refusalsMax {
                        refusals[key] = nil
                        let now = clock()
                        try await store.perform { state in
                            try PrivateSyncEngine.park(change, reason: PrivateSyncEngine.rejectedReason, in: state, now: now)
                            try state.release(change)
                        }
                        progressed = true
                        Self.logger.error("A space record was parked after \(count) refusals")
                    } else {
                        if PrivateSyncEngine.countsAsRefusal(error) {
                            refusals[key] = count
                            progressed = true
                        }
                        try await release([change])
                    }
                }
            default:
                try await release([change])
            }
        }
        return (progressed, false)
    }

    /// The server's record merged with the record's current local state; the projection takes the
    /// merge, and local winners go out again on the server's change tag (§6.2), parked after 5 rounds.
    private func resolveConflict(_ change: OutboxChange, server: CloudRecord) async throws -> Bool {
        let now = clock()
        let moveMaps = moveMaps
        let localWon = try await store.perform { state -> Bool in
            try state.replica.apply { _ in
                try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps).absorb(server, zoneKey: change.zoneKey)
            }
        }
        let key = change.zoneKey + change.recordName
        guard localWon else {
            conflictRounds[key] = nil
            try await release([change])
            return true
        }
        let rounds = (conflictRounds[key] ?? 0) + 1
        let parks = rounds >= configuration.conflictRoundsMax
        conflictRounds[key] = parks ? nil : rounds
        try await store.perform { state in
            if parks { try PrivateSyncEngine.quarantine(change, server: server, in: state, now: now) }
            try state.release(change)
        }
        if parks { Self.logger.error("A space record was parked after \(rounds) lost rounds") }
        return true
    }

    /// `unknownItem` on a save: a record a move took elsewhere goes to its copy; anything else follows
    /// the private engine's rule (a deterministic record seen in the last complete pass is created
    /// again, else the delete wins, §6.2).
    private func lostRecord(_ change: OutboxChange, zone: SpaceZone) async throws {
        if let destination = moveMaps.retarget(type: change.recordType.rawValue, id: change.wireID, from: zone.zoneID.zoneName) {
            _ = try await retarget(change, to: destination)
            return
        }
        let now = clock()
        let moveMaps = moveMaps
        try await store.perform { state in
            try state.replica.apply { _ in
                _ = try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps).serverLost(
                    zoneKey: change.zoneKey, recordName: change.recordName, type: change.recordType, wireID: change.wireID, localChangePending: true
                )
            }
            try state.release(change)
        }
    }

    /// The changes of a space that went: each record a move took elsewhere has its pending write sent
    /// to the copy; the rest wait, rows and all, for the space packages (§9.6).
    private func settleGone(_ changes: [OutboxChange], zone: SpaceZone) async throws -> Bool {
        var progressed = false
        for change in changes {
            if let destination = moveMaps.retarget(type: change.recordType.rawValue, id: change.wireID, from: zone.zoneID.zoneName) {
                progressed = try await retarget(change, to: destination) || progressed
            } else {
                try await release([change])
            }
        }
        return progressed
    }

    /// Applies a pending write, with its stamps, to the record's copy in `destination` (§4.4, §6.2):
    /// the copy is the server side of a merge whose base is what this device last acknowledged in the
    /// old zone, so only the fields written since go over. Waits (rows kept) until the replica holds
    /// the copy. The old zone's replica row goes once the copy took the write.
    private func retarget(_ change: OutboxChange, to destination: String) async throws -> Bool {
        guard let target = SyncZoneName(destination) else { return false }
        let found = try await store.perform { state -> (copy: ReplicaRecord, base: SyncEnvelope?, zone: SpaceZone)? in
            let placement = ReplicaPlacement(connection: state.connection)
            guard let key = try placement.zoneKey(of: target), let row = try state.replica.zone(key: key),
                  let copy = try state.replica.record(zoneKey: key, recordType: change.recordType.rawValue, wireID: change.wireID)
            else { return nil }
            let zone = target.isSpace ? SpaceZone(row) : SpaceZone(CloudZoneID(target.name), in: .private)
            let base = try state.replica.record(zoneKey: change.zoneKey, recordName: change.recordName)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            return zone.map { (copy, base, $0) }
        }
        guard let found else {
            try await release([change])
            return false
        }
        let copyID = CloudRecordID(found.copy.recordName, in: found.zone.zoneID)
        var results: CloudModifyResults
        var copy = found.copy
        // The copy may have moved on since this device last fetched it (the move back revived it): the
        // write is merged again onto the version the server answers with, a few times.
        var rounds = 0
        while true {
            switch change.action {
            case .delete:
                results = try await transport.modifyRecords(deleting: [copyID], in: found.zone.database)
            case .save(let local):
                let server = try SyncEnvelope(storedPayload: copy.payload)
                let outcome = FieldMerge.merge(server: server, local: local, base: found.base, mintedAgainst: change.mintedAgainst)
                guard !outcome.takenFromLocal.isEmpty else {
                    try await forgetMoved(change)
                    return true
                }
                let record = CloudRecord(id: copyID, recordType: change.recordType.rawValue,
                                         encryptedFields: [CloudRecord.payloadKey: .bytes(try outcome.merged.storedPayload())],
                                         systemFields: copy.systemFields)
                results = try await transport.modifyRecords(saving: [record], in: found.zone.database)
            }
            rounds += 1
            guard rounds < 3, results.savedRecord(copyID) == nil, let error = results.error(for: copyID), error.code == .serverRecordChanged,
                  let server = error.serverRecord, server.payload != nil
            else { break }
            copy = ReplicaRecord(server, zoneKey: found.copy.zoneKey, wireID: change.wireID, seenPass: found.copy.seenPass)
        }
        if let saved = results.savedRecord(copyID) {
            let row = ReplicaRecord(saved, zoneKey: found.copy.zoneKey, wireID: change.wireID, seenPass: clock().timeIntervalSinceReferenceDate)
            try await store.perform { try $0.replica.upsertRecord(row) }
        } else if case .success? = results.deleted[copyID] {
            let copyKey = found.copy.zoneKey
            try await store.perform { try $0.replica.deleteRecord(zoneKey: copyKey, recordName: copyID.recordName) }
        } else {
            // The copy moved on meanwhile: the next pass merges again with what it then holds.
            try await release([change])
            return false
        }
        try await forgetMoved(change)
        Self.logger.info("A pending write went to the copy of a moved record")
        return true
    }

    /// The write reached the copy: the change's rows go, and so does the old zone's replica row.
    private func forgetMoved(_ change: OutboxChange) async throws {
        try await store.perform { state in
            try state.discard(change)
            try state.replica.deleteRecord(zoneKey: change.zoneKey, recordName: change.recordName)
        }
    }

    // MARK: - Pacing

    /// One read through the `.spaces` stream of `database`'s pacer, which waits for its turn.
    private func request<T: Sendable>(_ database: CloudDatabaseScope, writes: Bool, _ body: @Sendable () async throws -> T) async throws -> T {
        let pacer = await pacer(database)
        _ = try await pacer.acquire(.spaces, writes: writes)
        do {
            let result = try await body()
            await pacer.succeeded(.spaces)
            return result
        } catch let error as CloudError {
            await pacer.refused(.spaces, with: error)
            throw error
        }
    }
}

extension SyncPacerState.Decision {
    var isGo: Bool {
        if case .go = self { return true }
        return false
    }
}

extension OutboxChange {
    /// The same change with another action (a save with refused fields left out).
    func with(action: Action) -> OutboxChange {
        OutboxChange(zoneKey: zoneKey, zone: zone, recordType: recordType, wireID: wireID, recordName: recordName,
                     systemFields: systemFields, action: action, priority: priority, stamps: stamps, mintedAgainst: mintedAgainst, rows: rows)
    }
}
