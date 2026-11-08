import CloudKit
import Foundation
import OSLog

/// Wires the generation-2 sync of one device (docs/cloudkit-schema-design.md §2.3, §2.4, §2.5, §9.7,
/// §14.1): the account, the bootstrap, then one CKSyncEngine on the private database with scope
/// `.zoneIDs([Library, Catalog])`, whose events reach `PrivateSyncEngine`; after it, SpaceSync walks
/// and sends every owned and joined space, and BlobStore and ShareService run on the same transport
/// and pacers. It publishes `SyncStatus`. Only a generation-2 build with a library container starts
/// it (`start` refuses otherwise), and nothing starts it before the activation is wired into the
/// launch (WP16a); pushes reach it through `handleRemoteNotification(from:)`, and an accepted share
/// through `acceptShare`.
/// Work a device runs inside each private round (§6.2 step 4, D44): after the fetch, bringing in the
/// bodies inbound pointers named; before the send, publishing the bodies that went idle, so their
/// pointers go out in the same round. The Mac's is `DocBodySync` (WP11).
protocol SyncRoundHooks: Sendable {
    func afterFetch() async
    func beforeSend() async
}

/// The Mac's maintenance (`MaintenanceService`, WP17): the compaction gate before the engine starts,
/// so a device back from a long absence discards its engine state and re-fetches before it sends
/// (§3.2 rule 4); after each round, the lease and the work its holder runs.
protocol SyncMaintenanceHooks: Sendable {
    func beforeEngineStarts() async
    func afterRound(caughtUp: Bool) async
}

actor SyncCoordinator {
    /// The coordinator the app started, for the push handler.
    nonisolated(unsafe) static weak var current: SyncCoordinator?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SyncCoordinator")
    /// Pushes that name nothing but satellite uploads are coalesced into one fetch per 30 seconds (§2.3).
    static let coalescingInterval: TimeInterval = 30

    let container: CKContainer
    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let client: ZoneBootstrap.Client
    let deviceID: String
    let engine: PrivateSyncEngine
    let spaces: SpaceSync
    let blobs: BlobStore
    let shares: ShareService
    /// The private database's pacer, shared by the engine, SpaceSync and BlobStore (D43).
    let pacer: SyncPacer
    private var syncEngine: CKSyncEngine?
    private var delegate: PrivateEngineDelegate?
    private(set) var status = SyncStatus()
    private var onStatus: (@Sendable (SyncStatus) -> Void)?
    private var lastPushFetch: Date?
    /// What the device runs between a round's fetch and its send (the Mac's Doc and notes bodies, WP11).
    private var roundHooks: (any SyncRoundHooks)?
    /// What the device does after each round: the Mac's one chain of Job runs, move work and cutover ticks
    /// (`MacSyncSession.wire`, WP16).
    private var afterRound: (@Sendable () async -> Void)?
    /// What the Mac runs before the engine starts and after each round: the compaction gate, then the
    /// lease, the Device record, GC and the janitor (`MaintenanceService`, WP17). `caughtUp` says the
    /// round took every private zone and every space to the end, which the janitor and GC wait for.
    private var maintenance: (any SyncMaintenanceHooks)?
    private var privateFetchCompleted = false
    private var sendScheduled = false
    /// The round in flight, and whether another was asked for while it ran (`syncNow`).
    private var roundTask: Task<Void, Never>?
    private var roundAgain = false
    /// Whether the last round's SpaceSync walk reached the end of every space.
    private var spacesWalkedAll = false
    /// The CKSyncEngine belongs to a database that stopped: the next start makes a fresh one, so its saved
    /// state (tokens of zones that may be gone) is never written back over the new one (m6).
    private var engineStale = false
    /// How many times the learner has had this Mac upload its library again; the Mac's cutover session
    /// starts its seed over when this changes, since it marks the cutover finished until a relaunch.
    private(set) var uploadGeneration = 0
    /// How long `sendSoon` waits: past the outbox's debounce, so the change it was asked for is due.
    static let sendSoonDelay: TimeInterval = 3

    /// `pacer` is the private database's, `SyncPacer.shared(container:database: .private)`; the shared
    /// database's comes from the same registry.
    init(containerIdentifier: String, store: PrivateSyncLocalStore,
         client: ZoneBootstrap.Client, deviceID: String, pacer: SyncPacer, accountName: String? = nil) {
        container = CKContainer(identifier: containerIdentifier)
        let cloud = CloudKitTransport(container: container)
        transport = cloud
        self.store = store
        self.client = client
        self.deviceID = deviceID
        self.pacer = pacer
        let moveMaps = MoveMapIndex()
        engine = PrivateSyncEngine(transport: cloud, store: store, pacer: pacer, moveMaps: moveMaps, deviceID: deviceID)
        let pacers: @Sendable (CloudDatabaseScope) async -> SyncPacer = { database in
            database == .private ? pacer : await SyncPacer.shared(container: containerIdentifier, database: database)
        }
        spaces = SpaceSync(transport: cloud, store: store, moveMaps: moveMaps, deviceID: deviceID, pacer: pacers)
        blobs = BlobStore(transport: cloud, store: store, deviceID: deviceID, pacer: pacers)
        shares = ShareService(transport: cloud, store: store, spaces: spaces, accountName: accountName)
    }

    func setRoundHooks(_ hooks: (any SyncRoundHooks)?) {
        roundHooks = hooks
    }

    func setAfterRound(_ work: @escaping @Sendable () async -> Void) {
        afterRound = work
    }

    func setMaintenance(_ hooks: (any SyncMaintenanceHooks)?) {
        maintenance = hooks
    }

    func observe(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        onStatus = handler
        handler(status)
    }

    private func publish(_ change: (inout SyncStatus) -> Void) {
        change(&status)
        onStatus?(status)
    }

    // MARK: - Starting

    /// Checks the account, runs the bootstrap and starts the engine. Safe to call again: a device
    /// that waited (no root yet, a failed lookup) tries the bootstrap once more.
    func start() async {
        guard ForeverLMRuntimeIdentity.syncGeneration == .two else { return }
        Self.current = self
        publish { $0.phase = .starting }
        do {
            try await engine.start()
            if let stop = await engine.stopped {
                publish { $0.phase = .stopped(stop) }
                return
            }
            guard try await transport.accountStatus() == .available else {
                publish { $0.phase = .noAccount }
                return
            }
            // No old container to look in: it stayed with the old Apple team, so an account with no root is
            // brand-new to this one (§2.4).
            var bootstrap = ZoneBootstrap(transport: transport, legacyTransport: nil, store: store, client: client, deviceID: deviceID)
            bootstrap.now = { Date() }
            #if os(macOS)
            bootstrap.containerEnvironment = CloudRuntimeAvailability.containerEnvironment.rawValue
            #endif
            switch try await bootstrap.run() {
            case .adopted, .created:
                break
            case .purged(let event):
                try await engine.stop(event)
                publish { $0.phase = .stopped(event) }
                return
            case .waiting(let reason):
                publish { $0.phase = .waiting(reason) }
                return
            case .staysOnGeneration1:
                publish { $0.phase = .staysOnGeneration1 }
                return
            case .updateRequired(let minimum):
                publish { $0.phase = .updateRequired(minClientRevision: minimum) }
                return
            }
            // What an older build parked raw or held unprojected is taken in now that the zones' salts are known.
            do { try await engine.reapplyAfterUpgrade() } catch {
                Self.logger.error("The upgrade pass failed: \(String(describing: error), privacy: .public)")
            }
            await maintenance?.beforeEngineStarts()
            try await startSyncEngine()
            await syncNow()
        } catch {
            Self.logger.error("Generation 2 could not start: \(String(describing: error), privacy: .public)")
            publish { $0.phase = .failed(error.localizedDescription) }
        }
    }

    /// One round of the device's cadence (`SyncRoundLoop`): a device that has not started, or whose start
    /// ended early (no network yet, no iCloud account, a bootstrap that waited), starts again; one that is
    /// running syncs. A round asked for while one runs is folded into it (`syncNow`).
    func runRound() async {
        if case .starting = status.phase { return }
        if syncEngine != nil, !engineStale {
            // Stopped until the learner acts (a sign-in, "Upload my library again"): the status says so.
            if await engine.stopped != nil { return }
            if await lacksServerOffset() {
                await start()
                return
            }
            await syncNow()
        } else {
            await start()
        }
    }

    /// A device with no server offset cannot mint a stamp, so it sends nothing: its bootstrap tries to learn
    /// one again (m4).
    private func lacksServerOffset() async -> Bool {
        (try? await store.perform { try $0.replica.lacksServerOffset() }) ?? false
    }

    /// Set while the engine is being made: this actor lets another `start()` in at the await below, and two
    /// rounds (a foreground and a write's timer) can both find it unmade. A second engine would overwrite the
    /// first one's state serialization.
    private var engineStarting = false

    private func startSyncEngine() async throws {
        if engineStale {
            delegate?.retire()
            delegate = nil
            syncEngine = nil
            engineStale = false
        }
        guard syncEngine == nil, !engineStarting else { return }
        engineStarting = true
        defer { engineStarting = false }
        let saved = try await store.perform { try $0.replica.engineState(ReplicaStore.EngineScope.privateEngine) }
        let serialization = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let delegate = PrivateEngineDelegate(engine: engine, store: store, coordinator: self, startedFresh: serialization == nil)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: serialization, delegate: delegate)
        configuration.automaticallySync = true
        self.delegate = delegate
        syncEngine = CKSyncEngine(configuration)
    }

    // MARK: - Syncing

    /// Fetches both zones, hands what is pending to CKSyncEngine and sends it, then runs a round of
    /// the spaces: the private side first, so the moves the personal root lists are current.
    ///
    /// One round runs at a time. A call that finds one running asks for another after it and returns when
    /// that has run, so a write made while a round sends goes out in the next, and a caller that waits for a
    /// complete fetch (`syncUntilCaughtUp`) never reads the state of a round that began before it asked.
    func syncNow() async {
        guard syncEngine != nil else { return }
        if let roundTask {
            roundAgain = true
            await roundTask.value
            return
        }
        let task = Task { await self.roundsUntilQuiet() }
        roundTask = task
        await task.value
    }

    private func roundsUntilQuiet() async {
        repeat {
            roundAgain = false
            await oneRound()
        } while roundAgain
        roundTask = nil
    }

    private func oneRound() async {
        guard let syncEngine else { return }
        publish { $0.phase = .syncing }
        privateFetchCompleted = false
        spacesWalkedAll = false
        await engine.markUnfetched(PrivateSyncZones.engineZones)
        do {
            try await syncEngine.fetchChanges(PrivateEngineDelegate.fetchOptions)
            privateFetchCompleted = true
            // CKSyncEngine took both zones to their end; the engine's own fetch loop is not the one that ran.
            if await engine.stopped == nil { await engine.markFetched(PrivateSyncZones.engineZones) }
            await roundHooks?.afterFetch()
            await roundHooks?.beforeSend()
            try await delegate?.schedulePending(on: syncEngine)
            try await syncEngine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs(PrivateSyncZones.engineZones.map(\.ck))))
        } catch {
            Self.logger.error("A private sync round failed: \(String(describing: error), privacy: .public)")
            await noteThrottle(error)
            publish { $0.phase = .failed(error.localizedDescription) }
            return
        }
        await syncSpaces(afterPrivateFetch: privateFetchCompleted)
    }

    /// An operation CloudKit throttled as a whole, which CKSyncEngine retries on its own: the pacer hears it
    /// too, so SpaceSync and BlobStore slow down with the engine (m7).
    private func noteThrottle(_ error: Error) async {
        let mapped = CloudKitMapping.error(error)
        guard [.requestRateLimited, .zoneBusy, .serviceUnavailable, .quotaExceeded].contains(mapped.code) else { return }
        await pacer.refused(.engine, with: mapped)
    }

    /// Fetches both private zones to their end through CKSyncEngine and nothing else: no send, no spaces, no
    /// after-round work, so it is safe to call from inside a round (the maintenance service's GC and janitor
    /// ask for a complete fetch there). The engine's own transport loop is never a second way into the
    /// replica (m5).
    func fetchPrivateToEnd() async -> Bool {
        guard let syncEngine, await engine.stopped == nil else { return false }
        await engine.markUnfetched(PrivateSyncZones.engineZones)
        do {
            try await syncEngine.fetchChanges(PrivateEngineDelegate.fetchOptions)
        } catch {
            Self.logger.error("A private fetch failed: \(String(describing: error), privacy: .public)")
            await noteThrottle(error)
            return false
        }
        guard await engine.stopped == nil else { return false }
        await engine.markFetched(PrivateSyncZones.engineZones)
        return true
    }

    /// One SpaceSync round, never while the private database is stopped (§2.5); then the status.
    /// `afterPrivateFetch`: the round's private fetch reached the end, so a space walk that does too
    /// leaves nothing unfetched.
    private func syncSpaces(afterPrivateFetch: Bool = false) async {
        var caughtUp = false
        var failure: String?
        if await engine.stopped == nil {
            do {
                let walkedAll = try await spaces.sync()
                spacesWalkedAll = walkedAll
                caughtUp = afterPrivateFetch && walkedAll
            } catch {
                Self.logger.error("A space round failed: \(String(describing: error), privacy: .public)")
                failure = error.localizedDescription
            }
        }
        await settle(caughtUp: caughtUp, failure: failure)
    }

    /// Publishes where the round left things, and tells the pacers how many small records wait, so
    /// satellites never hold them back (D43).
    /// `failure`: why part of the round failed. The round's work still settles, but the status says
    /// it failed rather than up to date.
    private func settle(caughtUp: Bool = false, failure: String? = nil) async {
        let pending = await engine.pendingCount + spaces.pendingCount
        let quotaOwner = await spaces.quotaOwner
        await pacer.setSmallRecordBacklog(pending)
        await SyncPacer.shared(container: transport.containerIdentifier, database: .shared).setSmallRecordBacklog(pending)
        let pause = await pacer.pause(of: .engine, writes: true) ?? quotaOwner.map { SyncPacerState.PauseReason.quotaExceeded(owner: $0) }
        if let stop = await engine.stopped {
            publish { $0.phase = .stopped(stop); $0.pendingChanges = 0; $0.pause = pause }
        } else {
            if case .updateRequired(let minimum)? = await engine.sendHold {
                publish { $0.phase = .updateRequired(minClientRevision: minimum); $0.pendingChanges = pending; $0.pause = pause }
            } else if let failure {
                publish { $0.phase = .failed(failure); $0.pendingChanges = pending; $0.pause = pause }
            } else {
                publish { $0.phase = .upToDate; $0.pendingChanges = pending; $0.lastSyncedAt = Date(); $0.pause = pause }
            }
            await afterRound?()
            await maintenance?.afterRound(caughtUp: caughtUp)
        }
    }

    /// Sends what the outbox holds a moment from now, past its debounce, then runs the after-round work
    /// again: a Job's claim goes out at once, and the runner starts it as soon as the server took it.
    /// Calls while one waits fold into it. `delay` is longer when the pacer asked the engine to wait.
    func sendSoon(after delay: TimeInterval = SyncCoordinator.sendSoonDelay) async {
        guard !sendScheduled, syncEngine != nil else { return }
        sendScheduled = true
        try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
        sendScheduled = false
        guard let syncEngine, await engine.stopped == nil else { return }
        do {
            try await delegate?.schedulePending(on: syncEngine)
            try await syncEngine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs(PrivateSyncZones.engineZones.map(\.ck))))
        } catch {
            Self.logger.error("A send could not be made: \(String(describing: error), privacy: .public)")
            await noteThrottle(error)
            return
        }
        await afterRound?()
    }

    /// Sends what the outbox holds now, past its debounce, and returns when the engine has sent it: the
    /// cutover seed hands the engine a bounded batch of rows and waits for it before the next (§13.4). Throws
    /// when the engine is not running or stopped, so a seed does not go on against a database that stopped.
    func sendNow() async throws {
        guard let syncEngine, await engine.stopped == nil else { throw CloudError(.notAuthenticated, message: "the private database is not syncing") }
        try await delegate?.schedulePending(on: syncEngine)
        try await syncEngine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs(PrivateSyncZones.engineZones.map(\.ck))))
    }

    /// A full round, then whether every zone the engine and SpaceSync fetch reached its end: what a
    /// reconcile and a late-import pass wait for before they compare anything with the server (§13.5, §13.6).
    func syncUntilCaughtUp() async -> Bool {
        await syncNow()
        guard await engine.stopped == nil else { return false }
        return await engine.unfetchedZones.isEmpty && spacesWalkedAll
    }

    /// A CloudKit push (D36). The shared database's (`flm-shared-db`) walks the joined spaces. The
    /// private database's is classified by SpaceSync, which walks the owned spaces it names and
    /// coalesces pushes that name nothing but `Content`; one that names `Library` or `Catalog` fetches
    /// the engine's zones, at most once per 30 seconds.
    func handleRemoteNotification(from database: CloudDatabaseScope) async {
        guard syncEngine != nil, await engine.stopped == nil else { return }
        do {
            switch database {
            case .shared:
                try await spaces.handleSharedPush()
            case .private:
                let changes = try await spaces.handlePrivatePush()
                guard changes.engineZones else { break }
                let now = Date()
                if let last = lastPushFetch, now.timeIntervalSince(last) < Self.coalescingInterval { break }
                lastPushFetch = now
                await syncNow()
                return
            }
        } catch {
            Self.logger.error("A push could not be handled: \(String(describing: error), privacy: .public)")
        }
        await settle()
    }

    /// An invitation the system handed over (`userDidAcceptCloudKitShareWith`): accepted, then the
    /// space is walked at once (§9.7). `prepare` runs between the two: the Mac moves a joined team's
    /// identities to the space there, so its first walk lands on the team's rows (WP15).
    @discardableResult
    func acceptShare(_ invitation: CloudShareInvitation, prepare: (@Sendable (SpaceZone) async throws -> Void)? = nil) async throws -> SpaceZone {
        let zone = try await shares.accept(invitation)
        try await prepare?(zone)
        if syncEngine != nil { await syncSpaces() }
        return zone
    }

    /// "Upload my library to iCloud again" (§2.5): forgets the old zones, then bootstraps as a device
    /// that never held a root. The seed that uploads the library follows it (WP16).
    func uploadAgain() async throws {
        try await store.perform { try PurgeHandler.reupload(in: $0) }
        uploadGeneration += 1
        try await engine.resume()
        engineStale = true
        await start()
    }

    /// Deletes this account's private library zones from iCloud, then uploads this Mac's library from the
    /// start. For a library iCloud holds only a stub of: a root a seed finished against nothing, or a move
    /// to another container. Only a Mac that holds the library may do it, since what iCloud held is gone
    /// afterwards, and other devices see the deletion like a purge (`.deleted`) and stop until the
    /// learner uploads from them or lets this Mac's copy sync down.
    func replaceICloudLibrary() async throws {
        guard client == .macHoldingLibrary else {
            throw CloudError(.invalidArguments, message: "this Mac does not hold the library, so it cannot replace iCloud's copy")
        }
        // Stop first, so the zones' deletion is not read back as a purge by a running engine.
        try await engine.stop(.zoneDeleted(reason: .deleted))
        engineStale = true
        _ = try await transport.modifyZones(saving: [], deleting: PrivateSyncZones.all, in: .private)
        try await uploadAgain()
    }

    fileprivate func stopped(_ event: PurgeHandler.Event) {
        engineStale = true
        publish { $0.phase = .stopped(event) }
    }
}

/// CKSyncEngine's delegate for the private database: maps its events onto `PrivateSyncEngine` and
/// builds each send batch from the engine's pending changes (§2.3, §6.6 steps 4 to 6).
final class PrivateEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    static var fetchOptions: CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(PrivateSyncZones.engineZones.map(\.ck)))
        options.prioritizedZoneIDs = PrivateSyncZones.engineZones.map(\.ck)
        return options
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PrivateSyncEngine")

    let engine: PrivateSyncEngine
    let store: PrivateSyncLocalStore
    weak var coordinator: SyncCoordinator?
    private let lock = NSLock()
    private var inFlight: [CloudRecordID: OutboxChange] = [:]
    private var sendStartedAt = Date()
    private var fetchStartedAt = Date()
    /// The engine started without saved state (a first launch, a discarded state): its first fetch is
    /// a pass from nil, which the replica audit follows (§2.3).
    private var auditAfterFetch: Bool
    /// The coordinator made a newer CKSyncEngine: this one's events are not applied any more (m6).
    private var retired = false

    func retire() {
        lock.withLock { retired = true }
    }

    private var isRetired: Bool { lock.withLock { retired } }

    init(engine: PrivateSyncEngine, store: PrivateSyncLocalStore, coordinator: SyncCoordinator, startedFresh: Bool) {
        self.engine = engine
        self.store = store
        self.coordinator = coordinator
        auditAfterFetch = startedFresh
    }

    /// Feeds the engine from the outbox and makes CKSyncEngine's pending list match it.
    func schedulePending(on syncEngine: CKSyncEngine) async throws {
        try await engine.feed()
        var wanted: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in await engine.pendingRecordIDs {
            wanted.append(await engine.isPendingDelete(id) ? .deleteRecord(id.ck) : .saveRecord(id.ck))
        }
        let wantedIDs = Set(wanted.map(Self.recordID))
        let stale = syncEngine.state.pendingRecordZoneChanges.filter { !wantedIDs.contains(Self.recordID($0)) }
        syncEngine.state.remove(pendingRecordZoneChanges: stale)
        syncEngine.state.add(pendingRecordZoneChanges: wanted)
    }

    private static func recordID(_ change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): return id
        @unknown default: return CKRecord.ID(recordName: "")
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        Self.fetchOptions
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isRetired else { return nil }
        do {
            // Nothing waiting takes no token. A refused request is asked again when the pacer says, since
            // CKSyncEngine ends the cycle on nil and nothing else would send what waits (M1).
            guard await engine.pendingCount > 0 else { return nil }
            if let until = await engine.holdUntil(writes: true) {
                if let coordinator { Task { await coordinator.sendSoon(after: max(until.timeIntervalSinceNow, SyncCoordinator.sendSoonDelay)) } }
                return nil
            }
            let batch = try await engine.nextBatch(limit: await engine.pacer.batchSize(.engine))
            let saves = try batch.saves.filter { context.options.scope.contains($0.id.ck) }.map(CloudKitMapping.ckRecord)
            let deletes = batch.deletes.map(\.ck).filter { context.options.scope.contains($0) }
            guard !saves.isEmpty || !deletes.isEmpty else { return nil }
            lock.withLock {
                inFlight = batch.changes
                sendStartedAt = Date()
            }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes, atomicByZone: false)
        } catch {
            Self.logger.error("No batch: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !isRetired else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try JSONEncoder().encode(update.stateSerialization)
                try await store.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.privateEngine, data) }
            case .accountChange(let change):
                switch change.changeType {
                case .signIn:
                    try await engine.resume()
                case .signOut:
                    try await engine.stop(.accountChanged(signedOut: true))
                case .switchAccounts:
                    try await engine.stop(.accountChanged(signedOut: false))
                @unknown default:
                    break
                }
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions {
                    try await engine.handleZoneDeletion(CloudZoneDeletion(zoneID: CloudZoneID(deletion.zoneID), reason: CloudKitMapping.reason(deletion.reason)))
                }
            case .willFetchChanges:
                lock.withLock { fetchStartedAt = Date() }
            case .fetchedRecordZoneChanges(let changes):
                let passStart = lock.withLock { fetchStartedAt }
                var modified: [CloudZoneID: [CloudRecord]] = [:]
                var deleted: [CloudZoneID: [CloudRecordDeletion]] = [:]
                for modification in changes.modifications {
                    modified[CloudZoneID(modification.record.recordID.zoneID), default: []].append(CloudKitMapping.record(modification.record))
                }
                for deletion in changes.deletions {
                    deleted[CloudZoneID(deletion.recordID.zoneID), default: []].append(
                        CloudRecordDeletion(id: CloudRecordID(deletion.recordID), recordType: deletion.recordType)
                    )
                }
                for zone in Set(modified.keys).union(deleted.keys) {
                    try await engine.absorbFetched(modified[zone] ?? [], deleted: deleted[zone] ?? [], in: zone, passStart: passStart)
                }
            case .didFetchChanges:
                let audit = lock.withLock { () -> Bool in
                    defer { auditAfterFetch = false }
                    return auditAfterFetch
                }
                for zone in PrivateSyncZones.engineZones {
                    let now = Date()
                    let due = try await store.perform { try ReplicaAudit.isDue(zone, in: $0, now: now, interval: 7 * 86_400) }
                    if audit || due { try await engine.audit(zone) }
                }
            case .sentRecordZoneChanges(let sent):
                let (changes, sentAt) = lock.withLock { (inFlight, sendStartedAt) }
                var saved: [CloudRecordID: Result<CloudRecord, CloudError>] = [:]
                var deletedResults: [CloudRecordID: Result<Void, CloudError>] = [:]
                for record in sent.savedRecords { saved[CloudRecordID(record.recordID)] = .success(CloudKitMapping.record(record)) }
                for failure in sent.failedRecordSaves { saved[CloudRecordID(failure.record.recordID)] = .failure(CloudKitMapping.error(failure.error)) }
                for id in sent.deletedRecordIDs { deletedResults[CloudRecordID(id)] = .success(()) }
                for (id, error) in sent.failedRecordDeletes { deletedResults[CloudRecordID(id)] = .failure(CloudKitMapping.error(error)) }
                let answered = changes.filter { saved[$0.key] != nil || deletedResults[$0.key] != nil }
                try await engine.handleSent(answered, results: CloudModifyResults(saved: saved, deleted: deletedResults), sentAt: sentAt)
                try await schedulePending(on: syncEngine)
            default:
                break
            }
            if let stop = await engine.stopped { await coordinator?.stopped(stop) }
        } catch {
            Self.logger.error("A sync event failed: \(String(describing: error), privacy: .public)")
        }
    }
}
