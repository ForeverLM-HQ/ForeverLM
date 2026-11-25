import AppKit
import Foundation
import OSLog

// MARK: - The Mac's generation-2 sync (docs/cloudkit-schema-design.md §2.3, §13.3 step 3e, §13.4, §13.5, §14.1)

/// What runs in each private round beside the engine on the Mac: the Doc and notes bodies (`DocBodySync`),
/// and, after a fetch, what the inbound records changed that the surfaces read from somewhere else: the
/// notebook states, enrollments and card states the view models keep in memory, the sidebar's keys, the
/// blocked shows, the Settings (`UserDefaults`), and the unticks that waited for their Entry's stamp.
final class MacRoundHooks: SyncRoundHooks, @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacRoundHooks")
    let docs: DocBodySync
    let store: MacPrivateSyncStore
    let satellites: SatelliteReader?

    init(docs: DocBodySync, store: MacPrivateSyncStore, satellites: SatelliteReader? = nil) {
        self.docs = docs
        self.store = store
        self.satellites = satellites
    }

    func afterFetch() async {
        await docs.afterFetch()
        do {
            try await store.onStore { try $0.resolvePendingUnticks() }
        } catch {
            Self.logger.error("Resolving the pending unticks failed: \(String(describing: error), privacy: .public)")
        }
        // This Mac's Device row is made once its clock names its device, which the activation's derivation
        // could not do when the clock did not exist yet.
        do {
            try await store.onStore { try $0.inDerivationTransaction { _ = try $0.ensureThisDeviceRow() } }
        } catch {
            Self.logger.error("Making this Mac's Device row failed: \(String(describing: error), privacy: .public)")
        }
        NotebookStateStore.reload()
        CourseEnrollmentStore.reload()
        MemoryCardStateStore.reload()
        BlockedShowsSync.reload()
        NotebookSidebarSync.reload()
        await PreferenceStore.hydrateFromStore()
        // A Setting that arrived cleared left no row; its old value is still in `UserDefaults`.
        for key in InboundSettingRemovals.take().sorted() {
            let stillAbsent: Bool
            do {
                stillAbsent = try await store.onStore { try $0.scalarInteger("SELECT EXISTS(SELECT 1 FROM user_preferences WHERE key = ?)", [.text(key)]) == 0 }
            } catch {
                Self.logger.error("Checking whether a cleared Setting still has a row failed: \(String(describing: error), privacy: .public)")
                stillAbsent = false
            }
            if stillAbsent { PreferenceStore.applyInboundRemoval(forKey: key) }
        }
        // The records this round applied queued the satellites they point at (a quiz's questions, a chat's
        // long text): fetched off the round, on a utility task.
        satellites?.drainSoon()
        // A narration another device made or removed is laid into (or out of) the working folder; this Mac's
        // own, if an upload failed, is tried again (§14.2 NARR3). Off the round, on a utility task.
        Task(priority: .utility) { await MacNarrationLibrary.shared.roundSettled() }
    }

    func beforeSend() async {
        await docs.beforeSend()
    }
}

/// Tells the Mac's surfaces what each committed inbound apply changed (`AppliedRemoteChanges`), whichever
/// path applied it: a round's fetch, CKSyncEngine's own fetch after a push (which runs no round hooks), a
/// space's walk (which runs after `afterFetch`), the maintenance service, a late import. `StorageService`
/// installs it on the app's own store. Applies that commit while the main queue is busy are told as one.
///
/// The snapshot stores the surfaces read synchronously are read again for the types that feed them, as
/// `MacRoundHooks.afterFetch` does after a round; then the view model and the other models hear the
/// entities generation 1's engine named (`cloudKitSyncRemoteStoreDidChange`), which they already reload
/// on: the view model reads the sources again and publishes only a real change. A Setting cleared on
/// another device is still taken out of `UserDefaults` by `afterFetch` alone.
enum AppliedRemoteChangesAnnouncer {
    private static let lock = AppLock()
    nonisolated(unsafe) private static var pending = AppliedRemoteChanges()
    nonisolated(unsafe) private static var scheduled = false

    /// Called on the store's own thread, right after the commit.
    static func announce(_ changes: AppliedRemoteChanges) {
        guard !changes.isEmpty else { return }
        let schedules = lock.withLock { () -> Bool in
            pending.formUnion(changes)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedules else { return }
        DispatchQueue.main.async {
            let batch = lock.withLock { () -> AppliedRemoteChanges in
                defer {
                    pending = AppliedRemoteChanges()
                    scheduled = false
                }
                return pending
            }
            tell(batch)
        }
    }

    private static func tell(_ changes: AppliedRemoteChanges) {
        let types = changes.types
        if !types.isDisjoint(with: [.notebookState, .entry]) { NotebookStateStore.reload() }
        if types.contains(.notebookState) { NotebookSidebarSync.reload() }
        if types.contains(.enrollment) { CourseEnrollmentStore.reload() }
        if types.contains(.card) { MemoryCardStateStore.reload() }
        if types.contains(.mark) { BlockedShowsSync.reload() }
        guard let note = notification(for: changes) else { return }
        NotificationCenter.default.post(note)
    }

    /// The notification generation 1's engine posts for the same change; nil when no surface reads it.
    static func notification(for changes: AppliedRemoteChanges) -> Notification? {
        let entities = changes.entities
        guard !entities.isEmpty else { return nil }
        return Notification(name: .cloudKitSyncRemoteStoreDidChange, object: nil, userInfo: [
            CloudKitSyncNotificationInfo.affectedEntitiesKey: entities.map(\.rawValue).sorted(),
            CloudKitSyncNotificationInfo.requiresFullRefreshKey: false,
            CloudKitSyncNotificationInfo.changedArtifactIDsKey: changes.artifactIDs.sorted(),
        ])
    }
}

/// `CloudKitSyncStatusCenter`, which Settings and the Studio read, fed from the coordinator's status under
/// generation 2 (§14.1, R5-m2).
final class CloudKitSyncStatusAdapter: @unchecked Sendable {
    private let lock = AppLock()
    private var lastPending = 0

    func update(_ status: SyncStatus) {
        let pending = status.pendingChanges
        let previous = lock.withLock { () -> Int in
            defer { lastPending = pending }
            return lastPending
        }
        let full: Bool
        if case .quotaExceeded? = status.pause { full = true } else { full = false }
        Task {
            await CloudKitSyncStatusCenter.publish { center in
                switch status.phase {
                case .syncing:
                    center.beginReceiving()
                case .failed:
                    // The readout has no failed state of its own: what waits shows as waiting to retry, and
                    // the reason is the status's notice (Settings › iCloud, `get_sync_status`).
                    if pending > 0 {
                        center.waitToRetry(remaining: pending, stalled: true)
                    } else {
                        center.finishReceiving()
                    }
                case .upToDate, .idle:
                    if pending > 0 {
                        center.beginSending(remaining: pending)
                        center.advanceSending(remaining: pending, sentInBatch: max(0, previous - pending))
                    } else {
                        center.finishSending(remaining: 0)
                        center.finishReceiving()
                    }
                default:
                    break
                }
                center.setICloudFull(full)
            }
        }
    }
}

/// The Mac's generation-2 sync of one launch: `SyncCoordinator` on the library container
/// (`ForeverLMRuntimeIdentity.libraryContainerIdentifier`) with the Mac's services beside it, and the
/// library's upload into it (§13.4 the seed, §13.5 the reconcile). It starts after the store's activation
/// finished. There is no old container to import from: generation 1's stayed with
/// the old Apple team, so no late import runs and a `deferred` store's catch-up finds no old world.
///
/// - the engine's rounds run `MacRoundHooks` and, after each, the Job runner, the move jobs, the cutover and
///   the maintenance service (one `setAfterRound`);
/// - a Mac that holds a library and is not the seeder sends nothing until the seed's metadata is complete
///   and its own catch-up has run (`ReplicaStore.EngineScope.holdSendsForSeed`), then reconciles;
/// - a seed claim waits for a `deferred` store's catch-up and for "This Mac holds my library"
///  .
actor MacSyncSession {
    /// The session the app started. Strong: the services below are held through it.
    nonisolated(unsafe) static var current: MacSyncSession?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacSyncSession")
    private static let started = AppLock()
    nonisolated(unsafe) private static var startedOnce = false

    /// Whether this build syncs at all: a library container to sync with, and not the First Run app. The
    /// First Run app signs in to the same iCloud account as the Dev app, and CloudKit keys the private
    /// database by account, not by bundle, so syncing there would download the seeded Dev library into
    /// what is meant to be a stranger's first launch.
    static var isEnabled: Bool {
        ForeverLMRuntimeIdentity.libraryContainerIdentifier != nil
            && !ForeverLMRuntimeIdentity.isFirstRun
    }

    private let storage: StorageService
    private let store: MacPrivateSyncStore
    private let makeJobWork: @Sendable (SyncCoordinator) -> any MacJobWork
    private let container: String
    private let statusAdapter = CloudKitSyncStatusAdapter()

    private(set) var coordinator: SyncCoordinator?
    private(set) var deviceID = ""
    private var holds = false
    private var holding: CutoverReadiness.Holding = .none
    /// A `fresh` Mac with a library the learner has not confirmed: it syncs as a Mac without one and sends
    /// nothing, whatever the root says, until "This Mac holds my library" (`HoldsMyLibrary.standing`).
    private var waitsForLearner = false
    private var services = Services()
    private var ticking = false
    private var drain: Task<Int, Never>?
    private var cutoverFinished = false
    private var starting = false
    private var retries = 0
    private var rounds: SyncRoundLoop?
    private var watcher: OutboxWatcher?
    private var observers: [NSObjectProtocol] = []
    private var accountWritten = false
    private var lastPurge = Date.distantPast
    private var movedReported = false
    /// The coordinator's `uploadGeneration` this session last saw.
    private var seenUploadGeneration = 0
    /// A `deferred` store whose catch-up has not run (§13.3): it syncs receive-only, as a Mac with no library,
    /// until its deferred catch-up has run over a complete fetch, and then holds its library.
    private var catchUpOwed = false

    /// What the session keeps alive: the coordinator holds its hooks weakly or not at all.
    private struct Services {
        var maintenance: MaintenanceService?
        var covers: NotebookCoverService?
        var jobs: MacJobRunner?
        var moves: SpaceMoveJob?
        var docs: DocBodySync?
        var hooks: MacRoundHooks?
        var spaces: SpaceService?
    }

    init(storage: StorageService, container: String, makeJobWork: @escaping @Sendable (SyncCoordinator) -> any MacJobWork) {
        self.storage = storage
        self.container = container
        self.makeJobWork = makeJobWork
        store = MacPrivateSyncStore.onStorage(storage)
    }

    /// Makes the session once per process and starts it without waiting: the first round runs on its own.
    /// A unit-test host never makes one: the Debug app that hosts the tests is generation 2 on the shared
    /// Development container, and a real sync starting under the suites would write to it.
    @discardableResult
    static func startIfEnabled(storage: StorageService, makeJobWork: @escaping @Sendable (SyncCoordinator) -> any MacJobWork) -> MacSyncSession? {
        guard isEnabled, !ForeverLMRuntimeIdentity.isTestHost, let container = ForeverLMRuntimeIdentity.libraryContainerIdentifier else { return nil }
        started.lock()
        defer { started.unlock() }
        guard !startedOnce else { return current }
        startedOnce = true
        let session = MacSyncSession(storage: storage, container: container, makeJobWork: makeJobWork)
        current = session
        MigrationServices.shared.claimer = SessionLibraryClaimer(session: session)
        Task {
            await session.start()
            await session.beginRounds()
        }
        return session
    }

    // MARK: - Rounds (§2.3: launch, foreground, every 15 minutes, after a write)

    /// The cadence after the first start: a round every 15 minutes whether or not the app is in front, one
    /// when it comes forward or the Mac wakes (the network is back), and a send soon after a local write. A start
    /// that ended early (no network at login, no iCloud yet, a catch-up still to run) is tried again by each
    /// of them: `round()` starts what is not running.
    private func beginRounds() async {
        let loop = SyncRoundLoop { [weak self] in await self?.round() }
        rounds = loop
        await loop.foreground(roundNow: false)
        let watcher = OutboxWatcher(
            read: { [store] in try? await store.perform { try OutboxSignature.read(in: $0.connection) } },
            changed: { [weak self] in await self?.localWrite() }
        )
        self.watcher = watcher
        await watcher.start()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await loop.requestRound() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            // The network takes a few seconds to come back after a wake.
            Task { await loop.wrote(dueIn: 5) }
        })
    }

    /// One round of the cadence: the coordinator syncs, or, when none was made yet, the start is tried again.
    func round() async {
        if let coordinator {
            await coordinator.runRound()
        } else {
            await start()
        }
        await retryIfNotRunning()
    }

    /// Seconds before the next try of a start that did not get going (no network at login, no iCloud account
    /// yet): sooner than the 15-minute timer, backing off, and only while it keeps failing.
    static let retryDelays: [TimeInterval] = [30, 60, 120, 300, 600]

    private func retryIfNotRunning() async {
        let phase = await coordinator?.status.phase
        let running: Bool
        switch phase {
        case nil, .idle?, .noAccount?, .failed?: running = false
        default: running = true
        }
        guard !running else {
            retries = 0
            return
        }
        guard let rounds, retries < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retries]
        retries += 1
        await rounds.wrote(dueIn: delay)
    }

    /// The outbox got a row: sent soon, past its debounce (`StorageService.scheduleCloudKitSync`, and the
    /// watcher for a write nothing announced). Writes in quick succession share one send.
    func localWrite(after delay: TimeInterval = SyncCoordinator.sendSoonDelay) async {
        await coordinator?.sendSoon(after: delay)
    }

    // MARK: - Sync now (Settings › iCloud, MCP `sync_icloud_now`, a finished import)

    /// "Sync now" and "Retry now": a round, which starts a sync that did not get going; the pacers own every
    /// wait, so a retry is the same round.
    func syncNow() async {
        await round()
    }

    /// Pushes what the outbox holds, round by round, and returns how many local changes still wait: zero only
    /// when the outbox is empty (`OutboxDrain`).
    func pushAndWaitForOutbox(maxAttempts: Int) async -> Int {
        let store = store
        let drain = OutboxDrain(
            push: { [weak self] in await self?.round() },
            backlog: { try? await store.perform { try OutboxBacklog.read(in: $0.connection) } }
        )
        return await drain.run(maxAttempts: maxAttempts)
    }

    /// The local changes the outbox still holds for the server.
    /// A failed read throws: zero means nothing waits, never "could not tell".
    func outboxBacklog() async throws -> Int {
        try await store.perform { try OutboxBacklog.read(in: $0.connection) }.changes
    }

    // MARK: - Starting

    /// Starts the engine and its services once the store is activated and the cutover lets this Mac sync.
    /// Called again when something that held it changes (the deferred catch-up ran, the learner confirmed).
    func start() async {
        // One start at a time: the cadence and a learner's confirmation may both ask while the first waits on
        // the activation or the catch-up, and two would make two coordinators.
        guard coordinator == nil, !starting else { return }
        starting = true
        defer { starting = false }
        await GenerationActivationGate.shared.waitUntilOpen()
        do {
            switch try await readReadiness() {
            case .notActivated:
                Self.logger.error("The store is not activated: generation 2 does not sync")
                return
            case .waitingForCatchUp:
                // A `deferred` store fetches the new container first, receive-only: it joins as a Mac with no
                // library, sends nothing and takes no claim or lease. Its catch-up runs after a round, over
                // the complete fetch (`cutoverTick`), and then it holds its library (§13.3).
                catchUpOwed = true
                holding = .library
                waitsForLearner = true
                CutoverStatus.shared.update(.waitingForCatchUp)
                try await begin(client: .macWithoutLibrary)
                return
            case .waitingForConfirmation:
                CutoverStatus.shared.update(.waitingForConfirmation)
                await resumeConfirmation()
                return
            case .ready(let found):
                holding = found
            }
            // A `fresh` library on an account with no root seeds at once (§2.4).
            let client = CutoverReadiness.client(for: holding)
            holds = client == .macHoldingLibrary
            waitsForLearner = !holds && holding != .none
            try await begin(client: client)
        } catch {
            Self.logger.error("The Mac's generation-2 sync could not start: \(String(describing: error), privacy: .public)")
        }
    }

    private func readReadiness() async throws -> CutoverReadiness {
        let (journal, hasLibrary) = try await store.perform { state -> (CutoverJournal.Read, Bool) in
            (try CutoverJournal.read(state.connection), try CutoverJournal.holdsLibrary(state.connection))
        }
        let confirmation = try await store.onStore { try $0.holdsMyLibraryConfirmation() }
        return CutoverReadiness.decide(
            journal, hasLibrary: hasLibrary, confirmedHoldsLibrary: confirmation?.catchUpAt != nil,
            confirmationStarted: confirmation != nil
        )
    }

    /// The deferred catch-up "This Mac holds my library" runs first. A store whose `Knowledge` zone was
    /// missing reads nothing from the old zones (R6-m9). Any other first joins receive-only when it has not
    /// started yet, fetches the new container to its end, and runs the catch-up over that fetch. Throws while
    /// it has not run, so the flow keeps its confirmation and resumes.
    func runDeferredCatchUpForClaim(readsOldZones: Bool) async throws {
        guard readsOldZones else { return }
        if coordinator == nil {
            holding = .library
            waitsForLearner = true
            try await begin(client: .macWithoutLibrary)
        }
        guard let coordinator else { throw SessionLibraryClaimer.NotYet(reason: "The new iCloud store could not be reached yet.") }
        _ = await coordinator.syncUntilCaughtUp()
    }

    /// What a `deferred` store does once a round has fetched (§13.3): there is no old world to catch up
    /// with, since generation 1's container stayed with the old Apple team and no build is entitled to it.
    /// So the library waits for "This Mac holds my library", and the learner's confirmation uploads it.
    private func settleOwedCatchUp() {
        catchUpOwed = false
        CutoverStatus.shared.update(.waitingForConfirmation)
    }

    /// This Mac holds its library from here on, in place: the root and the engine are the same for a Mac with
    /// one and without, and the seeder or the reconcile decides which it does. Its sends wait for the seed
    /// (§13.5).
    private func takeLibrary() async {
        guard !holds else { return }
        holds = true
        waitsForLearner = false
        holding = .library
        cutoverFinished = false
        do {
            try await setHold(true)
        } catch {
            Self.logger.error("Sends were not held for the library confirmation: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A confirmation whose catch-up or claim a quit interrupted goes on where it stopped; nothing asks the
    /// learner twice (`HoldsMyLibraryFlow` keeps its progress in `library.holdsConfirmed`).
    private func resumeConfirmation() async {
        guard let claimer = MigrationServices.shared.claimer else { return }
        let confirmation: Bool
        do {
            confirmation = try await store.onStore { try $0.holdsMyLibraryConfirmation() } != nil
        } catch {
            Self.logger.error("Reading the held library confirmation failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard confirmation else { return }
        let reason: String?
        do {
            reason = try await store.perform { try CutoverJournal.read($0.connection).freshReason }
        } catch {
            Self.logger.error("Reading the cutover journal failed: \(String(describing: error), privacy: .public)")
            return
        }
        let flow = HoldsMyLibraryFlow(record: SessionHoldsMyLibraryRecord(store: store), claimer: claimer)
        do {
            _ = try await flow.confirm(freshReason: reason.flatMap(FreshReason.init(rawValue:)))
        } catch {
            Self.logger.error("Resuming the held library confirmation failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - This Mac holds my library

    /// The learner confirmed and the catch-up ran: this Mac may claim the seed or reconcile (`Standing.mayClaim`).
    /// A session that has not started (a store whose old zone was missing starts nothing before this) starts
    /// now as a Mac holding its library; one that runs as a Mac without a library takes its library in place,
    /// since the root and the engine are the same for both, and the seeder or the reconcile decides which.
    func claimOrReconcile() async -> LibraryClaimOutcome {
        if coordinator == nil { await start() }
        guard let coordinator else { return .notYet }
        await takeLibrary()
        await coordinator.syncNow()
        let outcome = await rootOutcome()
        if outcome != .notYet { Task { await self.cutoverTick() } }
        return outcome
    }

    /// What the root says now: the seed is this Mac's, or complete (so this Mac reconciles), or another Mac's
    /// or not made yet.
    private func rootOutcome() async -> LibraryClaimOutcome {
        let deviceID = deviceID
        do {
            return try await store.perform { state -> LibraryClaimOutcome in
                guard let root = try state.replica.personalRoot()?.envelope else { return .notYet }
                return LibraryClaimOutcome.forRoot(CutoverRootState(root: root), me: deviceID, now: SyncTime.milliseconds(Date()))
            }
        } catch {
            Self.logger.error("Reading the library root failed: \(String(describing: error), privacy: .public)")
            return .notYet
        }
    }

    private func begin(client: ZoneBootstrap.Client) async throws {
        let clockID = try await store.perform { try $0.replica.loadClock()?.deviceID }
        let deviceID = MacSyncDeviceID.current(clockDeviceID: clockID)
        self.deviceID = deviceID
        // Rows this Mac wrote before it knew its sync device id take it (a day logged both ways is merged).
        try await store.onStore { try $0.claimOwnMemoryRows(deviceID: deviceID) }

        try await setHold(true)

        let pacer = await SyncPacer.shared(container: container, database: .private)
        let name = NSFullUserName()
        let coordinator = SyncCoordinator(
            containerIdentifier: container, store: store, client: client, deviceID: deviceID, pacer: pacer,
            accountName: name.isEmpty ? nil : name
        )
        self.coordinator = coordinator
        await wire(coordinator, deviceID: deviceID)
        await coordinator.observe { [weak self, statusAdapter] status in
            statusAdapter.update(status)
            if status.phase == .upToDate { Task { await self?.settled() } }
        }
        await coordinator.start()
    }

    /// Builds the Mac's services around the coordinator and attaches them.
    private func wire(_ coordinator: SyncCoordinator, deviceID: String) async {
        let blobs = coordinator.blobs
        let writer = MaintenanceWriter(transport: coordinator.transport, store: store, moveMaps: coordinator.engine.moveMaps, deviceID: deviceID, clock: { Date() })

        let docs = DocBodySync(store: store, transfer: .blobStore(blobs, store: store))
        DocBodySync.current = docs
        let hooks = MacRoundHooks(docs: docs, store: store, satellites: SatelliteReader.live(blobs: blobs, store: store))
        await coordinator.setRoundHooks(hooks)

        let storage = storage
        let jobs = MacJobRunner(store: { body in try await storage.performSync(body) }, work: makeJobWork(coordinator))
        await jobs.setOnChange { Task { await coordinator.sendSoon() } }
        let moves = SpaceMoveJob(coordinator: coordinator)
        let spaces = SpaceService(coordinator: coordinator)

        let info = Bundle.main.infoDictionary
        let description = MaintenanceDeviceDescription(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0", appBuild: info?["CFBundleVersion"] as? String ?? "0",
            displayName: Host.current().localizedName
        )
        let maintenance = MaintenanceService(
            transport: coordinator.transport, store: store, blobs: blobs, moveMaps: coordinator.engine.moveMaps, deviceID: deviceID,
            description: description, holdsLibrary: { [weak self] in await self?.holds ?? false },
            fetchToEnd: {
                // CKSyncEngine fetches the private zones, so the replica has one way in (m5).
                guard await coordinator.fetchPrivateToEnd() else { return false }
                do {
                    guard try await coordinator.spaces.sync() else { return false }
                } catch {
                    return false
                }
                return await coordinator.engine.unfetchedZones.isEmpty
            }
        )
        // The notebook covers: the service is kept here, since `current` is weak, and the maintenance service
        // wakes it after each round and runs its backfill on the lease holder.
        let covers = NotebookCoverService.live(store: store, blobs: blobs, writer: writer, deviceID: deviceID)
        await maintenance.attachCovers(covers)
        await maintenance.attach(to: coordinator)

        services.docs = docs
        services.hooks = hooks
        services.jobs = jobs
        services.moves = moves
        services.spaces = spaces
        services.maintenance = maintenance
        services.covers = covers

        // One after-round chain: `setAfterRound` holds a single closure, and the move jobs run beside the
        // Job runner. Nothing here waits on the cutover, which runs on a task of its own.
        await coordinator.setAfterRound { [weak self] in
            // A body that a space's walk pointed at (a shared Doc's, `DocSpaces`) is brought in now and not
            // a round later: the walk runs after the private fetch's own hook. One query when none waits.
            await docs.afterFetch()
            _ = await jobs.pass()
            _ = await moves.afterRound()
            await self?.afterRound()
        }

        // The library this Mac reopens on is walked first from the first round on (§2.2); switching
        // libraries updates it (`StudioViewModel.setActiveTeam`).
        let reopened = UserDefaults.standard.string(forKey: StudioViewModel.activeTeamPreferenceKey)
        await storage.applySpaceFetchPriority(
            activeTeamID: reopened?.isEmpty == false ? reopened : nil, openedNow: false, coordinator: coordinator
        )
    }

    // MARK: - After each round

    private func afterRound() async {
        Task { await self.cutoverTick() }
        // Only the Mac that holds the library lays out its pointers.
        if holds { Task { await self.drainBackfills() } }
    }

    /// The activation's queues (every source's files, the Understanding documents, narration positions an
    /// evicted file held back): before the seed sends the records that carry their pointers, and after
    /// each round for what is left. One drain at a time.
    private func drainBackfills() async {
        if let drain {
            await drain.value
            return
        }
        let store = store
        let task = Task { () -> Int in
            let laid = await SyncBackfillDrain.run(store: store)
            let published = await self.publishSourceFiles()
            let covers = await self.publishBookCovers()
            let pictures = await self.publishCardPictures()
            await self.restoreMissingSatellites()
            return laid + published + covers + pictures
        }
        drain = task
        await task.value
        drain = nil
    }

    /// Whether this Mac's sends are held for the seed. A read that fails counts as held, so nothing is sent
    /// before the hold is known to be lifted.
    private func sendsAreHeld() async -> Bool {
        do {
            return try await store.perform { try $0.replica.engineState(ReplicaStore.EngineScope.holdSendsForSeed) != nil }
        } catch {
            Self.logger.error("Reading the hold on this Mac's sends failed: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    /// Uploads the satellites of the sources this Mac ingested since the activation, so another Mac takes their
    /// text and PDF instead of ingesting them again (`InboundSourceFiles`). Only while this Mac's sends are not
    /// held: the seed lays out and uploads what existed at the cutover, and a held Mac's pointers could not be
    /// sent after their bytes.
    private func publishSourceFiles() async -> Int {
        guard let coordinator else { return 0 }
        let held = await sendsAreHeld()
        guard !held else { return 0 }
        let publisher = SourceFilePublisher(
            store: store, blobs: coordinator.blobs,
            pendingCount: { await coordinator.engine.pendingCount }, wrote: { await coordinator.sendSoon() }
        )
        return await publisher.run()
    }

    /// Uploads the covers of the books this Mac holds a cover file for whose record names none, so another Mac
    /// and the iPhone show them (`BookCovers`). Under the same hold as the publisher.
    private func publishBookCovers() async -> Int {
        guard let coordinator else { return 0 }
        let held = await sendsAreHeld()
        guard !held else { return 0 }
        let writer = MaintenanceWriter(
            transport: coordinator.transport, store: store, moveMaps: coordinator.engine.moveMaps, deviceID: deviceID, clock: { Date() }
        )
        return await BookCoverPublisher(store: store, blobs: coordinator.blobs, writer: writer).run()
    }

    /// Uploads the pictures of the learner's cards that the iPhone cannot draw itself — a slide, a video frame, an
    /// article's or book's image, a stored drawing — and points each card at them (`CardPictures`). Under the same
    /// hold as the publisher.
    private func publishCardPictures() async -> Int {
        guard let coordinator else { return 0 }
        let held = await sendsAreHeld()
        guard !held else { return 0 }
        let writer = MaintenanceWriter(
            transport: coordinator.transport, store: store, moveMaps: coordinator.engine.moveMaps, deviceID: deviceID, clock: { Date() }
        )
        return await CardPicturePublisher(store: store, blobs: coordinator.blobs, writer: writer).run()
    }

    /// Once per library, uploads the satellites its pointers name and the server lacks, where this Mac holds the
    /// bytes (`CutoverSatellites.restoreMissing`). Under the same hold as the publisher.
    private func restoreMissingSatellites() async {
        guard let coordinator else { return }
        let held = await sendsAreHeld()
        guard !held else { return }
        let satellites = CutoverSatellites(store: store, blobs: coordinator.blobs, pendingCount: { await coordinator.engine.pendingCount })
        do {
            try await satellites.restoreMissing()
        } catch {
            Self.logger.notice("Restoring missing satellites stopped for now: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs when a round ends up to date: the account the replica belongs to, the teams as spaces and the
    /// cutover.
    private func settled() async {
        guard let coordinator else { return }
        if !accountWritten, let account = try? await coordinator.transport.userRecordName() {
            accountWritten = true
            do {
                try await store.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.account, Data(account.utf8)) }
            } catch {
                Self.logger.error("The account name was not stored: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let spaces = services.spaces {
            do {
                try await spaces.mirrorTeams()
            } catch {
                Self.logger.error("Mirroring the teams as spaces failed: \(String(describing: error), privacy: .public)")
            }
            if Date().timeIntervalSince(lastPurge) > 6 * 3_600 {
                lastPurge = Date()
                do {
                    _ = try await spaces.purgeExpired()
                } catch {
                    Self.logger.error("Purging expired spaces failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        await remakeLostTeamSpaces()
        await restoreTeamSpaceSatellites()
        await flushSpaceDelta()
        await cutoverTick()
    }

    /// A team's space is a zone in the container the library syncs with. When the library moved to a new
    /// container or was uploaded again, the space was not carried with it, SpaceSync marked it gone, and the
    /// team's sources, notebooks and chats waited in the outbox for a zone that never came back: the iPhone
    /// listed none of them. The cutover's P6 is done by then, so this makes the space again, as P6 does,
    /// once the cutover is finished and only for a team `TeamToSpace.isOwed` names.
    private func remakeLostTeamSpaces() async {
        guard let coordinator, holds, cutoverFinished else { return }
        let owed: Bool
        do {
            owed = try await store.perform { try TeamToSpace.anyOwed(in: $0) }
        } catch {
            Self.logger.error("Checking for team spaces to make again failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard owed else { return }
        do {
            let owner = SyncPerson(user: try await coordinator.transport.userRecordName(), name: coordinator.shares.accountName ?? "")
            let passKey = "\(deviceID).\(CutoverSeeder.teamsPassID)"
            let outcome = try await TeamToSpace(service: SpaceService(coordinator: coordinator), passKey: passKey).run(owner: owner)
            Self.logger.info("Made \(outcome.spaces.count) team spaces again")
        } catch {
            Self.logger.error("A team's space could not be made again: \(String(describing: error), privacy: .public)")
        }
    }

    /// A converted team's space holds its sources' pointers but, until this runs, none of their bytes: the seed and
    /// the publisher upload the personal library's satellites only. Once per space and salt, once the cutover is
    /// finished and this Mac holds the library, the team's missing text, PDFs and the rest go into the space's zone
    /// (`CutoverSatellites.restoreMissing(inSpace:teamID:)`).
    private func restoreTeamSpaceSatellites() async {
        guard let coordinator, holds, cutoverFinished else { return }
        let spaces: [SpaceSummary]
        do {
            spaces = try await store.perform { try SpaceService.summaries($0.connection) }
        } catch {
            Self.logger.error("Reading the spaces to restore their satellites failed: \(String(describing: error), privacy: .public)")
            spaces = []
        }
        let pending: @Sendable () async -> Int = { await coordinator.engine.pendingCount }
        let satellites = CutoverSatellites(store: store, blobs: coordinator.blobs, pendingCount: pending)
        for space in spaces where space.isOwned && space.gone == nil && ["team", "family"].contains(space.kind ?? "") {
            do {
                try await satellites.restoreMissing(inSpace: space.zone.zoneKey, teamID: space.localTeamID)
            } catch {
                Self.logger.error("A team space's files could not be sent: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// P6's records are acknowledged by SpaceSync after the seed's last step, so their delta is written in a
    /// later round (and again after a crash, from `ck_manifest_pending`, R5-3).
    private func flushSpaceDelta() async {
        let passKey = "\(deviceID).\(CutoverSeeder.teamsPassID)"
        let writer = MaintenanceWriter(transport: coordinator?.transport ?? CloudKitTransport(containerIdentifier: container), store: store, moveMaps: coordinator?.engine.moveMaps ?? MoveMapIndex(), deviceID: deviceID, clock: { Date() })
        guard let blobs = coordinator?.blobs else { return }
        do {
            _ = try await SeedManifestWriter(store: store, blobs: blobs, writer: writer).flushDelta(passKey: passKey)
        } catch {
            Self.logger.error("Writing the space delta manifest failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - The cutover

    /// The hold on this Mac's sends (`holdSendsForSeed`): until the root shows `seed.metadataCompleteAt` or
    /// this Mac is the seeder (§13.5, R8-m5).
    private func setHold(_ hold: Bool) async throws {
        let released = try await store.perform { state -> Bool in
            let replica = state.replica
            let isHolding = try replica.engineState(ReplicaStore.EngineScope.holdSendsForSeed) != nil
            guard isHolding != hold else { return false }
            try replica.setEngineState(ReplicaStore.EngineScope.holdSendsForSeed, hold ? Data("wait".utf8) : nil)
            return !hold
        }
        // What the outbox gathered while sends were held goes out now, not at the next 15-minute round.
        if released { await coordinator?.sendSoon() }
    }

    private func refreshHold() async throws {
        let deviceID = deviceID
        // A library the learner has not confirmed uploads nothing, whatever the root says (§13.5).
        if waitsForLearner {
            try await setHold(true)
            return
        }
        let hold = try await store.perform { state -> Bool in
            guard let root = try state.replica.personalRoot()?.envelope else { return true }
            let seed = CutoverRootState(root: root)
            if seed.metadataCompleteAt != nil { return false }
            return !(seed.state == "seeding" && seed.claimDevice == deviceID)
        }
        try await setHold(hold)
    }

    private func seedEnvironment(_ coordinator: SyncCoordinator) async -> CutoverSeedEnvironment {
        let deviceID = deviceID
        let store = store
        let blobs = coordinator.blobs
        let writer = MaintenanceWriter(transport: coordinator.transport, store: store, moveMaps: coordinator.engine.moveMaps, deviceID: deviceID, clock: { Date() })
        let pending: @Sendable () async -> Int = { await coordinator.engine.pendingCount }
        var environment = CutoverSeedEnvironment(
            transport: coordinator.transport, store: store, registry: store.registry, blobs: blobs, writer: writer, deviceID: deviceID,
            send: { try await coordinator.sendNow() }, pendingCount: pending,
            holdsLibrary: { [weak self] in await self?.holds ?? false }
        )
        environment.pause = { await coordinator.pacer.pause(of: .engine, writes: true) }
        environment.fetchAll = { await coordinator.syncUntilCaughtUp() }
        let satellites = CutoverSatellites(store: store, blobs: blobs, pendingCount: pending)
        environment.uploadSatellites = { try await satellites.upload() }
        environment.runTeams = { passKey in
            let owner = SyncPerson(user: try await coordinator.transport.userRecordName(), name: coordinator.shares.accountName ?? "")
            try await TeamToSpace(service: SpaceService(coordinator: coordinator), passKey: passKey).run(owner: owner)
        }
        environment.progress = { phase in CutoverStatus.shared.update(.seeding(phase)) }
        return environment
    }

    /// One look at where this Mac stands in the cutover, after a round: the seeder seeds, a Mac that finds
    /// the metadata complete reconciles, another's live claim is waited for. It runs on a task of its own, so
    /// the rounds go on; one run at a time.
    private func cutoverTick() async {
        guard let coordinator, !ticking else { return }
        // "Upload my library to iCloud again" made a new root: the cutover this session finished was the old one's.
        let generation = await coordinator.uploadGeneration
        if generation != seenUploadGeneration {
            seenUploadGeneration = generation
            cutoverFinished = false
            movedReported = false
        }
        guard !cutoverFinished else { return }
        ticking = true
        defer { ticking = false }
        do {
            if catchUpOwed {
                settleOwedCatchUp()
                try await refreshHold()
                return
            }
            try await refreshHold()
            guard holds else {
                await reportMovedIfComplete(coordinator)
                return
            }
            // The pointers the records carry exist before the first record is sent.
            await drainBackfills()
            let environment = await seedEnvironment(coordinator)
            switch try await CutoverSeeder(environment).run() {
            case .complete:
                CutoverStatus.shared.update(.moved)
                cutoverFinished = true
            case .noLibrary:
                break
            case .waiting(let holder):
                CutoverStatus.shared.update(.waitingForSeed(holder: holder))
            case .secondMac:
                CutoverStatus.shared.update(.reconciling)
                try await refreshHold()
                switch try await CutoverReconcile(environment).run() {
                case .reconciled(_, _, let satellites):
                    CutoverStatus.shared.update(.moved)
                    cutoverFinished = satellites
                case .noLibrary, .waitingForSeed, .fetchIncomplete:
                    break
                }
            case .stopped(let stop):
                // A stop is retried on the next round; the log says why, since the status alone shows "stopped".
                Self.logger.error("The seed stopped for now: \(String(describing: stop), privacy: .public)")
                CutoverStatus.shared.update(.stopped(stop))
            }
            try await refreshHold()
            await reportMovedIfComplete(coordinator)
        } catch {
            Self.logger.error("The cutover stopped for now: \(String(describing: error), privacy: .public)")
        }
    }

    /// Once the root shows `seed.metadataCompleteAt`, the always-on MCP learns the account moved (`v2Ready`).
    private func reportMovedIfComplete(_ coordinator: SyncCoordinator) async {
        guard !movedReported else { return }
        let complete: Bool
        do {
            complete = try await store.perform { try $0.replica.personalRoot()?.envelope.fields["seed"]?.objectValue?["metadataCompleteAt"] != nil }
        } catch {
            Self.logger.error("Reading whether the seed's metadata is complete failed: \(String(describing: error), privacy: .public)")
            complete = false
        }
        guard complete else { return }
        if await LibraryMovedReport.send(sessionToken: ManagedAI.requestSessionToken) { movedReported = true }
    }

    // MARK: - Narration

    /// What the Mac's narration library needs of this session, once the coordinator runs: the store the pointers
    /// live in, the blobs the satellites move through, and a nudge to send what it wrote (§14.2 NARR3).
    func narrationSession() -> MacNarrationLibrary.Session? {
        guard let coordinator else { return nil }
        return MacNarrationLibrary.Session(store: store, blobs: coordinator.blobs, wrote: { await coordinator.sendSoon() })
    }

    // MARK: - What the status shows

    struct Snapshot: Equatable, Sendable {
        var phase: SyncStatus.Phase
        var pendingChanges: Int
        var lastSyncedAt: Date?
        var holdsLibrary: Bool
        var cutover: CutoverStatus.State
    }

    /// The coordinator's status with the cutover's, for `get_sync_status` and Settings › iCloud.
    func snapshot() async -> Snapshot {
        let status = await coordinator?.status ?? SyncStatus()
        return Snapshot(phase: status.phase, pendingChanges: status.pendingChanges, lastSyncedAt: status.lastSyncedAt, holdsLibrary: holds, cutover: CutoverStatus.shared.current)
    }
}

/// "This Mac holds my library" asks the session for the deferred catch-up and for the claim or the reconcile
/// (`LibraryClaiming`). With no catch-up registered the claimer says so, and the flow
/// leaves the confirmation standing for the next launch.
struct SessionLibraryClaimer: LibraryClaiming {
    /// The catch-up has not run yet; the confirmation stands and the flow resumes.
    struct NotYet: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    let session: MacSyncSession

    func runDeferredCatchUp(readsOldZones: Bool) async throws {
        try await session.runDeferredCatchUpForClaim(readsOldZones: readsOldZones)
    }

    func claimOrReconcile() async throws -> LibraryClaimOutcome {
        await session.claimOrReconcile()
    }
}

/// The confirmation of "This Mac holds my library" in the session's own store, for a flow a relaunch resumes.
struct SessionHoldsMyLibraryRecord: HoldsMyLibraryRecord {
    let store: MacPrivateSyncStore

    func load() async throws -> HoldsMyLibraryConfirmation? {
        try await store.onStore { try $0.holdsMyLibraryConfirmation() }
    }

    func save(_ confirmation: HoldsMyLibraryConfirmation) async throws {
        try await store.onStore { try $0.writeHoldsMyLibraryConfirmation(confirmation) }
    }
}
