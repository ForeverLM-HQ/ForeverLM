import CloudKit
import Foundation
import OSLog
import Security
import UIKit

/// The iPhone's sync (docs/cloudkit-schema-design.md §2.3, §9.7, §14.1 iOS/Sync): `SyncCoordinator`
/// configured for the phone, over the phone's replica, which is the only library the phone reads and
/// writes. The bootstrap runs as a `.phone` client; then one CKSyncEngine on the private database
/// fetches `Library` and `Catalog`, SpaceSync walks every owned and joined space with
/// `desiredKeys = ["payload"]`, and BlobStore fetches satellites only when a screen asks
/// (`coordinator.blobs`).
///
/// Rounds run at launch, on every foreground, every 15 minutes while the app is active and after a
/// CloudKit push (D36); push is never relied on. After a round that stopped the private database or
/// lost a space, the index drops what the replica no longer holds. Each round, a waiting one included,
/// ends with `.mobileReplicaDidChange`, which the screens' models reload on.
///
/// Only a build whose entitlements grant the library container runs it (`isEnabled`).
actor MobileSyncSession {
    /// The session the app started, for the push handler and the screens.
    @MainActor static var current: MobileSyncSession?
    @MainActor private static var starting: Task<MobileSyncSession?, Never>?

    static let refreshInterval: TimeInterval = SyncRoundLoop.refreshInterval
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileSyncSession")

    /// Whether this build syncs at all: it needs a library container its entitlements grant.
    static var isEnabled: Bool {
        ForeverLMRuntimeIdentity.libraryContainerIdentifier != nil
    }

    nonisolated let containerIdentifier: String
    nonisolated let replica: MobileReplica
    nonisolated let projection: MobileProjection
    nonisolated let coordinator: SyncCoordinator
    /// The phone's write path: RecordPatches into the replica, sent by the coordinator's engine
    /// and SpaceSync.
    nonisolated let writer: MobileRecordWriter
    /// Satellites on demand: fetched by name when a screen opens them, kept on disk by hash.
    nonisolated let satellites: MobileSatellites
    /// The phone's search index over its text set (§8a).
    nonisolated let textIndexer: MobileTextIndexer
    private var cadence: SyncRoundLoop?
    /// Runs while the library arrives for the first time (`statusMoved`).
    private var arrivalReadout: Task<Void, Never>?
    /// What the screens last heard about the arrival.
    private var announced = MobileLibraryArrival.settled

    /// The round cadence (`SyncRoundLoop`), made on first use: it calls back into the session.
    private var loop: SyncRoundLoop {
        if let cadence { return cadence }
        let made = SyncRoundLoop { [weak self] in await self?.round() }
        cadence = made
        return made
    }

    init(containerIdentifier: String, replica: MobileReplica, deviceID: String, pacer: SyncPacer) {
        self.containerIdentifier = containerIdentifier
        self.replica = replica
        projection = MobileProjection(replica: replica)
        coordinator = SyncCoordinator(
            containerIdentifier: containerIdentifier, store: replica, client: .phone, deviceID: deviceID, pacer: pacer
        )
        writer = MobileRecordWriter(replica: replica, deviceID: deviceID, blobs: coordinator.blobs)
        satellites = MobileSatellites(projection: projection, blobs: coordinator.blobs)
        textIndexer = MobileTextIndexer(satellites: satellites)
        replica.moveMaps = coordinator.engine.moveMaps
    }

    /// Opens the replica off the main actor and makes the session, once per process, then starts its
    /// first round without waiting for it. Call it only once the account gate let the app reach
    /// iCloud: making the container before then traps.
    @MainActor @discardableResult
    static func startIfEnabled() async -> MobileSyncSession? {
#if DEBUG
        // A preview draws a sample library and never syncs: the unsigned Simulator build it runs
        // in has no iCloud, and CloudKit traps rather than throws on a container it will not serve.
        // The Space's preview died that way at launch on a Simulator that had signed in before.
        // (`isEnabled` stays as it is: the scene configuration reads it.)
        if MobileAppHarness.standsInForTheApp { return nil }
#endif
        guard isEnabled, !ForeverLMRuntimeIdentity.isHostingUnitTests,
              let container = ForeverLMRuntimeIdentity.libraryContainerIdentifier else { return nil }
        if let current { return current }
        if let starting { return await starting.value }
        let task = Task.detached(priority: .utility) { () -> MobileSyncSession? in
            do {
                let replica = try MobileReplica(path: try MobileReplica.fileURL().path)
                let clockDeviceID = try await replica.read { try $0.replica.loadClock()?.deviceID }
                let session = MobileSyncSession(
                    containerIdentifier: container, replica: replica, deviceID: MobileSyncDeviceID.current(clockDeviceID: clockDeviceID),
                    pacer: await SyncPacer.shared(container: container, database: .private)
                )
                session.writer.whenWritten { due in Task { await session.wrote(dueIn: due) } }
                await session.coordinator.observe { status in
                    Task { await session.statusMoved() }
                    switch status.phase {
                    case .upToDate, .stopped, .waiting: Task { await session.settled(status.phase) }
                    default: break
                    }
                }
                // The first round runs on its own: the phone shows its replica at once, never after a
                // network round.
                Task { await session.foreground() }
                return session
            } catch {
                logger.error("The iPhone's replica could not open: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        starting = task
        let session = await task.value
        current = session
        starting = nil
        return session
    }

    // MARK: - Rounds

    /// The app came to the foreground: a round now, then one every 15 minutes while it stays active.
    /// A device whose bootstrap waited (no root yet) tries the bootstrap again instead.
    func foreground() async {
        await loop.foreground()
    }

    /// The app left the foreground: the timer stops; pushes and the next foreground fetch. A running
    /// sitting and the day's activity log go out now rather than after their debounce (D44): made due and
    /// sent in a round of their own, not after the half second a write's round waits, since iOS suspends the
    /// app within seconds of this. The caller holds a background task until it returns.
    func background() async {
        await loop.background()
        do {
            try await writer.flushLearningHistory(sendsSoon: false)
        } catch {
            Self.logger.error("The sitting and the day's activity were not made due: \(String(describing: error), privacy: .public)")
        }
        await round()
    }

    private func round() async {
        await coordinator.runRound()
    }

    /// Something was written: a round once the newest of it is due, so it goes out without waiting
    /// for the next 15-minute round; writes in quick succession share one.
    func wrote(dueIn seconds: TimeInterval) async {
        await loop.wrote(dueIn: seconds)
    }

    /// A CloudKit push of the library container, with the database it came from.
    func handlePush(from database: CloudDatabaseScope) async {
        await coordinator.handleRemoteNotification(from: database)
    }

    /// After a round: when the private database stopped or a space went since the last sweep, the
    /// index drops the rows the replica no longer holds; then the screens hear the replica changed.
    func settled(_ phase: SyncStatus.Phase) async {
        do {
            _ = try await replica.read { try $0.sweepIndexIfNeeded() }
        } catch {
            Self.logger.error("The index could not be swept: \(String(describing: error), privacy: .public)")
        }
        await MainActor.run { NotificationCenter.default.post(name: .mobileReplicaDidChange, object: nil) }
        // The text set's text for search, then bytes the learner asked to have on this phone, after
        // the screens have what they show.
        let pinned = MobileOfflinePins.saved()
        let wholeLibrary = MobileTextIndexChoice().wholeLibrary
        Task.detached(priority: .utility) { [textIndexer] in await textIndexer.refresh(pinned: pinned, wholeLibrary: wholeLibrary) }
        let spaces = MobileSpaceDownloads().zoneKeys
        if !spaces.isEmpty {
            Task.detached(priority: .utility) { [satellites] in await satellites.downloadSpaces(spaces) }
        }
    }

    // MARK: - The library's first arrival

    /// How often the screens hear that the library is still arriving, and read what has arrived.
    static let arrivalInterval: TimeInterval = 4

    /// The coordinator's status moved. While a round fetches a library this phone has never held whole,
    /// the screens hear `.arriving` now and every few seconds, so they say the library is still coming
    /// and show what has come; a first fetch takes minutes, and the replica is on screen from its first
    /// records. The live status is read here rather than handed over, so two calls that run out of order
    /// both act on where the round is now.
    func statusMoved() async {
        let phase = await coordinator.status.phase
        guard MobileLibraryArrival.isFetching(phase) else {
            await endArrivalReadout(phase)
            return
        }
        guard arrivalReadout == nil else { return }
        let whole = await holdsLibraryWhole()
        // Asked again: another call may have started the readout while the replica was read.
        guard !whole, arrivalReadout == nil else { return }
        announce(.arriving)
        arrivalReadout = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.arrivalInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.arrivalTick()
            }
        }
    }

    /// One beat of the readout. It ends itself when the round is over, so a readout started just as the
    /// round settled never outlives it.
    private func arrivalTick() async {
        let phase = await coordinator.status.phase
        if MobileLibraryArrival.isFetching(phase) {
            announce(.arriving)
        } else {
            await endArrivalReadout(phase)
        }
    }

    /// The round is over: the readout stops, and the screens hear that nothing is arriving any more, or
    /// that the round failed before the library was whole (the next one goes on from where this one
    /// stopped). Only a failed round reads the replica: any other end leaves nothing to say.
    private func endArrivalReadout(_ phase: SyncStatus.Phase) async {
        arrivalReadout?.cancel()
        arrivalReadout = nil
        var state = MobileLibraryArrival.settled
        if case .failed = phase {
            state = MobileLibraryArrival.state(phase: phase, heldWhole: await holdsLibraryWhole())
            // A new round began while the replica was read: its readout speaks now.
            guard arrivalReadout == nil else { return }
        }
        guard state != announced else { return }
        announce(state)
    }

    /// Says where the arrival stands, and keeps it, so a round that ends with nothing new to say is silent.
    private func announce(_ arrival: MobileLibraryArrival) {
        announced = arrival
        post(arrival)
    }

    private func holdsLibraryWhole() async -> Bool {
        do {
            return try await replica.read { try MobileLibraryArrival.holdsWhole(in: $0) }
        } catch {
            // Unknown reads as whole: a line that says "syncing" must have a fetch behind it.
            Self.logger.error("Whether the library has arrived whole could not be read: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    private nonisolated func post(_ arrival: MobileLibraryArrival) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .mobileLibraryArrivalDidChange, object: nil, userInfo: [MobileLibraryArrival.userInfoKey: arrival]
            )
        }
    }
}

/// Where the library's first arrival on this phone stands (§2.3). A first fetch of `Library` and `Catalog`
/// takes minutes and the phone shows its replica from the first records, so a list is short, and its
/// counts low, until the fetch reaches the end. iCloud hands records over oldest change first: whatever a
/// Mac rewrote last (a pass over every paper, say) arrives last. The screens say so while it lasts.
enum MobileLibraryArrival: Equatable, Sendable {
    /// A round is fetching a library this phone has never held whole.
    case arriving
    /// That round failed before the library was whole; the next round goes on.
    case interrupted
    /// The library is whole on this phone, or nothing is fetching it (no account, no root yet, a stop).
    case settled

    static let userInfoKey = "arrival"

    /// Whether a round is under way.
    static func isFetching(_ phase: SyncStatus.Phase) -> Bool {
        switch phase {
        case .starting, .syncing: return true
        default: return false
        }
    }

    static func state(phase: SyncStatus.Phase, heldWhole: Bool) -> MobileLibraryArrival {
        if heldWhole { return .settled }
        if isFetching(phase) { return .arriving }
        if case .failed = phase { return .interrupted }
        return .settled
    }

    /// Whether both zones the engine fetches have been taken to their end on this phone: each has a
    /// complete pass, which the audit after a fetch from nothing writes (`ReplicaAudit`) and a purge clears.
    static func holdsWhole(in replica: MobileReplica) throws -> Bool {
        try PrivateSyncZones.engineZones.allSatisfy {
            try replica.replica.zone(key: PrivateSyncZones.key($0))?.lastCompletePassAt != nil
        }
    }
}

extension Notification.Name {
    /// The library's first arrival moved, or is still under way: `userInfo[MobileLibraryArrival.userInfoKey]`
    /// holds the `MobileLibraryArrival`. Posted on the main actor, every few seconds while it arrives.
    static let mobileLibraryArrivalDidChange = Notification.Name("ForeverLM.mobileLibraryArrivalDidChange")
}

extension Notification.Name {
    /// The phone's replica changed after a sync round or a write the screens show: the
    /// screens' models read it again, through a `MobileReloadCoalescer`.
    static let mobileReplicaDidChange = Notification.Name("ForeverLM.mobileReplicaDidChange")
}

/// Turns a stream of "the replica changed" into at most one library reload per interval. The first change
/// after a quiet stretch reloads at once, so a learner's own edit shows without a wait; changes that
/// arrive within the interval of the last reload share one more, run when the interval is up, which reads
/// all of them. Without it every write and every settled round re-read the whole library.
@MainActor
final class MobileReloadCoalescer {
    private let interval: TimeInterval
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let reload: () async -> Void
    private var pending: Task<Void, Never>?
    private var lastStarted = Date.distantPast

    init(interval: TimeInterval = 2, now: @escaping () -> Date = { Date() },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         reload: @escaping () async -> Void) {
        self.interval = interval
        self.now = now
        self.sleep = sleep
        self.reload = reload
    }

    /// Whether a reload is waiting for its turn.
    var isWaiting: Bool { pending != nil }

    func changed() {
        // One is already due; it reads this change too.
        guard pending == nil else { return }
        let wait = max(0, lastStarted.addingTimeInterval(interval).timeIntervalSince(now()))
        pending = Task { [weak self] in
            if wait > 0 { await self?.sleep(wait) }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.lastStarted = self.now()
            await self.reload()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// This installation's sync device id (§3.5.2): 8 base32 characters, random, kept in a Keychain item
/// that stays on this device and never syncs. The replica's stamp clock names the id it minted with,
/// and is taken back when the item is missing, so the phone keeps one id for its stamps.
enum MobileSyncDeviceID {
    static let service = "com.foreverlm.sync"
    static let account = "deviceID"
    /// Reserved for migrated history (§3.5.24), never drawn.
    static let reserved = "legacy22"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func current(clockDeviceID: String?) -> String {
        if let held = read(), isUsable(held) { return held }
        let id = clockDeviceID.flatMap { isUsable($0) ? $0 : nil } ?? draw()
        save(id)
        return id
    }

    static func isUsable(_ id: String) -> Bool {
        SyncStamp.isValidDeviceID(id) && id != reserved
    }

    static func draw() -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let id = String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            if isUsable(id) { return id }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ id: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(id.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileSyncSession")
                .error("The sync device id was not saved to the Keychain (\(status)); the replica's clock keeps it")
        }
    }
}

/// The app delegate the phone needs for CloudKit pushes (D36): it registers for remote notifications
/// and hands a push of the library container to the session, with the database it came from.
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if MobileSyncSession.isEnabled {
            application.registerForRemoteNotifications()
        }
        return true
    }

    /// The phone's window scenes take accepted CloudKit shares (`MobileWindowSceneDelegate`, §9.7); every
    /// other scene, and every scene of a build with no library container, keeps the configuration it
    /// would have had.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        guard MobileSyncSession.isEnabled, connectingSceneSession.role == .windowApplication else {
            return connectingSceneSession.configuration
        }
        let configuration = UISceneConfiguration(name: connectingSceneSession.configuration.name, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MobileWindowSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileSyncSession")
            .error("Could not register for CloudKit pushes: \(error.localizedDescription, privacy: .public)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard MobileSyncSession.isEnabled,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let database = CloudKitMapping.database(of: notification),
              let session = MobileSyncSession.current,
              notification.containerIdentifier == session.containerIdentifier
        else {
            completionHandler(.noData)
            return
        }
        Task {
            await session.handlePush(from: database)
            completionHandler(.newData)
        }
    }
}

/// What the phone says about its sync (§2.5), in its own words: `SyncStatus.notice` speaks of "this Mac",
/// which never holds on an iPhone, and the phone has no "Upload my library to iCloud again" (only a Mac
/// holds a library to upload).
enum MobileSyncNotice {
    static func text(for status: SyncStatus) -> String? {
        switch status.phase {
        case .stopped(.zoneDeleted(.purged)), .stopped(.rootMissing), .stopped(.saltChanged):
            return "Your ForeverLM data was removed from iCloud. Your library on your Mac is intact; upload it again from the Mac to sync this iPhone."
        case .stopped(.zoneDeleted(.deleted)):
            return "Another of your devices removed your ForeverLM data from iCloud."
        case .stopped(.zoneDeleted(.encryptedDataReset)):
            return "Your iCloud encrypted data was reset, which removed your ForeverLM data from iCloud. Upload your library again from your Mac."
        case .stopped(.accountChanged(signedOut: true)), .noAccount:
            return "Sign in to iCloud to sync your library."
        case .stopped(.accountChanged(signedOut: false)):
            return "This iPhone's iCloud account changed. Your library was not copied to the new account."
        case .updateRequired:
            return "Update ForeverLM to keep syncing your library."
        case .failed(let reason):
            return "The last sync with iCloud failed: \(reason) ForeverLM will try again."
        default:
            guard case .quotaExceeded(let owner)? = status.pause else { return nil }
            return ShareService.quotaNotice(owner: owner)
        }
    }
}

/// The lines Settings shows about the library's sync: whatever stops it. Read again after every round of
/// the session.
@MainActor
final class MobileLibrarySyncStatusModel: ObservableObject {
    static let shared = MobileLibrarySyncStatusModel()

    @Published private(set) var lines: [String] = []
    private var observer: NSObjectProtocol?

    init() {
        guard MobileSyncSession.isEnabled else { return }
        observer = NotificationCenter.default.addObserver(forName: .mobileReplicaDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    func reload() async {
        var next: [String] = []
        if let session = MobileSyncSession.current, let line = MobileSyncNotice.text(for: await session.coordinator.status) {
            next.append(line)
        }
        if next != lines { lines = next }
    }
}
