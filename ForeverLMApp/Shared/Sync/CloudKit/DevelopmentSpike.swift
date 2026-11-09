#if DEBUG
import CloudKit
import Foundation
import OSLog

/// WP5's Development spike (docs/cloudkit-schema-design.md §2.3, R3): proves on the library
/// container's real Development environment that a CKSyncEngine scoped to `.zoneIDs([Library,
/// Catalog])` coexists with plain operations on the same private database and never fetches a space
/// zone. Debug builds only, and only when launched with `--schema-v2-spike` and
/// `FOREVERLM_SYNC_GENERATION=2` in the environment; it never opens `knowledge.db` (its replica is
/// a file of its own in the temporary folder) and touches nothing generation 1 reads. Its log is in
/// Console.app, subsystem the app's bundle id, category `SchemaV2Spike`; the last line is `SPIKE PASS`
/// or `SPIKE FAIL: <why>`.
///
/// What it does: names records with the Development root's salt when there is a root, and otherwise
/// makes only the zones it needs and a throwaway salt (it never creates a root, so a later bootstrap
/// or rehearsal finds the environment as it was); saves one test-only Setting (`spike.<run>`) into
/// `Library` and one into a new `Space-<uuid>` zone with plain operations; starts a CKSyncEngine with
/// no saved state; and fetches while another plain save goes to the space. It passes when the engine
/// delivered the `Library` Setting and nothing from the space zone. Afterwards it deletes the
/// Setting, the space zone, and any private zone it made.
///
/// WP6's share spike (`--schema-v2-share-spike`, same environment and log) proves C8: a Dev build makes
/// a test space as `SpaceService` will (a `Space-<uuid>` zone and a root with a fresh salt, saved by
/// compare-and-set create), SpaceSync walks it, and ShareService saves its zone-wide CKShare, which
/// materializes the `cloudkit.share` record type in the Development schema. It reads the share back by
/// name and passes when CloudKit holds it as `cloudkit.share` with a link and this account as owner.
/// Its replica is in memory; afterwards it stops sharing and deletes the zone. The type stays.
enum DevelopmentSpike {
    static let argument = "--schema-v2-spike"
    static let shareArgument = "--schema-v2-share-spike"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SchemaV2Spike")

    static var isRequested: Bool { isRequested(argument) }

    private static func isRequested(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
            && ProcessInfo.processInfo.environment["FOREVERLM_SYNC_GENERATION"] == "2"
    }

    static func runIfRequested() {
        let engine = isRequested(argument)
        let share = isRequested(shareArgument)
        guard engine || share else { return }
        guard let container = ForeverLMRuntimeIdentity.libraryContainerIdentifier else {
            logger.error("SPIKE FAIL: this build names no library container")
            return
        }
        Task.detached(priority: .utility) {
            do {
                if engine { try await run(containerIdentifier: container) }
                if share { try await runShare(containerIdentifier: container) }
            } catch {
                logger.error("SPIKE FAIL: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// C8: a test space, walked, shared, read back, unshared and deleted.
    private static func runShare(containerIdentifier: String) async throws {
        let run = UUID().uuidString.lowercased()
        logger.info("Share spike \(run, privacy: .public) on \(containerIdentifier, privacy: .public)")
        let transport = CloudKitTransport(containerIdentifier: containerIdentifier)
        guard try await transport.accountStatus() == .available else { throw CloudError(.notAuthenticated, message: "no iCloud account") }
        let user = try await transport.userRecordName()

        let connection = try SQLiteHandle(path: ":memory:")
        try ReplicaStore(connection: connection).installSharedSchema()
        let store = ReplicaOnlySyncStore(connection: connection)
        let pacers: @Sendable (CloudDatabaseScope) async -> SyncPacer = { await SyncPacer.shared(container: containerIdentifier, database: $0) }
        let spaces = SpaceSync(transport: transport, store: store, moveMaps: MoveMapIndex(), deviceID: "spikeaaa", pacer: pacers)
        let shares = ShareService(transport: transport, store: store, spaces: spaces, accountName: "Share spike")

        let zoneID = CloudZoneID("Space-\(run)")
        _ = try await transport.modifyZones(saving: [zoneID], deleting: [], in: .private)
        defer { Task.detached { _ = try? await transport.modifyZones(saving: [], deleting: [zoneID], in: .private) } }
        let now = SyncTime.milliseconds(Date())
        let root = try ShareService.spaceRoot(kind: "team", name: "Share spike \(run.prefix(8))", owner: SyncPerson(user: user, name: "Share spike"),
                                              primaryID: nil, salt: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }), at: now) { policy, _ in
            SyncStamp.provisional(policy, deviceID: "spikeaaa")
        }
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: zoneID)
        let created = try await transport.modifyRecords(saving: [CloudRecord(id: rootID, recordType: SyncRecordType.zoneRoot.rawValue,
                                                                             encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])],
                                                        in: .private)
        if let error = created.error(for: rootID) { throw error }

        // SpaceSync finds the space in the private database and adopts its root.
        let zone = SpaceZone(zoneID, in: .private)
        guard try await spaces.refreshZones().contains(zone) else { throw CloudError(.zoneNotFound, message: "the zone list did not name the space") }
        try await spaces.walk(zone)
        guard try await store.perform({ try $0.replica.zone(key: zone.zoneKey)?.saltID }) == root.saltID else {
            throw CloudError(.internalError, message: "the walk did not adopt the space's root")
        }

        let shared = try await shares.share(zone, title: "ForeverLM share spike", publicPermission: CloudShare.Permission.none)
        let shareID = CloudRecordID(CloudRecordID.zoneShareRecordName, in: zoneID)
        let readBack = try await transport.record(shareID, in: .private, desiredKeys: nil).get()
        let roster = try await shares.roster(of: zone)
        try await shares.stopSharing(zone)
        logger.info("The share was saved as \(readBack.recordType, privacy: .public) with \(roster.members.count) on its roster")
        if readBack.recordType != CloudRecordID.shareRecordType {
            logger.error("SPIKE FAIL: the zone-wide share is a \(readBack.recordType, privacy: .public), not cloudkit.share")
        } else if shared.url == nil || readBack.share?.url == nil {
            logger.error("SPIKE FAIL: the share has no link")
        } else if roster.members.first?.isOwner != true || roster.members.first?.person.user != user {
            logger.error("SPIKE FAIL: the roster does not start with this account as owner")
        } else {
            logger.info("SHARE SPIKE PASS")
        }
    }

    /// Collects what CKSyncEngine delivers.
    private final class Collector: CKSyncEngineDelegate, @unchecked Sendable {
        let lock = NSLock()
        var zones: Set<String> = []
        var recordNames: Set<String> = []

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            guard case .fetchedRecordZoneChanges(let changes) = event else { return }
            lock.withLock {
                for modification in changes.modifications {
                    zones.insert(modification.record.recordID.zoneID.zoneName)
                    recordNames.insert(modification.record.recordID.recordName)
                }
            }
        }

        func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
            nil
        }

        func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
            PrivateEngineDelegate.fetchOptions
        }
    }

    private static func run(containerIdentifier: String) async throws {
        let run = UUID().uuidString.lowercased()
        logger.info("Spike \(run, privacy: .public) on \(containerIdentifier, privacy: .public)")
        let container = CKContainer(identifier: containerIdentifier)
        let transport = CloudKitTransport(container: container)
        guard try await transport.accountStatus() == .available else { throw CloudError(.notAuthenticated, message: "no iCloud account") }

        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: PrivateSyncZones.library)
        var salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var madeZones: [CloudZoneID] = []
        if case .success(let root) = try await transport.record(rootID, in: .private, desiredKeys: [CloudRecord.payloadKey]),
           let payload = root.payload, let held = try? SyncEnvelope(storedPayload: payload),
           let rootSalt = held.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:)) {
            salt = rootSalt
            logger.info("Using the Development root's salt")
        } else {
            let existing = Set(try await transport.allZones(in: .private))
            madeZones = PrivateSyncZones.engineZones.filter { !existing.contains($0) }
            _ = try await transport.modifyZones(saving: madeZones, deleting: [], in: .private)
            logger.info("No Development root: made \(madeZones.count) zones and a throwaway salt")
        }

        // One test-only Setting in Library, one in a space zone of its own, by plain operations.
        let key = "spike.\(run)"
        let space = CloudZoneID("Space-\(run)")
        _ = try await transport.modifyZones(saving: [space], deleting: [], in: .private)
        let libraryRecord = try setting(key, value: "library", zone: PrivateSyncZones.library, salt: salt)
        let spaceSalt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let spaceRecord = try setting(key, value: "space", zone: space, salt: spaceSalt)
        _ = try await transport.modifyRecords(saving: [libraryRecord, spaceRecord], in: .private)
        defer {
            let zones = [space] + madeZones
            Task.detached { _ = try? await transport.modifyZones(saving: [], deleting: zones, in: .private) }
        }

        // A CKSyncEngine with no saved state, scoped to the engine's zones, fetching while another
        // plain save goes to the same database.
        let collector = Collector()
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: nil, delegate: collector)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        async let fetched: Void = engine.fetchChanges(PrivateEngineDelegate.fetchOptions)
        let concurrent = try setting(key + ".concurrent", value: "space", zone: space, salt: spaceSalt)
        _ = try await transport.modifyRecords(saving: [concurrent], in: .private)
        try await fetched

        let (zones, names) = collector.lock.withLock { (collector.zones, collector.recordNames) }
        logger.info("CKSyncEngine fetched zones \(zones.sorted().joined(separator: ","), privacy: .public)")
        if zones.contains(space.zoneName) {
            logger.error("SPIKE FAIL: CKSyncEngine fetched the space zone")
        } else if !names.contains(libraryRecord.id.recordName) {
            logger.error("SPIKE FAIL: CKSyncEngine did not deliver the Library Setting")
        } else {
            logger.info("SPIKE PASS")
        }
        _ = try? await transport.modifyRecords(deleting: [libraryRecord.id], in: .private)
    }

    private static func setting(_ key: String, value: String, zone: CloudZoneID, salt: Data) throws -> CloudRecord {
        var envelope = SyncEnvelope.new(.setting, id: key, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(.setting, id: key)
        patch.changes["key"] = .value(.string(key))
        patch.changes["value"] = .value(.string(value))
        patch.changes["editedAt"] = .value(SyncJSON(SyncTime.milliseconds(Date())))
        try envelope.apply(patch) { _, policy, _ in SyncStamp.provisional(policy, deviceID: "spikeaaa") }
        return CloudRecord(
            id: CloudRecordID(RecordNaming.recordName(type: .setting, id: key, salt: salt), in: zone),
            recordType: SyncRecordType.setting.rawValue,
            encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())]
        )
    }
}
#endif
