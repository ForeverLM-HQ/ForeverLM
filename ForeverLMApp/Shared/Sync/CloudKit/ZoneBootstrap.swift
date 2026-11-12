import CloudKit
import Foundation
import OSLog

/// The private library's root and salt (docs/cloudkit-schema-design.md §2.4), run before the private
/// engine sends anything: the only code that creates a private zone.
///
/// 1. `root` is read from `Library` by name. When it exists it is adopted: its salt names every record
///    of `Library`, `Catalog` and `Content`, and the device writes a `ck_zones` row for each zone with
///    the root's `saltID`.
/// 2. When it does not, a device that held a root before (a `ck_zones` row with a salt) is purged
///    (§2.5): `PurgeHandler` takes over and nothing is created. So is a device whose held salt is not
///    the root's any more.
/// 3. Otherwise the device makes the root, by a compare-and-set create with a fresh 32-byte salt, after
///    saving the three zones (idempotent). Losing the race adopts the winner's root. What the root says
///    depends on the client: a Mac that holds the library starts seeding and claims the seed lease and
///    the maintenance lease in the same save; a client that holds none creates the root only when the
///    new container has no zone yet (or only the ones it made itself), with the empty complete seed
///    of a brand-new account.
///
/// A device that has no server offset yet takes its first one from the root save; one that adopted a
/// root re-saves it unchanged (a compare-and-set update that moves only the change tag) to learn it,
/// since no stamp may be minted before it (§6.3). The stamps of a root this device creates before it
/// knows its offset are provisional (millisecond 1), so every later writer of a field beats them.
struct ZoneBootstrap {
    /// The seed lease a Mac claims with the root it creates (§13.4 step 1).
    static let seedLease: TimeInterval = 30 * 60
    /// The maintenance lease (§3.5.1): 24 hours, renewed by its holder. The seeder takes it with its
    /// claim, in the same save (§13.4 step 1).
    static let maintenanceLease: TimeInterval = 24 * 3_600

    enum Client: Equatable, Sendable {
        /// A Mac whose store holds the library (a `full` activation, a `deferred` one whose catch-up
        /// ran, or a `fresh` one the learner confirmed): it creates the root `seeding` and claims the
        /// seed in the same save.
        case macHoldingLibrary
        /// A Mac that holds no library, or one whose library waits for "This Mac holds my library".
        case macWithoutLibrary
        /// An iPhone or iPad: it only ever writes the empty complete seed.
        case phone
    }

    enum Waiting: Equatable, Sendable {
        /// The new container has zones but no root yet: another device is making it.
        case zonesWithoutRoot
    }

    enum Outcome: Equatable, Sendable {
        /// The account's root was there; this device holds it now.
        case adopted(saltID: String)
        /// This device made the root.
        case created(saltID: String)
        /// The device held a root and the zone or root is gone, or names another salt (§2.5).
        case purged(PurgeHandler.Event)
        /// Nothing created; try again later.
        case waiting(Waiting)
        /// The root asks for a newer client than this build (§12.5): nothing is sent until an update.
        case updateRequired(minClientRevision: Int)
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ZoneBootstrap")

    let transport: CloudTransport
    let store: PrivateSyncLocalStore
    let client: Client
    let deviceID: String
    var now: @Sendable () -> Date = { Date() }
    /// "Production" or "Development": the half of the container's identity its name does not carry.
    var containerEnvironment = ""
    /// The fresh salt of a root this device creates (32 random bytes; a test passes its own).
    var makeSalt: @Sendable () -> Data = {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: - The run

    func run() async throws -> Outcome {
        let outcome = try await perform()
        switch outcome {
        case .adopted, .created:
            let binding = Data(containerBinding.utf8)
            try await store.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.containerBinding, binding) }
        default:
            break
        }
        return outcome
    }

    private var containerBinding: String { "\(transport.containerIdentifier)|\(containerEnvironment)" }

    /// Whether the zones and salt this replica holds describe another container, environment or iCloud
    /// account than the one the transport reads now. A moved Apple team, a new container or a switch
    /// between Development and Production all look like a missing root; none of them is a purge, and a
    /// device that read one as a purge stopped syncing for good (a Mac moved to another team held the
    /// old container's salt, found no root in the new one and showed "removed from iCloud").
    private func holdsForeignState() async throws -> Bool {
        let (binding, account) = try await store.perform { state in
            (try state.replica.engineState(ReplicaStore.EngineScope.containerBinding),
             try state.replica.engineState(ReplicaStore.EngineScope.account))
        }
        if let binding, String(decoding: binding, as: UTF8.self) != containerBinding { return true }
        // A user record name is scoped to its container, so it also tells a replica written before
        // the binding existed.
        if let account, String(decoding: account, as: UTF8.self) != (try await transport.userRecordName()) { return true }
        return false
    }

    private func perform() async throws -> Outcome {
        var held = try await store.perform { try $0.replica.zone(key: PrivateSyncZones.libraryKey)?.saltID }
        if held != nil, try await holdsForeignState() {
            Self.logger.notice("The replica describes another container or account; starting as a device that holds no root")
            try await store.perform { try PurgeHandler.reupload(in: $0) }
            held = nil
        }
        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: PrivateSyncZones.library)
        switch try await transport.record(rootID, in: .private, desiredKeys: [CloudRecord.payloadKey]) {
        case .success(let root):
            return try await adopt(root, held: held)
        case .failure(let error) where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code):
            if held != nil {
                return .purged(error.code == .userDeletedZone ? .zoneDeleted(reason: .purged) : .rootMissing)
            }
            return try await create()
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Adopting

    private func adopt(_ root: CloudRecord, held: String?) async throws -> Outcome {
        guard let payload = root.payload, let envelope = try? SyncEnvelope(storedPayload: payload),
              let saltID = envelope.fields["saltID"]?.stringValue,
              let salt = envelope.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:)),
              RecordNaming.saltID(salt) == saltID
        else { throw CloudError(.invalidArguments, message: "the library's root carries no salt this build reads") }
        if let held, held != saltID {
            return .purged(.saltChanged)
        }
        try await hold(root, saltID: saltID)
        if let minimum = envelope.fields["minClientRevision"]?.intValue, minimum > SyncSchema.schemaRevision {
            return .updateRequired(minClientRevision: minimum)
        }
        try await learnServerOffset(from: root)
        return .adopted(saltID: saltID)
    }

    /// Writes the root into the replica and a `ck_zones` row for each private zone, keeping what the
    /// rows already hold (tokens, passes).
    private func hold(_ root: CloudRecord, saltID: String) async throws {
        try await store.perform { state in
            let replica = state.replica
            try replica.upsertRecord(ReplicaRecord(
                zoneKey: PrivateSyncZones.libraryKey, recordName: SyncSchema.rootRecordName,
                recordType: SyncRecordType.zoneRoot.rawValue, wireID: SyncSchema.rootRecordName,
                systemFields: root.systemFields, payload: root.payload ?? Data(), seenPass: nil
            ))
            for zone in PrivateSyncZones.all {
                var row = try replica.zone(key: PrivateSyncZones.key(zone)) ?? ReplicaZone(
                    zoneKey: PrivateSyncZones.key(zone), database: .private, zoneName: zone.zoneName, kind: PrivateSyncZones.kind(zone)
                )
                row.saltID = saltID
                try replica.upsertZone(row)
            }
            try replica.setEngineState(ReplicaStore.EngineScope.zonesCreated, nil)
        }
    }

    /// A device with no server offset re-saves the root it holds, unchanged, and takes the server's
    /// date of that save as its first sample (§6.3). Another device's save in between is adopted and
    /// the probe tried once more.
    private func learnServerOffset(from root: CloudRecord) async throws {
        var current = root
        for _ in 0..<2 {
            guard try await store.perform({ try $0.replica.loadClock()?.serverOffset }) == nil else { return }
            let sentAt = now()
            let probe = CloudRecord(id: current.id, recordType: current.recordType, encryptedFields: current.encryptedFields,
                                    systemFields: current.systemFields)
            let result = try await transport.modifyRecords(saving: [probe], in: .private)
            if let saved = result.savedRecord(current.id) {
                try await recordServerTime(saved, sentAt: sentAt)
                try await hold(saved, saltID: try await heldSaltID())
                return
            }
            guard let error = result.error(for: current.id), error.code == .serverRecordChanged, let server = error.serverRecord else {
                throw result.error(for: current.id) ?? CloudError(.internalError, message: "no result for the root")
            }
            current = server
        }
    }

    private func heldSaltID() async throws -> String {
        guard let saltID = try await store.perform({ try $0.replica.zone(key: PrivateSyncZones.libraryKey)?.saltID }) else {
            throw CloudError(.internalError, message: "no salt held")
        }
        return saltID
    }

    private func recordServerTime(_ record: CloudRecord, sentAt: Date) async throws {
        guard let serverTime = record.modificationDate else { return }
        let deviceID = deviceID
        try await store.perform { try $0.replica.recordServerTime(serverTime, sentAt: sentAt, deviceID: deviceID) }
    }

    // MARK: - Creating

    private func create() async throws -> Outcome {
        var seed: [String: SyncJSON]
        var claim: SyncJSON?
        var maintenance: SyncJSON?
        let at = now()
        switch client {
        case .macHoldingLibrary:
            seed = ["state": .string("seeding"), "startedAt": SyncJSON(SyncTime.milliseconds(at))]
            claim = .object(["device": .string(deviceID), "leaseUntil": SyncJSON(SyncTime.milliseconds(at.addingTimeInterval(Self.seedLease)))])
            maintenance = .object(["device": .string(deviceID), "leaseUntil": SyncJSON(SyncTime.milliseconds(at.addingTimeInterval(Self.maintenanceLease)))])
        case .macWithoutLibrary, .phone:
            guard try await canCreateWithoutLibrary() else { return .waiting(.zonesWithoutRoot) }
            let ms = SyncJSON(SyncTime.milliseconds(at))
            seed = [
                "state": .string("complete"), "startedAt": ms, "canaryPassedAt": ms, "metadataCompleteAt": ms, "completedAt": ms,
                "counts": .object(["records": SyncJSON(0), "satellites": SyncJSON(0), "bytes": SyncJSON(0)]),
            ]
        }

        let zoneResults = try await transport.modifyZones(saving: PrivateSyncZones.all, deleting: [], in: .private)
        for zone in PrivateSyncZones.all {
            if case .failure(let error)? = zoneResults.saved[zone] { throw error }
        }
        try await store.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.zonesCreated, Data("\(at.timeIntervalSinceReferenceDate)".utf8), now: at) }

        let salt = makeSalt()
        let saltID = RecordNaming.saltID(salt)
        let milliseconds = SyncJSON(SyncTime.milliseconds(at))
        var envelope = SyncEnvelope.new(.zoneRoot, id: SyncSchema.rootRecordName, saltID: saltID)
        var patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        patch.changes["kind"] = .value(.string("personal"))
        patch.changes["salt"] = .value(.string(salt.base64EncodedString()))
        patch.changes["saltID"] = .value(.string(saltID))
        patch.changes["createdAt"] = .value(milliseconds)
        patch.changes["editedAt"] = .value(milliseconds)
        patch.changes["minClientRevision"] = .value(SyncJSON(1))
        patch.changes["seed"] = .elements(seed)
        if let claim { patch.changes["seedClaim"] = .value(claim) }
        if let maintenance { patch.changes["maintenanceLease"] = .value(maintenance) }
        let clock = try await store.perform { try $0.replica.loadClock() }
        var minting = clock
        let deviceID = deviceID
        try envelope.apply(patch) { _, policy, seen in
            if var clock = minting, let stamp = clock.mint(policy, eventTime: SyncTime.milliseconds(at), seen: seen, now: SyncTime.milliseconds(at)) {
                minting = clock
                return stamp
            }
            return SyncStamp.provisional(policy, deviceID: deviceID)
        }
        if let minting, minting != clock { try await store.perform { try $0.replica.saveClock(minting, now: at) } }

        let rootID = CloudRecordID(SyncSchema.rootRecordName, in: PrivateSyncZones.library)
        let record = CloudRecord(id: rootID, recordType: SyncRecordType.zoneRoot.rawValue,
                                 encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])
        let sentAt = now()
        let result = try await transport.modifyRecords(saving: [record], in: .private)
        if let saved = result.savedRecord(rootID) {
            try await hold(saved, saltID: saltID)
            try await recordServerTime(saved, sentAt: sentAt)
            Self.logger.info("Created the library's root (\(String(describing: client), privacy: .public))")
            return .created(saltID: saltID)
        }
        guard let error = result.error(for: rootID) else { throw CloudError(.internalError, message: "no result for the root") }
        guard error.code == .serverRecordChanged, let winner = error.serverRecord else { throw error }
        // Another device made the root first: ours is discarded and nothing was named with its salt.
        return try await adopt(winner, held: nil)
    }

    /// A client holding no library creates the root only when the new container has no zone yet, or
    /// only the zones this device created itself before its root save went through.
    private func canCreateWithoutLibrary() async throws -> Bool {
        let zones = try await transport.allZones(in: .private).filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
        guard !zones.isEmpty else { return true }
        let createdHere = try await store.perform { try $0.replica.engineState(ReplicaStore.EngineScope.zonesCreated) } != nil
        return createdHere && zones.allSatisfy { PrivateSyncZones.all.contains($0) }
    }
}
