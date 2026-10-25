import CloudKit
import Foundation
import OSLog

// MARK: - The local half

/// Where the private engine's local state lives (docs/cloudkit-schema-design.md §6.6): the replica,
/// and on the Mac the outbox and the projections, all on one connection with one owner (on the Mac
/// the storage actor, which owns `KnowledgeStore`). The engine reaches it only through `perform`, so
/// nothing else writes on the connection while a body runs, and an apply never spans an await.
protocol PrivateSyncLocalStore: AnyObject, Sendable {
    /// Runs `body` on the store's connection, where the connection belongs.
    func perform<T>(_ body: @escaping (PrivateSyncLocalState) throws -> T) async throws -> T
}

/// What the engine reads and writes inside `perform` (§6.6 steps 2 to 6).
protocol PrivateSyncLocalState: AnyObject {
    var connection: SQLiteConnection { get }
    /// The changes due at `now` in `scope`'s zones, at most `limit`, coalesced and stamped
    /// (`OutboxFeeder.nextBatch`).
    func nextChanges(now: Date, limit: Int, scope: OutboxScope) throws -> [OutboxChange]
    /// Every record with a local change, due or not, encoded at `now` and handed to no one: what an
    /// inbound record is merged with. Runs inside an apply.
    func pendingChanges(now: Date) throws -> [OutboxChange]
    func acknowledgeSave(_ change: OutboxChange, serverRecord: ReplicaRecord) throws
    func acknowledgeDelete(_ change: OutboxChange, now: Date) throws
    func release(_ change: OutboxChange) throws
    /// Drops a change that will never be sent, rows and all (a write SpaceSync refused, §9.2).
    func discard(_ change: OutboxChange) throws
    /// Writes a record into the local rows, or lists what it waits for. Runs inside an apply.
    func project(_ record: ReplicaRecord) throws
    /// `project` for a record a fetch brought (`InboundApply.absorb`). `serverVersionIsNew` is false when
    /// the replica already held that version byte for byte and had projected it (this device's own save
    /// coming back): the rows hold it already, so nothing a screen shows changed.
    func project(_ record: ReplicaRecord, serverVersionIsNew: Bool) throws
    /// Removes the local rows of a record the server no longer has. Runs inside an apply.
    func projectDeletion(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String) throws
    /// Notebooks again the records whose parents arrived, in an apply of its own (before each feeder pass).
    func drainReady() throws
    /// Writes a record the merge made for a first write this device lost (`onServerFirstLoss`, §6.2 step 2:
    /// a losing Keep's own card) into the local rows as a local change, so it is sent. Runs inside an apply.
    func recordLocalWrite(_ patch: RecordPatch) throws
    /// The compaction gate's last step (§3.2 rule 4), once a device back from a long absence has
    /// re-fetched every zone: drops pending set and map element edits older than `horizon` whose
    /// element the server no longer lists. Returns how many it dropped.
    func dropStaleElementEdits(before horizon: Date, now: Date) throws -> Int
    /// The record types this store has no projection for: held raw in the replica, and projected once a
    /// build that knows them runs (§6.5 rule 2).
    func unprojectableTypes() -> Set<SyncRecordType>
}

extension PrivateSyncLocalState {
    var replica: ReplicaStore { ReplicaStore(connection: connection) }

    /// A store that keeps nothing in memory projects every version alike.
    func project(_ record: ReplicaRecord, serverVersionIsNew: Bool) throws {
        try project(record)
    }

    /// A store with no domain tables has nowhere to write it; its writer (the iPhone's, WP19) does.
    func recordLocalWrite(_ patch: RecordPatch) throws {}

    func unprojectableTypes() -> Set<SyncRecordType> { [] }

    /// A store with no outbox holds its pending edits in `ck_patches` alone.
    func dropStaleElementEdits(before horizon: Date, now: Date) throws -> Int {
        try PendingPatch.dropStaleElements(before: horizon, in: connection, now: now)
    }
}

/// A local store that is the replica alone, with no domain tables and no outbox: the iPhone's shape
/// until its writer arrives (WP19), and what the engine's suites run the bootstrap, purge and audit
/// on. Acknowledgements write the replica; there is nothing to project.
final class ReplicaOnlySyncStore: PrivateSyncLocalStore, PrivateSyncLocalState, @unchecked Sendable {
    let connection: SQLiteConnection
    private let lock = NSRecursiveLock()

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func perform<T>(_ body: @escaping (PrivateSyncLocalState) throws -> T) async throws -> T {
        try lock.withLock { try body(self) }
    }

    func nextChanges(now: Date, limit: Int, scope: OutboxScope) throws -> [OutboxChange] { [] }
    func pendingChanges(now: Date) throws -> [OutboxChange] { [] }

    func acknowledgeSave(_ change: OutboxChange, serverRecord: ReplicaRecord) throws {
        try replica.upsertRecord(serverRecord)
    }

    func acknowledgeDelete(_ change: OutboxChange, now: Date) throws {
        try replica.deleteRecord(zoneKey: change.zoneKey, recordName: change.recordName)
    }

    func release(_ change: OutboxChange) throws {}
    func discard(_ change: OutboxChange) throws {}
    func project(_ record: ReplicaRecord) throws {}
    func projectDeletion(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String) throws {}
    func drainReady() throws {}
}

// MARK: - Device state kept with the replica

extension ReplicaStore {
    /// The record types the cutover seed holds back from the senders now (none outside a seed).
    func seedHeldTypes() throws -> Set<SyncRecordType> {
        guard let data = try engineState(EngineScope.seedHeldTypes), let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: ",").compactMap { SyncRecordType(rawValue: String($0)) })
    }

    /// `ck_engine_state` scopes the private engine keeps besides CKSyncEngine's own state.
    enum EngineScope {
        /// CKSyncEngine's serialized state for the private database.
        static let privateEngine = "private"
        /// Why sending to the private database stopped (§2.5), until the learner uploads again.
        static let privateStop = "private.stop"
        /// The account the replica belongs to (its user record name in the library container).
        static let account = "account"
        /// The container and environment ("<container>|<environment>") whose zones and salts the replica
        /// holds, written when a bootstrap adopts or creates a root there.
        static let containerBinding = "bootstrap.container"
        /// When this device created the private zones, before its root save was acknowledged.
        static let zonesCreated = "bootstrap.zonesCreated"
        /// When the replica audit last walked a zone (`audit.<zone key>`).
        static func audit(_ zoneKey: String) -> String { "audit.\(zoneKey)" }
        /// Set by the compaction gate (§3.2 rule 4) while a device away longer than the horizon
        /// re-fetches every zone: nothing is sent until the maintenance service clears it.
        static let refetchBeforeSend = "maintenance.refetchBeforeSend"
        /// Set by a Mac's sync session while the cutover keeps it from sending: another Mac's seed is not
        /// metadata complete, its catch-up has not run, or a question about the old world waits (§13.5).
        static let holdSendsForSeed = "seed.holdSends"
        /// The record types the cutover seed holds back from every sender until its pass begins, as a comma
        /// list of type names (§13.4 step 5).
        static let seedHeldTypes = "seed.heldTypes"
    }

    /// The device's stamp clock (`ck_clock`, §6.3); nil before it exists.
    func loadClock() throws -> StampClock? {
        guard let json = try connection.scalarText("SELECT clock_json FROM ck_clock WHERE id = 1") else { return nil }
        return try? JSONDecoder().decode(StampClock.self, from: Data(json.utf8))
    }

    /// Whether the device has no server offset yet: it cannot mint a stamp, so it sends nothing until one
    /// of its saves comes back with the server's date (§6.3). A bootstrap that lost both of its probes to a
    /// busy root leaves it so, and the round loop tries again (m4).
    func lacksServerOffset() throws -> Bool {
        try loadClock()?.serverOffset == nil
    }

    func saveClock(_ clock: StampClock, now: Date = Date()) throws {
        let json = String(decoding: try JSONEncoder().encode(clock), as: UTF8.self)
        try connection.execute("""
            INSERT INTO ck_clock (id, clock_json, updated_at) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET clock_json = excluded.clock_json, updated_at = excluded.updated_at
        """, [.text(json), .real(now.timeIntervalSinceReferenceDate)])
    }

    /// Records one server time (an acknowledged save's modification date) against the local time the
    /// request went out (§6.3), in the device's clock.
    func recordServerTime(_ serverTime: Date, sentAt: Date, deviceID: String) throws {
        var clock = try loadClock() ?? StampClock(deviceID: deviceID)
        clock.recordServerTime(SyncTime.milliseconds(serverTime), sentAt: SyncTime.milliseconds(sentAt))
        try saveClock(clock, now: sentAt)
    }

    func engineState(_ scope: String) throws -> Data? {
        var state: Data?
        try connection.query("SELECT state FROM ck_engine_state WHERE scope = ?", [.text(scope)]) { state = $0.blob(0) }
        return state
    }

    /// When one scope's state was last written; nil when it holds none.
    func engineStateUpdatedAt(_ scope: String) throws -> Date? {
        var written: Date?
        try connection.query("SELECT updated_at FROM ck_engine_state WHERE scope = ?", [.text(scope)]) {
            written = $0.real(0).map(Date.init(timeIntervalSinceReferenceDate:))
        }
        return written
    }

    /// Writes one scope's state, or removes it with nil.
    func setEngineState(_ scope: String, _ state: Data?, now: Date = Date()) throws {
        guard let state else {
            try connection.execute("DELETE FROM ck_engine_state WHERE scope = ?", [.text(scope)])
            return
        }
        try connection.execute("""
            INSERT INTO ck_engine_state (scope, state, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at
        """, [.text(scope), .blob(state), .real(now.timeIntervalSinceReferenceDate)])
    }

    /// The personal root this device holds (`Library`'s `root`), decoded; nil when it holds none.
    func personalRoot() throws -> (record: ReplicaRecord, envelope: SyncEnvelope)? {
        guard let record = try record(zoneKey: PrivateSyncZones.libraryKey, recordName: SyncSchema.rootRecordName),
              let envelope = try? SyncEnvelope(storedPayload: record.payload)
        else { return nil }
        return (record, envelope)
    }
}

/// The private zones the engine and the bootstrap name (§2.2).
enum PrivateSyncZones {
    static let library = CloudZoneID(SyncZone.library.rawValue)
    static let catalog = CloudZoneID(SyncZone.catalog.rawValue)
    static let content = CloudZoneID(SyncZone.content.rawValue)
    /// The engine's scope, `Library` first (§2.2 fetch priority); `Content` is never change-fetched.
    static let engineZones = [library, catalog]
    static let all = [library, catalog, content]

    static let libraryKey = ReplicaZone.key(database: .private, zoneName: SyncZone.library.rawValue)

    static func key(_ zone: CloudZoneID) -> String {
        ReplicaZone.key(database: .private, zoneName: zone.zoneName)
    }

    static func kind(_ zone: CloudZoneID) -> String {
        zone.zoneName.lowercased()
    }
}

// MARK: - The engine

/// The private engine's logic (docs/cloudkit-schema-design.md §2.3, §6.2, §6.4, §6.6): what goes out
/// to `Library` and `Catalog`, what a save's outcome does, and how an inbound record or deletion
/// meets the learner's own pending changes. In the app CKSyncEngine runs the operations and hands
/// its events here (`SyncCoordinator`); in tests, and wherever no engine runs, `sync()` drives the
/// same logic through a `CloudTransport` (FakeCloudKit in tests). Everything is gated on generation
/// 2 by its callers; nothing here runs under generation 1.
///
/// - Sends: at most 1,000 changes wait in the engine (fed from the outbox), and a request carries at
///   most 200 records and 800 KiB of payload, fewer when the pacer has halved the batch (D43, P11).
///   Nothing goes out before the device holds the root and a server offset (§2.4 step 4, §6.3), after
///   the private database stopped (§2.5), while the root asks for a newer client (§12.5), or while a
///   device back from a long absence re-fetches (§3.2 rule 4); fetches go on.
/// - `serverRecordChanged`: the server's record is merged with the record's current local state and
///   becomes the new base; the projection takes the merge, and the local winners go out again on the
///   server's change tag. After 5 rounds the local side won but could not land, the record is parked
///   in `ck_quarantine` until the next launch.
/// - `unknownItem`: a record `moveMaps` lists as moved goes to its copy; a record with a
///   deterministic name is created again when this replica's last complete pass saw it or it was
///   acknowledged since; otherwise the delete wins and the local rows go (§6.2). An inbound deletion
///   follows the same rule when a local change is pending.
/// - Inbound: every server record is applied, never skipped; with a local change pending the
///   projection takes `merge(server, local, base)` and the replica the server's record (§6.2). A
///   record named with another salt is ignored (§2.4 step 6), a stale echo of an acknowledged delete
///   too (§6.4).
actor PrivateSyncEngine {
    struct Configuration: Sendable {
        var pendingMax = SyncSchema.Limits.enginePendingChangesMax
        var batchMaxRecords = SyncSchema.Limits.batchMaxRecords
        var batchMaxBytes = SyncSchema.Limits.batchMaxBytes
        var conflictRoundsMax = 5
        /// Refusals of one record (an invalid record, a constraint, a limit) after which it is parked and the
        /// rest go on: a record the server turns away for good must not stand at the head of every batch (M6).
        var refusalsMax = 3
        /// What identifies this build to the upgrade pass (`reapplyAfterUpgrade`): a new one applies again what
        /// the last one could not take.
        var buildRevision = PrivateSyncEngine.currentBuild
        /// How often the replica audit walks a zone even without a token reset (§2.3).
        var auditInterval: TimeInterval = 7 * 86_400
        var fetchPageSize: Int? = nil
    }

    /// Records whose names are deterministic, created again on `unknownItem` when the last complete
    /// pass saw them (§6.2).
    static let recreatableTypes: Set<SyncRecordType> = [
        .entry, .readingState, .mark, .notebookState, .placement, .setting, .enrollment, .device, .activityLog,
    ]

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PrivateSyncEngine")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let pacer: SyncPacer
    nonisolated let moveMaps: MoveMapIndex
    let deviceID: String
    let configuration: Configuration
    private let clock: @Sendable () -> Date

    /// The changes waiting to go out, by record, and the order they came from the feeder in.
    private var pending: [CloudRecordID: OutboxChange] = [:]
    private var order: [CloudRecordID] = []
    /// Rounds a record's local winners lost the compare-and-set again.
    private var conflictRounds: [CloudRecordID: Int] = [:]
    /// Requests the server refused one record of for a reason no retry changes, in a row.
    private var refusals: [CloudRecordID: Int] = [:]
    /// Why the private database stopped, once it has (§2.5).
    private(set) var stopped: PurgeHandler.Event?
    private var started = false
    /// Which records CKSyncEngine delivered, and when (a serial), while a transport fetch is in flight: a page
    /// fetched before such a delivery must not take that record back to the older version it holds (m5).
    private var deliverySerial = 0
    private var delivered: [String: Int] = [:]
    private var fetchesInFlight = 0

    init(transport: CloudTransport, store: PrivateSyncLocalStore, pacer: SyncPacer, moveMaps: MoveMapIndex = MoveMapIndex(),
         deviceID: String, configuration: Configuration = Configuration(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.store = store
        self.pacer = pacer
        self.moveMaps = moveMaps
        self.deviceID = deviceID
        self.configuration = configuration
        self.clock = clock
    }

    var pendingCount: Int { pending.count }

    /// The build's name for the upgrade pass: the schema revision and the bundle version.
    static var currentBuild: String {
        "\(SyncSchema.schemaRevision).\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")"
    }

    /// Why sends are held while fetches go on (§12.5, §3.2 rule 4).
    enum SendHold: Equatable, Sendable {
        /// The personal root asks for a newer client than this build: "Update ForeverLM to keep syncing".
        case updateRequired(minClientRevision: Int)
        /// This device was away longer than the compaction horizon and re-fetches every zone first.
        case refetchBeforeSend
        /// A Mac that holds the library sends nothing until the seed's metadata is complete and its own
        /// catch-up has run (§13.4 step 1, §13.5, R8-m5); its edits wait in the outbox.
        case waitingForSeed
    }

    /// Set by the last feed; nil while sends may go out.
    private(set) var sendHold: SendHold?
    /// The engine's zones the last fetch did not take to the end (a failure, a throttle, a stop): the
    /// maintenance Mac's janitor and GC wait until none is left (§5.7, §5.8).
    private(set) var unfetchedZones: Set<CloudZoneID> = Set(PrivateSyncZones.engineZones)

    /// CKSyncEngine took these zones to their end (its fetch returned without a failure): what the
    /// transport loop's `fetchZone` does on its own path. In the app CKSyncEngine fetches the zones and
    /// only the coordinator knows when it finished, so without this the set never empties on a Mac that
    /// does not run maintenance, and a reconcile waits for ever on it (B2).
    func markFetched(_ zones: [CloudZoneID]) {
        unfetchedZones.subtract(zones)
    }

    /// A fetch of these zones started or failed: they are not caught up.
    func markUnfetched(_ zones: [CloudZoneID]) {
        unfetchedZones.formUnion(zones)
    }

    static func sendHold(in state: PrivateSyncLocalState) throws -> SendHold? {
        let replica = state.replica
        if let minimum = try replica.personalRoot()?.envelope.fields["minClientRevision"]?.intValue, minimum > SyncSchema.schemaRevision {
            return .updateRequired(minClientRevision: minimum)
        }
        if try replica.engineState(ReplicaStore.EngineScope.refetchBeforeSend) != nil { return .refetchBeforeSend }
        if try replica.engineState(ReplicaStore.EngineScope.holdSendsForSeed) != nil { return .waitingForSeed }
        return nil
    }

    /// The pacer's answer for one request of the engine's: nil to go, else when to ask again. A refused
    /// stream gives up its place in line at once, because nothing repeats the request on a timer: left
    /// waiting, it would hold SpaceSync and BlobStore behind it for ever (the pacer lets neither take a
    /// token while a small-record stream waits).
    func holdUntil(writes: Bool) async -> Date? {
        guard case .wait(let until, _) = await pacer.request(.engine, writes: writes) else { return nil }
        await pacer.withdraw(.engine)
        return until
    }

    /// Reads why the database stopped, if it did, and re-queues what a conflict, a refusal or an oversize
    /// payload parked (a launch re-queues it, §6.2). A delete handed out before a quit is forgotten: its
    /// acknowledgement can never come from this process, and while the row stays a record the learner
    /// brought back under the same name would wait for it for ever (M7).
    func start() async throws {
        guard !started else { return }
        started = true
        let now = clock()
        stopped = try await store.perform { state in
            try state.connection.execute(
                "DELETE FROM ck_quarantine WHERE reason IN (?, ?, ?)",
                [.text(Self.conflictReason), .text(Self.rejectedReason), .text(OutboxFeeder.payloadTooLargeReason)]
            )
            // An echo guard that ran out is of no use any more (nothing else removes one).
            try state.connection.execute("DELETE FROM ck_echo WHERE until <= ?", [.real(now.timeIntervalSinceReferenceDate)])
            let keys = PrivateSyncZones.all.map { PrivateSyncZones.key($0) }
            try state.connection.execute(
                "DELETE FROM ck_pending_deletes WHERE zone_key IN (\(keys.map { _ in "?" }.joined(separator: ", ")))", keys.map { .text($0) }
            )
            return try PurgeHandler.stopReason(in: state)
        }
    }

    // MARK: - After an upgrade (§6.5 rule 2)

    static let projectionBuildScope = "projection.build"
    static let unprojectableScope = "projection.unprojectable"

    /// Takes in what an older build could not: the records it parked raw (an envelope version it did not read,
    /// a projection that threw) are applied again, and the replica rows of a type it had no projection for are
    /// projected now that this build has one. CKSyncEngine's token has long moved past all of them, so nothing
    /// else would ever bring them back until each changed again (M8). Runs once per build, after the
    /// bootstrap, and never while a zone's salt is not known. Returns how many records it handled.
    @discardableResult
    func reapplyAfterUpgrade() async throws -> Int {
        try await start()
        guard stopped == nil else { return 0 }
        let now = clock()
        let moveMaps = moveMaps
        let build = configuration.buildRevision
        return try await store.perform { state -> Int in
            let replica = state.replica
            let missing = state.unprojectableTypes()
            let missingText = missing.map(\.rawValue).sorted().joined(separator: ",")
            let lastBuild = try replica.engineState(Self.projectionBuildScope).flatMap { String(data: $0, encoding: .utf8) }
            let lastMissing = try replica.engineState(Self.unprojectableScope).flatMap { String(data: $0, encoding: .utf8) }
            guard lastBuild != build || lastMissing != missingText else { return 0 }
            var handled = 0
            let keys = PrivateSyncZones.all.map { PrivateSyncZones.key($0) }
            try replica.apply { _ in
                let inbound = try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps)
                var parked: [(zoneKey: String, name: String, type: String, systemFields: Data?, payload: Data)] = []
                try state.connection.query("""
                    SELECT zone_key, record_name, record_type, system_fields, payload FROM ck_quarantine
                    WHERE reason IN (?, ?) AND payload IS NOT NULL AND zone_key IN (\(keys.map { _ in "?" }.joined(separator: ", ")))
                """, [.text("unreadable"), .text(InboundApply.projectionFailedReason)] + keys.map { .text($0) }) { row in
                    parked.append((row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "", row.blob(3), row.blob(4) ?? Data()))
                }
                for item in parked {
                    guard let zone = try replica.zone(key: item.zoneKey), zone.saltID != nil else { continue }
                    try state.connection.execute(
                        "DELETE FROM ck_quarantine WHERE zone_key = ? AND record_name = ?", [.text(item.zoneKey), .text(item.name)]
                    )
                    let record = CloudRecord(id: CloudRecordID(item.name, in: CloudZoneID(zone.zoneName)), recordType: item.type,
                                             encryptedFields: [CloudRecord.payloadKey: .bytes(item.payload)], systemFields: item.systemFields)
                    _ = try inbound.absorbIsolated(record, zoneKey: item.zoneKey)
                    handled += 1
                }
                // Types a build now notebooks that the last one only held.
                if let lastMissing {
                    let newly = Set(lastMissing.split(separator: ",").compactMap { SyncRecordType(rawValue: String($0)) }).subtracting(missing)
                    for type in newly.sorted(by: { $0.rawValue < $1.rawValue }) {
                        var names: [(zoneKey: String, name: String)] = []
                        try state.connection.query("SELECT zone_key, record_name FROM ck_records WHERE record_type = ?", [.text(type.rawValue)]) { row in
                            names.append((row.text(0) ?? "", row.text(1) ?? ""))
                        }
                        for item in names where keys.contains(item.zoneKey) {
                            guard let record = try replica.record(zoneKey: item.zoneKey, recordName: item.name) else { continue }
                            try state.connection.executeScript("SAVEPOINT ck_reproject_type")
                            do {
                                try state.project(record)
                                try state.connection.executeScript("RELEASE ck_reproject_type")
                            } catch {
                                try state.connection.executeScript("ROLLBACK TO ck_reproject_type")
                                try state.connection.executeScript("RELEASE ck_reproject_type")
                                Self.logger.error("\(type.rawValue, privacy: .public) could not be projected: \(String(describing: error), privacy: .public)")
                            }
                            handled += 1
                        }
                    }
                }
            }
            try replica.setEngineState(Self.projectionBuildScope, Data(build.utf8), now: now)
            try replica.setEngineState(Self.unprojectableScope, Data(missingText.utf8), now: now)
            return handled
        }
    }

    // MARK: - Driving it through a transport

    /// One round: the database's zone changes, both zones' record changes, then what is pending.
    /// CKSyncEngine does the same in the app.
    func sync() async throws {
        try await fetchDatabaseChanges()
        try await fetchChanges()
        try await sendChanges()
    }

    // MARK: - Sending

    /// Takes due changes from the outbox until 1,000 wait in the engine. A change of a record already
    /// waiting replaces it (it carries the newer encode). Space records are SpaceSync's.
    @discardableResult
    func feed() async throws -> Int {
        try await start()
        guard stopped == nil else { return 0 }
        let now = clock()
        let limit = configuration.pendingMax
        let (changes, hold) = try await store.perform { state -> ([OutboxChange], SendHold?) in
            try state.drainReady()
            if let hold = try Self.sendHold(in: state) { return ([], hold) }
            // The batch first: encoding frees a parked oversize record that has shrunk.
            let due = try state.nextChanges(now: now, limit: limit, scope: .privateZones)
            var parked = Set<String>()
            try state.connection.query("SELECT zone_key || char(31) || record_name FROM ck_quarantine", []) { parked.insert($0.text(0) ?? "") }
            return (due.filter { !parked.contains($0.zoneKey + "\u{1F}" + $0.recordName) }, nil)
        }
        sendHold = hold
        // Held: nothing goes out, and what waited is handed back to the outbox, where it stays.
        guard hold == nil else {
            pending = [:]
            order = []
            return 0
        }
        for change in changes where !change.zone.isSpace {
            // A record a move took out of this zone goes to its copy, never back here (§4.4): the
            // feeder places it there once the replica holds the copy.
            if moveMaps.retarget(type: change.recordType.rawValue, id: change.wireID, from: change.zone.name) != nil { continue }
            let id = Self.recordID(change)
            if pending[id] == nil {
                guard pending.count < limit else { continue }
                order.append(id)
            }
            pending[id] = change
        }
        return pending.count
    }

    /// The next request's records: in feeder order, at most `limit` and 800 KiB of payload (always at
    /// least one record).
    func nextBatch(limit: Int) throws -> (saves: [CloudRecord], deletes: [CloudRecordID], changes: [CloudRecordID: OutboxChange]) {
        var saves: [CloudRecord] = []
        var deletes: [CloudRecordID] = []
        var changes: [CloudRecordID: OutboxChange] = [:]
        var bytes = 0
        filling: for id in order {
            guard let change = pending[id] else { continue }
            guard changes.count < min(limit, configuration.batchMaxRecords) else { break }
            switch change.action {
            case .save(let envelope):
                let payload = try envelope.storedPayload()
                if !changes.isEmpty, bytes + payload.count > configuration.batchMaxBytes { break filling }
                bytes += payload.count
                saves.append(CloudRecord(id: id, recordType: change.recordType.rawValue,
                                         encryptedFields: [CloudRecord.payloadKey: .bytes(payload)], systemFields: change.systemFields))
            case .delete:
                deletes.append(id)
            }
            changes[id] = change
            if bytes >= configuration.batchMaxBytes { break }
        }
        return (saves, deletes, changes)
    }

    /// Sends what is pending, batch by batch, until nothing is left, a batch makes no progress, the
    /// pacer holds the engine, or the database stops.
    func sendChanges() async throws {
        try await feed()
        var rounds = 0
        while stopped == nil, !pending.isEmpty, rounds < configuration.pendingMax {
            rounds += 1
            if await holdUntil(writes: true) != nil { return }
            let batch = try nextBatch(limit: await pacer.batchSize(.engine))
            guard !batch.changes.isEmpty else { return }
            let sentAt = clock()
            let results: CloudModifyResults
            do {
                results = try await transport.modifyRecords(saving: batch.saves, deleting: batch.deletes, in: .private)
            } catch let error as CloudError {
                await pacer.refused(.engine, with: error)
                Self.logger.error("A send failed: \(error.description, privacy: .public)")
                return
            }
            await pacer.succeeded(.engine)
            let progressed = try await handleSent(batch.changes, results: results, sentAt: sentAt)
            if !progressed { return }
            try await feed()
        }
    }

    /// What a request's results do (CKSyncEngine's `sentRecordZoneChanges` in the app). Returns
    /// whether anything was settled.
    @discardableResult
    func handleSent(_ changes: [CloudRecordID: OutboxChange], results: CloudModifyResults, sentAt: Date) async throws -> Bool {
        var progressed = false
        // A record the server no longer has may have been moved: the lookup reads the root as the
        // server holds it now, before any `unknownItem` is decided (§6.2).
        if changes.keys.contains(where: { results.error(for: $0)?.code == .unknownItem && changes[$0]?.action != .delete }) {
            try await refreshMoveMapsFromServer()
        }
        for (id, change) in changes.sorted(by: { $0.key.recordName < $1.key.recordName }) {
            guard stopped == nil else { return progressed }
            let outcome: Result<CloudRecord?, CloudError>
            switch change.action {
            case .save:
                switch results.saved[id] {
                case .success(let record)?: outcome = .success(record)
                case .failure(let error)?: outcome = .failure(error)
                case nil: continue
                }
            case .delete:
                switch results.deleted[id] {
                case .success?: outcome = .success(nil)
                case .failure(let error)? where error.code == .unknownItem: outcome = .success(nil)
                case .failure(let error)?: outcome = .failure(error)
                case nil: continue
                }
            }
            switch outcome {
            case .success(let record?):
                try await acknowledge(change, record: record, sentAt: sentAt)
                progressed = true
            case .success(nil):
                let now = clock()
                try await store.perform { try $0.acknowledgeDelete(change, now: now) }
                drop(id)
                conflictRounds[id] = nil
                progressed = true
            case .failure(let error):
                progressed = try await handleFailure(error, id: id, change: change) || progressed
            }
        }
        return progressed
    }

    private func acknowledge(_ change: OutboxChange, record: CloudRecord, sentAt: Date) async throws {
        let deviceID = deviceID
        let acknowledged = ReplicaRecord(record, zoneKey: change.zoneKey, wireID: change.wireID, seenPass: sentAt.timeIntervalSinceReferenceDate)
        try await store.perform { state in
            try state.acknowledgeSave(change, serverRecord: acknowledged)
            if let serverTime = record.modificationDate {
                try state.replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID)
            }
        }
        drop(Self.recordID(change))
        // A save that landed ends the record's run of lost rounds: only conflicts one after the other, with
        // nothing landing between, park it (M3).
        conflictRounds[Self.recordID(change)] = nil
        refusals[Self.recordID(change)] = nil
    }

    private func handleFailure(_ error: CloudError, id: CloudRecordID, change: OutboxChange) async throws -> Bool {
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else { return false }
            return try await resolveConflict(change, server: server)
        case .unknownItem:
            try await resolveUnknownItem(change)
            return true
        case .zoneNotFound:
            try await stop(.rootMissing)
            return true
        case .userDeletedZone:
            try await stop(.zoneDeleted(reason: .purged))
            return true
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .quotaExceeded:
            await pacer.refused(.engine, with: error)
            return false
        default:
            return try await refused(error, id: id, change: change)
        }
    }

    /// `ck_quarantine.reason` of a record the server refused for good (§3.2 rule 1); a launch tries it again.
    static let rejectedReason = "rejected"

    /// Failures a later request may well not meet again: they never count against a record.
    private static let transientCodes: Set<CKError.Code> = [
        .batchRequestFailed, .networkFailure, .networkUnavailable, .serverResponseLost, .notAuthenticated, .operationCancelled,
        .internalError, .changeTokenExpired,
    ]

    /// Whether a per-record failure is one the server will repeat: it counts against the record.
    static func countsAsRefusal(_ error: CloudError) -> Bool { !transientCodes.contains(error.code) }

    /// One refusal of a record. It goes to the back of the line, so one that fails every time cannot starve
    /// the others; after `refusalsMax` it is parked, its outbox rows kept for the next launch (M6). Returns
    /// whether the line moved.
    private func refused(_ error: CloudError, id: CloudRecordID, change: OutboxChange) async throws -> Bool {
        Self.logger.error("\(change.recordType.rawValue, privacy: .public) was not saved: \(error.description, privacy: .public)")
        guard Self.countsAsRefusal(error) else { return false }
        let count = (refusals[id] ?? 0) + 1
        guard count >= configuration.refusalsMax else {
            refusals[id] = count
            order.removeAll { $0 == id }
            order.append(id)
            return true
        }
        let now = clock()
        try await store.perform { state in
            try Self.park(change, reason: Self.rejectedReason, in: state, now: now)
            try state.release(change)
        }
        drop(id)
        refusals[id] = nil
        Self.logger.error("\(change.recordType.rawValue, privacy: .public) parked after \(count) refusals")
        return true
    }

    /// Parks a local change the server will not take, with its own body (so the garbage collection still
    /// sees the satellites it names).
    static func park(_ change: OutboxChange, reason: String, in state: PrivateSyncLocalState, now: Date) throws {
        var body: Data?
        if case .save(let local) = change.action { body = (try? local.storedPayload()) ?? local.json.serialized() }
        try state.connection.execute("""
            INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, system_fields, payload, quarantined_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET reason = excluded.reason, system_fields = excluded.system_fields,
                payload = excluded.payload, quarantined_at = excluded.quarantined_at
        """, [
            .text(change.zoneKey), .text(change.recordName), .text(change.recordType.rawValue), .text(reason),
            .blob(change.systemFields), .blob(body), .real(now.timeIntervalSinceReferenceDate),
        ])
    }

    // MARK: - serverRecordChanged (§6.2)

    static let conflictReason = "conflict"

    /// The server's record becomes the base and is merged with the record's current local state; the
    /// projection takes the merge. When a local field won, it goes out again on the server's tag.
    private func resolveConflict(_ change: OutboxChange, server: CloudRecord) async throws -> Bool {
        let id = Self.recordID(change)
        let now = clock()
        let moveMaps = moveMaps
        let localWon = try await store.perform { state -> Bool in
            try state.replica.apply { _ in
                try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps).absorb(server, zoneKey: change.zoneKey)
            }
        }
        drop(id)
        guard localWon else {
            conflictRounds[id] = nil
            return true
        }
        let rounds = (conflictRounds[id] ?? 0) + 1
        conflictRounds[id] = rounds
        if rounds >= configuration.conflictRoundsMax {
            conflictRounds[id] = nil
            try await store.perform { state in
                try Self.quarantine(change, server: server, in: state, now: now)
                try state.release(change)
            }
            Self.logger.error("\(change.recordType.rawValue, privacy: .public) parked after \(rounds) lost rounds")
        }
        return true
    }

    /// Parks a record whose local side won and could not land, with both bodies (§6.2).
    static func quarantine(_ change: OutboxChange, server: CloudRecord, in state: PrivateSyncLocalState, now: Date) throws {
        var bodies: [String: SyncJSON] = [:]
        if let payload = server.payload { bodies["server"] = .string(payload.base64EncodedString()) }
        if case .save(let local) = change.action {
            bodies["local"] = .string(((try? local.storedPayload()) ?? local.json.serialized()).base64EncodedString())
        }
        try state.connection.execute("""
            INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, system_fields, payload, quarantined_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET reason = excluded.reason, system_fields = excluded.system_fields,
                payload = excluded.payload, quarantined_at = excluded.quarantined_at
        """, [
            .text(change.zoneKey), .text(change.recordName), .text(change.recordType.rawValue), .text(conflictReason),
            .blob(server.systemFields), .blob(SyncJSON.object(bodies).serialized()), .real(now.timeIntervalSinceReferenceDate),
        ])
    }

    // MARK: - unknownItem (§6.2)

    private func resolveUnknownItem(_ change: OutboxChange) async throws {
        let now = clock()
        let moveMaps = moveMaps
        try await store.perform { state in
            try state.replica.apply { _ in
                let applied = try InboundApply(state: state, now: now, passStart: nil, moveMaps: moveMaps)
                _ = try applied.serverLost(zoneKey: change.zoneKey, recordName: change.recordName, type: change.recordType,
                                           wireID: change.wireID, localChangePending: true)
            }
            try state.release(change)
        }
        drop(Self.recordID(change))
    }

    // MARK: - Fetching

    /// Fetches `Library`, then `Catalog`, page by page, applying each page in one transaction. A zone
    /// gone is a purge; an expired token starts the zone over from nil, and the replica audit follows
    /// that pass (§2.3).
    func fetchChanges() async throws {
        try await start()
        guard stopped == nil else { return }
        try await refreshMoveMaps()
        for zone in PrivateSyncZones.engineZones {
            guard stopped == nil else { return }
            let walkedFromNil = try await fetchZone(zone)
            guard stopped == nil else { return }
            // After a pass from nil (an expired token, a first pass) and once a week, the audit sweeps
            // the deletions such a pass never returns (§2.3).
            let now = clock()
            let interval = configuration.auditInterval
            let due = try await store.perform { try ReplicaAudit.isDue(zone, in: $0, now: now, interval: interval) }
            if walkedFromNil || due {
                try await audit(zone)
            }
        }
    }

    /// Reads the moves the personal root lists (D51) before anything is written or applied.
    func refreshMoveMaps() async throws {
        guard let (root, salt) = try await store.perform({ state -> (SyncEnvelope, Data)? in
            guard let root = try state.replica.personalRoot()?.envelope,
                  let salt = root.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
            else { return nil }
            return (root, salt)
        }) else { return }
        await moveMaps.refresh(from: root, fetch: MoveMapIndex.transportFetch(transport, salt: salt))
    }

    /// Fetches one zone to its end. Returns whether the pass started from a nil token and completed.
    /// Reads the root as the server holds it now, and the moves it lists.
    func refreshMoveMapsFromServer() async throws {
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: PrivateSyncZones.library)
        guard case .success(let record) = try await transport.record(rootID, in: .private, desiredKeys: [CloudRecord.payloadKey]) else { return }
        try await refreshMoveMaps(fromRoot: record)
    }

    private func refreshMoveMaps(fromRoot record: CloudRecord) async throws {
        guard let payload = record.payload, let root = try? SyncEnvelope(storedPayload: payload),
              let salt = root.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        else { return }
        await moveMaps.refresh(from: root, fetch: MoveMapIndex.transportFetch(transport, salt: salt))
    }

    private func fetchZone(_ zone: CloudZoneID) async throws -> Bool {
        let zoneKey = PrivateSyncZones.key(zone)
        var token = try await store.perform { try $0.replica.zone(key: zoneKey)?.changeToken }.map(CloudChangeToken.init(data:))
        var passStart = clock()
        var fromNil = token == nil
        var walked = false
        unfetchedZones.insert(zone)
        fetchesInFlight += 1
        defer {
            fetchesInFlight -= 1
            if fetchesInFlight == 0 { delivered = [:] }
        }
        while stopped == nil {
            if await holdUntil(writes: false) != nil { return false }
            let result: Result<CloudZoneChanges, CloudError>
            let requested = deliverySerial
            do {
                result = try await transport.zoneChanges(zone, in: .private, since: token, resultsLimit: configuration.fetchPageSize)
            } catch let error as CloudError {
                await pacer.refused(.engine, with: error)
                return false
            }
            await pacer.succeeded(.engine)
            switch result {
            case .failure(let error) where error.code == .changeTokenExpired:
                guard !walked else { return false }
                walked = true
                token = nil
                fromNil = true
                passStart = clock()
                try await store.perform { try $0.connection.execute("UPDATE ck_zones SET change_token = NULL WHERE zone_key = ?", [.text(zoneKey)]) }
                continue
            case .failure(let error) where error.code == .zoneNotFound:
                try await stop(.rootMissing)
                return false
            case .failure(let error) where error.code == .userDeletedZone:
                try await stop(.zoneDeleted(reason: .purged))
                return false
            case .failure(let error):
                Self.logger.error("Fetching \(zone.zoneName, privacy: .public) failed: \(error.description, privacy: .public)")
                return false
            case .success(var page):
                // What CKSyncEngine delivered since this page was asked for is newer than the page.
                page.modified.removeAll { (delivered[zoneKey + "\u{1F}" + $0.id.recordName] ?? 0) > requested }
                page.deleted.removeAll { (delivered[zoneKey + "\u{1F}" + $0.id.recordName] ?? 0) > requested }
                // Records the page could not hand over are fetched by name; while one still fails, the
                // zone keeps its old token (CloudZoneChanges.failed).
                var keepToken = false
                if !page.failed.isEmpty {
                    let refetched = try await transport.records(Array(page.failed.keys), in: .private, desiredKeys: nil)
                    for outcome in refetched.values {
                        switch outcome {
                        case .success(let record): page.modified.append(record)
                        case .failure(let error) where error.code == .unknownItem: break
                        case .failure: keepToken = true
                        }
                    }
                }
                // A root in the page may list moves its deletions are part of: read them first.
                if let root = page.modified.first(where: { $0.id.recordName == SyncSchema.rootRecordName }) {
                    try await refreshMoveMaps(fromRoot: root)
                }
                let complete = fromNil && !page.moreComing && !keepToken
                let event = try await absorb(page, zoneKey: zoneKey, passStart: passStart, storeToken: !keepToken, complete: complete)
                if let event {
                    try await stop(event)
                    return false
                }
                if !keepToken, !page.moreComing { unfetchedZones.remove(zone) }
                if keepToken || !page.moreComing { return complete }
                token = page.changeToken
            }
        }
        return false
    }

    /// Walks a zone's names and sweeps the replica rows the server no longer has (§2.3).
    func audit(_ zone: CloudZoneID) async throws {
        let audit = ReplicaAudit(transport: transport, store: store, moveMaps: moveMaps, clock: clock)
        try await audit.run(zone)
    }

    /// Applies one fetched page in one transaction. Returns a purge event when the page shows the
    /// library's root with another salt.
    func absorb(_ page: CloudZoneChanges, zoneKey: String, passStart: Date, storeToken: Bool = true, complete: Bool = false) async throws -> PurgeHandler.Event? {
        let now = clock()
        let moveMaps = moveMaps
        return try await store.perform { state -> PurgeHandler.Event? in
            try state.replica.apply { replica -> PurgeHandler.Event? in
                let applied = try InboundApply(state: state, now: now, passStart: passStart, moveMaps: moveMaps)
                for record in page.modified {
                    if let event = try applied.absorbIsolated(record, zoneKey: zoneKey) { return event }
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

    /// Records CKSyncEngine fetched for one zone (its `fetchedRecordZoneChanges`): applied like a
    /// page, the engine keeping the token itself. A root among them lists moves its deletions belong
    /// to, so they are read first.
    func absorbFetched(_ modified: [CloudRecord], deleted: [CloudRecordDeletion], in zone: CloudZoneID, passStart: Date) async throws {
        try await start()
        guard stopped == nil, PrivateSyncZones.engineZones.contains(zone) else { return }
        if let root = modified.first(where: { $0.id.recordName == SyncSchema.rootRecordName }) {
            try await refreshMoveMaps(fromRoot: root)
        }
        let page = CloudZoneChanges(modified: modified, deleted: deleted, changeToken: CloudChangeToken(data: Data()), moreComing: false)
        if fetchesInFlight > 0 {
            deliverySerial += 1
            let zoneKey = PrivateSyncZones.key(zone)
            for record in modified { delivered[zoneKey + "\u{1F}" + record.id.recordName] = deliverySerial }
            for deletion in deleted { delivered[zoneKey + "\u{1F}" + deletion.id.recordName] = deliverySerial }
        }
        if let event = try await absorb(page, zoneKey: PrivateSyncZones.key(zone), passStart: passStart, storeToken: false) {
            try await stop(event)
        }
    }

    /// The record ids waiting to go out, in feeder order: what CKSyncEngine's state lists as pending.
    var pendingRecordIDs: [CloudRecordID] { order.filter { pending[$0] != nil } }

    /// Whether a waiting change is a delete.
    func isPendingDelete(_ id: CloudRecordID) -> Bool { pending[id]?.action == .delete }

    /// Reads the stop again after the learner acted (a sign-in after a sign-out, Upload again).
    func resume() async throws {
        stopped = try await store.perform { state in
            try PurgeHandler.resumeAfterSignIn(in: state)
            return try PurgeHandler.stopReason(in: state)
        }
    }

    // MARK: - Stopping

    /// The private database stops (§2.5): nothing pending goes out, and what described the server goes.
    func stop(_ event: PurgeHandler.Event) async throws {
        let now = clock()
        try await store.perform { try PurgeHandler.handle(event, in: $0, now: now) }
        stopped = event
        pending = [:]
        order = []
        conflictRounds = [:]
        refusals = [:]
    }

    /// A zone deletion the database feed reports (CKSyncEngine's `fetchedDatabaseChanges`).
    func handleZoneDeletion(_ deletion: CloudZoneDeletion) async throws {
        guard PrivateSyncZones.all.contains(deletion.zoneID) else { return }
        try await stop(.zoneDeleted(reason: deletion.reason))
    }

    /// Reads the private database's zone changes since the last time, and stops on a deletion of one
    /// of the private zones (§2.5). The token is kept in `ck_engine_state`.
    func fetchDatabaseChanges() async throws {
        try await start()
        guard stopped == nil else { return }
        let scope = "private.database"
        var token = try await store.perform { try $0.replica.engineState(scope) }.map(CloudChangeToken.init(data:))
        while true {
            let changes: CloudDatabaseChanges
            do {
                changes = try await transport.databaseChanges(in: .private, since: token, resultsLimit: nil)
            } catch let error as CloudError where error.code == .changeTokenExpired {
                token = nil
                continue
            }
            for deletion in changes.deletedZones {
                try await handleZoneDeletion(deletion)
                if stopped != nil { return }
            }
            let next = changes.changeToken.data
            try await store.perform { try $0.replica.setEngineState(scope, next) }
            guard changes.moreComing else { return }
            token = changes.changeToken
        }
    }

    // MARK: - Helpers

    private func drop(_ id: CloudRecordID) {
        pending[id] = nil
        order.removeAll { $0 == id }
    }

    static func recordID(_ change: OutboxChange) -> CloudRecordID {
        CloudRecordID(change.recordName, in: CloudZoneID(change.zone.name))
    }
}

extension ReplicaRecord {
    /// The server's copy of a record as the replica keeps it.
    init(_ record: CloudRecord, zoneKey: String, wireID: String, seenPass: Double?) {
        self.init(zoneKey: zoneKey, recordName: record.id.recordName, recordType: record.recordType, wireID: wireID,
                  systemFields: record.systemFields, payload: record.payload ?? Data(), seenPass: seenPass)
    }
}

// MARK: - Inbound

/// One inbound apply's logic (§6.2, §6.4), run inside `ReplicaStore.apply`: a server record meets the
/// local changes pending for it, a deletion meets them too.
struct InboundApply {
    let state: PrivateSyncLocalState
    let now: Date
    /// When the fetch pass started: what a delivered record's `seen_pass` is. Nil outside a fetch.
    let passStart: Date?
    let moveMaps: MoveMapIndex
    /// Every record's pending local change, by zone key and record name, encoded once per apply.
    private let pending: [String: OutboxChange]

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PrivateSyncEngine")
    /// `ck_quarantine.reason` of a record named with another salt than its zone's root (§2.4 step 6).
    static let foreignSaltReason = "foreignSalt"

    init(state: PrivateSyncLocalState, now: Date, passStart: Date?, moveMaps: MoveMapIndex) throws {
        self.state = state
        self.now = now
        self.passStart = passStart
        self.moveMaps = moveMaps
        // Read lazily would be cheaper for a page with no local change; one pass per page is bounded by
        // the outbox, which the feeder reads whole anyway.
        var pending: [String: OutboxChange] = [:]
        if try state.connection.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ck_outbox_fields'") == 1,
           try state.connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_outbox_fields) OR EXISTS(SELECT 1 FROM ck_outbox)") == 1 {
            for change in try state.pendingChanges(now: now) {
                pending[Self.key(change.zoneKey, change.recordName)] = change
            }
        }
        self.pending = pending
    }

    private static func key(_ zoneKey: String, _ recordName: String) -> String { zoneKey + "\u{1F}" + recordName }

    private var replica: ReplicaStore { state.replica }

    /// `ck_quarantine.reason` of a record whose projection threw: kept raw in the replica, projected again
    /// once something changes (M2, M8).
    static let projectionFailedReason = "projectionFailed"

    /// A fetched record, alone in a savepoint: one whose projection throws (a constraint, a parent row the
    /// projection did not expect) is undone, kept raw in the replica and parked, and the rest of the page
    /// goes on. Without it the whole page rolled back, and CKSyncEngine, which has moved its token past the
    /// page, never delivered the good records again (M2).
    func absorbIsolated(_ record: CloudRecord, zoneKey: String) throws -> PurgeHandler.Event? {
        try state.connection.executeScript("SAVEPOINT ck_inbound_record")
        do {
            let event = try absorbFetched(record, zoneKey: zoneKey)
            try state.connection.executeScript("RELEASE ck_inbound_record")
            return event
        } catch {
            try state.connection.executeScript("ROLLBACK TO ck_inbound_record")
            try state.connection.executeScript("RELEASE ck_inbound_record")
            Self.logger.error("\(record.recordType, privacy: .public) could not be applied: \(String(describing: error), privacy: .public)")
            guard let payload = record.payload, let envelope = try? SyncEnvelope(storedPayload: payload) else {
                try quarantine(record, zoneKey: zoneKey, reason: "unreadable")
                return nil
            }
            try replica.upsertRecord(ReplicaRecord(record, zoneKey: zoneKey, wireID: envelope.id,
                                                   seenPass: passStart?.timeIntervalSinceReferenceDate ?? now.timeIntervalSinceReferenceDate))
            try quarantine(record, zoneKey: zoneKey, reason: Self.projectionFailedReason)
            return nil
        }
    }

    /// A fetched record. Returns a purge event when it is the root and names another salt.
    func absorbFetched(_ record: CloudRecord, zoneKey: String) throws -> PurgeHandler.Event? {
        guard record.recordType != CloudRecordID.shareRecordType else { return nil }
        guard let payload = record.payload, let envelope = try? SyncEnvelope(storedPayload: payload) else {
            try quarantine(record, zoneKey: zoneKey, reason: record.payload == nil ? "noPayload" : "unreadable")
            return nil
        }
        let zoneSaltID = try replica.zone(key: zoneKey)?.saltID
        if record.id.recordName == SyncSchema.rootRecordName {
            if let zoneSaltID, envelope.fields["saltID"]?.stringValue != zoneSaltID { return .saltChanged }
            try replica.upsertRecord(ReplicaRecord(record, zoneKey: zoneKey, wireID: envelope.id, seenPass: passStart?.timeIntervalSinceReferenceDate))
            return nil
        }
        guard envelope.saltID == zoneSaltID else {
            // An old-salt sender after a re-bootstrap (§2.4 step 6): never applied. It is parked, raw,
            // so the maintenance Mac's janitor finds it by name and deletes it (§5.7).
            Self.logger.error("Ignored \(record.recordType, privacy: .public) named with another salt")
            try quarantine(record, zoneKey: zoneKey, reason: Self.foreignSaltReason)
            return nil
        }
        if try isStaleEcho(record, zoneKey: zoneKey) { return nil }
        _ = try absorb(record, zoneKey: zoneKey, envelope: envelope)
        return nil
    }

    /// Applies a server record against the record's pending local change. Returns whether a local
    /// field won (and so goes out again).
    @discardableResult
    func absorb(_ record: CloudRecord, zoneKey: String, envelope known: SyncEnvelope? = nil) throws -> Bool {
        guard let payload = record.payload, let server = known ?? (try? SyncEnvelope(storedPayload: payload)) else {
            try quarantine(record, zoneKey: zoneKey, reason: "unreadable")
            return false
        }
        let name = record.id.recordName
        try state.connection.execute(
            "DELETE FROM ck_quarantine WHERE zone_key = ? AND record_name = ? AND reason = ?",
            [.text(zoneKey), .text(name), .text(Self.projectionFailedReason)]
        )
        // A record whose projection failed before is held raw and was never projected.
        let wasParked = state.connection.changedRowCount > 0
        let held = try replica.record(zoneKey: zoneKey, recordName: name)
        let serverRow = ReplicaRecord(record, zoneKey: zoneKey, wireID: server.id,
                                      seenPass: passStart?.timeIntervalSinceReferenceDate ?? held?.seenPass ?? now.timeIntervalSinceReferenceDate)
        let serverVersionIsNew = wasParked || held?.payload != serverRow.payload
        let local = pending[Self.key(zoneKey, name)]
        let patch = try PendingPatch.load(zoneKey: zoneKey, type: server.type, wireID: server.id, in: state.connection)

        // A local delete waiting to go out stands: the replica takes the new version, the rows stay gone.
        if let local, local.action == .delete {
            try replica.upsertRecord(serverRow)
            return true
        }
        if try state.connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)", [.text(zoneKey), .text(name)]
        ) == 1 {
            try replica.upsertRecord(serverRow)
            return true
        }

        guard local != nil || patch != nil else {
            try replica.upsertRecord(serverRow)
            try state.project(serverRow, serverVersionIsNew: serverVersionIsNew)
            return false
        }
        let base = held.flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
        var localEnvelope: SyncEnvelope
        var mintedAgainst: [StampedPath: SyncStamp] = [:]
        if let local, case .save(let envelope) = local.action {
            localEnvelope = envelope
            mintedAgainst = local.mintedAgainst
        } else {
            localEnvelope = base ?? server
        }
        if let patch { localEnvelope = patch.applied(to: localEnvelope) }
        let outcome = FieldMerge.merge(server: server, local: localEnvelope, base: base, mintedAgainst: mintedAgainst)
        // A first write the local side lost, which the type keeps as a record of its own (§6.2 step 2): a
        // losing Keep with different wording becomes a card that `splitFrom` the server's.
        for loss in outcome.serverFirstLosses where loss.hook == "splitKeptCard" {
            if let patch = ServerFirstLossHooks.splitKeptCard(cardID: server.id, server: outcome.merged, lostKept: loss.local ?? .null) {
                try state.recordLocalWrite(patch)
            }
        }
        if !outcome.needsTextMerge.isEmpty {
            // The three-way body merge belongs to the Docs packages; until then the server's body stays.
            Self.logger.error("\(server.type, privacy: .public) needs a text merge of \(outcome.needsTextMerge.joined(separator: ","), privacy: .public); the server's body stays")
        }
        try replica.upsertRecord(serverRow)
        var projected = serverRow
        if !outcome.takenFromLocal.isEmpty { projected.payload = try outcome.merged.storedPayload() }
        try state.project(projected, serverVersionIsNew: serverVersionIsNew)
        if let patch { try patch.keeping(outcome.merged, takenFromLocal: Set(outcome.takenFromLocal), in: state.connection, now: now) }
        return !outcome.takenFromLocal.isEmpty
    }

    /// A fetched deletion. Without a pending local change the local rows go, unless a move took the
    /// record elsewhere (its rows are the copy's now); with one, the `unknownItem` rule decides.
    func absorbDeletion(_ deletion: CloudRecordDeletion, zoneKey: String) throws {
        guard let held = try replica.record(zoneKey: zoneKey, recordName: deletion.id.recordName) else {
            try state.connection.execute(
                "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(deletion.id.recordName)]
            )
            return
        }
        guard let type = SyncRecordType(rawValue: held.recordType) else {
            try replica.deleteRecord(zoneKey: zoneKey, recordName: held.recordName)
            return
        }
        let patch = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: held.wireID, in: state.connection)
        let localChangePending = pending[Self.key(zoneKey, held.recordName)] != nil || patch != nil
        _ = try serverLost(zoneKey: zoneKey, recordName: held.recordName, type: type, wireID: held.wireID,
                           localChangePending: localChangePending)
    }

    enum LostRecord: Equatable {
        /// A move took it elsewhere: the replica forgets this copy; the local rows are the copy's.
        case moved(to: String)
        /// A deterministic record the last complete pass saw: the next send creates it again.
        case recreated
        /// The delete wins: the local rows go.
        case deleted
    }

    /// The server no longer has a record (an inbound deletion, or `unknownItem` on a save): §6.2's rule.
    func serverLost(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String, localChangePending: Bool) throws -> LostRecord {
        defer {
            try? state.connection.execute(
                "DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(recordName)]
            )
        }
        if let zone = ProjectionZones.zone(ofKey: zoneKey), let destination = moveMaps.retarget(type: type.rawValue, id: wireID, from: zone.name) {
            try replica.deleteRecord(zoneKey: zoneKey, recordName: recordName)
            try forgetPinnedStamps(zoneKey: zoneKey, type: type, wireID: wireID)
            return .moved(to: destination)
        }
        if localChangePending, PrivateSyncEngine.recreatableTypes.contains(type), try sawInLastCompletePass(zoneKey: zoneKey, recordName: recordName) {
            try replica.deleteRecord(zoneKey: zoneKey, recordName: recordName)
            return .recreated
        }
        try state.projectDeletion(zoneKey: zoneKey, recordName: recordName, type: type, wireID: wireID)
        try replica.deleteRecord(zoneKey: zoneKey, recordName: recordName)
        try PendingPatch.delete(zoneKey: zoneKey, type: type.rawValue, wireID: wireID, in: state.connection)
        // The stamps pinned for edits that were on their way go with the record: a removal the learner makes
        // next would otherwise wait for pins no acknowledgement will ever settle (m10).
        try forgetPinnedStamps(zoneKey: zoneKey, type: type, wireID: wireID)
        return .deleted
    }

    /// The pins live in the Mac's `ck_outbox_fields`; the phone's store has no such table and pins nothing.
    private func forgetPinnedStamps(zoneKey: String, type: SyncRecordType, wireID: String) throws {
        guard try state.connection.scalarInteger("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ck_outbox_fields'") == 1 else { return }
        try state.connection.execute(
            "DELETE FROM ck_outbox_fields WHERE source_table = ? AND local_key = ?",
            [.text(OutboxFeeder.pinSource), .text(OutboxFeeder.pinKey(zoneKey: zoneKey, type: type, wireID: wireID))]
        )
    }

    /// Whether the zone's last complete pass delivered the record, or it was acknowledged since (D30).
    private func sawInLastCompletePass(zoneKey: String, recordName: String) throws -> Bool {
        guard let pass = try replica.zone(key: zoneKey)?.lastCompletePassAt,
              let seen = try replica.record(zoneKey: zoneKey, recordName: recordName)?.seenPass
        else { return false }
        return seen >= pass
    }

    /// A stale echo of a delete this device made and the server acknowledged (§6.4): a version from
    /// before that delete. A newer one (a deliberate re-create) is taken, and the echo forgotten.
    private func isStaleEcho(_ record: CloudRecord, zoneKey: String) throws -> Bool {
        var until: Double?
        try state.connection.query(
            "SELECT until FROM ck_echo WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(record.id.recordName)]
        ) { until = $0.real(0) }
        guard let until else { return false }
        let deletedAt = until - Double(SyncSchema.Limits.echoSuppressionDays) * 86_400
        if until > now.timeIntervalSinceReferenceDate, let modified = record.modificationDate?.timeIntervalSinceReferenceDate, modified <= deletedAt {
            return true
        }
        try state.connection.execute("DELETE FROM ck_echo WHERE zone_key = ? AND record_name = ?", [.text(zoneKey), .text(record.id.recordName)])
        return false
    }

    private func quarantine(_ record: CloudRecord, zoneKey: String, reason: String) throws {
        try state.connection.execute("""
            INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, system_fields, payload, quarantined_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name) DO UPDATE SET reason = excluded.reason, system_fields = excluded.system_fields,
                payload = excluded.payload, quarantined_at = excluded.quarantined_at
        """, [
            .text(zoneKey), .text(record.id.recordName), .text(record.recordType), .text(reason),
            .blob(record.systemFields), .blob(record.payload), .real(now.timeIntervalSinceReferenceDate),
        ])
    }
}

// MARK: - Patches with stamps of their own

/// A `ck_patches` row (§6.6): one record's pending field changes, each with its own stamp, as
/// `{"changes": {field: value | {element: value}}, "stamps": {field: stamp | {element: stamp}}}` (the
/// shape of the web outbox's `changes` and `stamps`). Every write on the iPhone; on the Mac only late
/// import's, the deferred catch-up's and listen positions read from iCloud Drive. An inbound version
/// merges with it like any pending change: fields the server won leave the patch.
struct PendingPatch: Equatable {
    var changes: [String: SyncJSON]
    var stamps: [String: SyncFieldStamp]
    let zoneKey: String
    let type: String
    let wireID: String

    static func load(zoneKey: String, type: String, wireID: String, in connection: SQLiteConnection) throws -> PendingPatch? {
        guard let text = try connection.scalarText(
            "SELECT patch_json FROM ck_patches WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(type), .text(wireID)]
        ), let json = try? SyncJSON(parsing: Data(text.utf8)),
           let changes = json["changes"]?.objectValue, let rawStamps = json["stamps"]?.objectValue
        else { return nil }
        var stamps: [String: SyncFieldStamp] = [:]
        for (field, raw) in rawStamps {
            switch raw {
            case .string(let text): if let stamp = SyncStamp(text) { stamps[field] = .value(stamp) }
            case .object(let elements): stamps[field] = .elements(elements.compactMapValues { $0.stringValue.flatMap(SyncStamp.init) })
            default: continue
            }
        }
        return PendingPatch(changes: changes, stamps: stamps, zoneKey: zoneKey, type: type, wireID: wireID)
    }

    static func delete(zoneKey: String, type: String, wireID: String, in connection: SQLiteConnection) throws {
        try connection.execute(
            "DELETE FROM ck_patches WHERE zone_key = ? AND record_type = ? AND wire_id = ?", [.text(zoneKey), .text(type), .text(wireID)]
        )
    }

    /// The compaction gate's step for patches (§3.2 rule 4): every set or map element a patch stamped
    /// before `horizon` whose element the record the replica holds no longer lists leaves the patch,
    /// and a patch left with nothing goes. Returns how many elements went.
    static func dropStaleElements(before horizon: Date, in connection: SQLiteConnection, now: Date) throws -> Int {
        let limit = SyncTime.milliseconds(horizon)
        var keys: [(zoneKey: String, type: String, wireID: String)] = []
        try connection.query("SELECT zone_key, record_type, wire_id FROM ck_patches", []) { row in
            keys.append((row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? ""))
        }
        let replica = ReplicaStore(connection: connection)
        var dropped = 0
        for key in keys {
            guard var patch = try load(zoneKey: key.zoneKey, type: key.type, wireID: key.wireID, in: connection) else { continue }
            let held = try replica.record(zoneKey: key.zoneKey, recordType: key.type, wireID: key.wireID)
                .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }
            var changed = false
            for (field, stamp) in patch.stamps {
                guard case .elements(var elements) = stamp, var values = patch.changes[field]?.objectValue else { continue }
                let listed = held?.fields[field]?.objectValue ?? [:]
                for (element, elementStamp) in elements where elementStamp.milliseconds < limit && listed[element] == nil {
                    elements[element] = nil
                    values[element] = nil
                    dropped += 1
                    changed = true
                }
                if elements.isEmpty {
                    patch.stamps[field] = nil
                    patch.changes[field] = nil
                } else {
                    patch.stamps[field] = .elements(elements)
                    patch.changes[field] = .object(values)
                }
            }
            guard changed else { continue }
            if patch.changes.isEmpty {
                try delete(zoneKey: key.zoneKey, type: key.type, wireID: key.wireID, in: connection)
            } else {
                try patch.save(in: connection, now: now)
            }
        }
        return dropped
    }

    var json: SyncJSON {
        .object([
            "changes": .object(changes),
            "stamps": .object(stamps.mapValues { stamp in
                switch stamp {
                case .value(let stamp): return .string(stamp.rawValue)
                case .elements(let elements): return .object(elements.mapValues { .string($0.rawValue) })
                }
            }),
        ])
    }

    func save(in connection: SQLiteConnection, now: Date) throws {
        try connection.execute("""
            INSERT INTO ck_patches (zone_key, record_type, wire_id, patch_json, dirty_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET patch_json = excluded.patch_json
        """, [.text(zoneKey), .text(type), .text(wireID), .text(String(decoding: json.serialized(), as: UTF8.self)), .real(now.timeIntervalSinceReferenceDate)])
    }

    /// `envelope` with the patch's values and stamps laid over it, element by element for maps and sets,
    /// each path where its stamp is not earlier than the one the envelope holds: a value the envelope
    /// stamped later (a change of the outbox's own, or a newer version) stands.
    func applied(to envelope: SyncEnvelope) -> SyncEnvelope {
        var patched = envelope
        for (field, value) in changes {
            switch stamps[field] {
            case .value(let stamp)?:
                // X and N order by value, not by stamp: a larger furthest-position or an earlier first-added
                // time wins whichever side wrote last (§6.1). The patch's value goes on only when it wins, under
                // the patch's own stamp (an equal one would read as "the server already holds this"), and a
                // value that loses leaves the envelope alone, whatever the stamps say (M5).
                if stamp.policy == .maximum || stamp.policy == .minimum,
                   let heldValue = patched.fields[field], let order = FieldMerge.compareOrdered(value, heldValue) {
                    guard stamp.policy == .maximum ? order > 0 : order < 0 else { continue }
                    patched.fields[field] = value
                    patched.stamps[field] = .value(stamp)
                    continue
                }
                if case .value(let held)? = patched.stamps[field], held.isLater(than: stamp) { continue }
                patched.fields[field] = value
                patched.stamps[field] = .value(stamp)
            case .elements(let elementStamps)?:
                var values = patched.fields[field]?.objectValue ?? [:]
                var held: [String: SyncStamp] = if case .elements(let held)? = patched.stamps[field] { held } else { [:] }
                for (element, stamp) in elementStamps {
                    guard let elementValue = value[element] else { continue }
                    if let present = held[element], present.isLater(than: stamp) { continue }
                    values[element] = elementValue
                    held[element] = stamp
                }
                patched.fields[field] = .object(values)
                patched.stamps[field] = .elements(held)
            case nil:
                continue
            }
        }
        return patched
    }

    /// Keeps only the paths whose stamp the merge kept, and the ones the merge took from the patch under a
    /// later stamp of the server's (X and N take the winning value, whoever stamped it last); the row goes
    /// when none is left.
    func keeping(_ merged: SyncEnvelope, takenFromLocal: Set<StampedPath> = [], in connection: SQLiteConnection, now: Date) throws {
        var kept = self
        for (field, stamp) in stamps {
            switch (stamp, merged.stamps[field]) {
            case (.value(let mine), .value(let theirs)?) where mine == theirs:
                continue
            case (.value, _) where takenFromLocal.contains(StampedPath(field)):
                continue
            case (.elements(let mine), .elements(let theirs)?):
                let survivors = mine.filter { theirs[$0.key] == $0.value || takenFromLocal.contains(StampedPath(field, element: $0.key)) }
                if survivors.isEmpty {
                    kept.changes[field] = nil
                    kept.stamps[field] = nil
                } else {
                    kept.stamps[field] = .elements(survivors)
                    kept.changes[field] = .object((changes[field]?.objectValue ?? [:]).filter { survivors[$0.key] != nil })
                }
            default:
                kept.changes[field] = nil
                kept.stamps[field] = nil
            }
        }
        if kept.stamps.isEmpty {
            try Self.delete(zoneKey: zoneKey, type: type, wireID: wireID, in: connection)
        } else if kept != self {
            try kept.save(in: connection, now: now)
        }
    }
}
