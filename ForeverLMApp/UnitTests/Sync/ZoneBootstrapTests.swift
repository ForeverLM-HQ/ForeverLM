import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The private library's root and salt (docs/cloudkit-schema-design.md §2.4), on FakeCloudKit and a
/// replica-only store.
@Suite("Zone bootstrap")
struct ZoneBootstrapTests {
    static let user = "alice"

    /// A device: its transports to both containers and its own replica.
    struct Device {
        let transport: FakeCloudKit.Transport
        let store: ReplicaOnlySyncStore

        init(_ server: FakeCloudKit, name: String, user: String = ZoneBootstrapTests.user) throws {
            transport = server.transport(user: user, device: name)
            let connection = try SQLiteHandle(path: ":memory:")
            store = ReplicaOnlySyncStore(connection: connection)
            try ReplicaStore(connection: connection).installSharedSchema()
        }

        func bootstrap(_ client: ZoneBootstrap.Client, salt: UInt8 = 1, server: FakeCloudKit,
                       transport: CloudTransport? = nil) -> ZoneBootstrap {
            var bootstrap = ZoneBootstrap(transport: transport ?? self.transport,
                                          store: store, client: client, deviceID: "macaaaaa")
            bootstrap.now = { server.now }
            bootstrap.makeSalt = { Data(repeating: salt, count: 32) }
            return bootstrap
        }

        func zone(_ name: String) async throws -> ReplicaZone? {
            try await store.perform { try $0.replica.zone(key: ReplicaZone.key(database: .private, zoneName: name)) }
        }

        func clock() async throws -> StampClock? {
            try await store.perform { try $0.replica.loadClock() }
        }
    }

    static func serverRoot(_ server: FakeCloudKit) throws -> SyncEnvelope? {
        guard let record = server.storedRecord("root", zone: "Library", owner: user), let payload = record.payload else { return nil }
        return try SyncEnvelope(storedPayload: payload)
    }

    static func seed(_ root: SyncEnvelope?) -> [String: SyncJSON] {
        root?.fields["seed"]?.objectValue ?? [:]
    }

    /// Passes calls through to a transport, and runs `beforeSave` once, just before the first record save.
    final class RacingTransport: CloudTransport, @unchecked Sendable {
        let inner: CloudTransport
        var beforeSave: (() async throws -> Void)?

        init(_ inner: CloudTransport, beforeSave: @escaping () async throws -> Void) {
            self.inner = inner
            self.beforeSave = beforeSave
        }

        var containerIdentifier: String { inner.containerIdentifier }
        func accountStatus() async throws -> CKAccountStatus { try await inner.accountStatus() }
        func userRecordName() async throws -> String { try await inner.userRecordName() }
        func allZones(in database: CloudDatabaseScope) async throws -> [CloudZoneID] { try await inner.allZones(in: database) }
        func modifyZones(saving: [CloudZoneID], deleting: [CloudZoneID], in database: CloudDatabaseScope) async throws -> CloudZoneModifyResults {
            try await inner.modifyZones(saving: saving, deleting: deleting, in: database)
        }
        func databaseChanges(in database: CloudDatabaseScope, since token: CloudChangeToken?, resultsLimit: Int?) async throws -> CloudDatabaseChanges {
            try await inner.databaseChanges(in: database, since: token, resultsLimit: resultsLimit)
        }
        func zoneChanges(_ requests: [CloudZoneChangesRequest], in database: CloudDatabaseScope) async throws -> [CloudZoneID: Result<CloudZoneChanges, CloudError>] {
            try await inner.zoneChanges(requests, in: database)
        }
        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            try await inner.records(ids, in: database, desiredKeys: desiredKeys)
        }
        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                           savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            if !saving.isEmpty, let hook = beforeSave {
                beforeSave = nil
                try await hook()
            }
            return try await inner.modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: savePolicy, atomically: atomically)
        }
    }

    @Test("The salt race: the loser adopts the winner's root and names nothing with its own salt")
    func saltRace() async throws {
        let server = FakeCloudKit()
        let winner = try Device(server, name: "mac-b")
        let loser = try Device(server, name: "mac-a")
        var winnerOutcome: ZoneBootstrap.Outcome?
        let racing = RacingTransport(loser.transport) {
            winnerOutcome = try await winner.bootstrap(.macHoldingLibrary, salt: 2, server: server).run()
        }
        let outcome = try await loser.bootstrap(.macHoldingLibrary, salt: 1, server: server, transport: racing).run()

        let winnerSaltID = RecordNaming.saltID(Data(repeating: 2, count: 32))
        #expect(winnerOutcome == .created(saltID: winnerSaltID))
        #expect(outcome == .adopted(saltID: winnerSaltID))
        #expect(try Self.serverRoot(server)?.fields["saltID"]?.stringValue == winnerSaltID)
        for zone in ["Library", "Catalog", "Content"] {
            #expect(try await loser.zone(zone)?.saltID == winnerSaltID, "the loser's \(zone) row names the winner's salt")
        }
        #expect(try await loser.store.perform { try $0.replica.personalRoot()?.envelope.fields["saltID"]?.stringValue } == winnerSaltID)
        #expect(server.recordNames(zone: "Library", owner: Self.user) == ["root"])
        #expect(try await loser.clock()?.serverOffset != nil, "the loser learned its offset from re-saving the root it adopted")
    }

    @Test("The root this device makes carries the salt and its saltID, and every private zone's row names it")
    func saltIDWritten() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        let outcome = try await mac.bootstrap(.macHoldingLibrary, salt: 7, server: server).run()
        let salt = Data(repeating: 7, count: 32)
        #expect(outcome == .created(saltID: RecordNaming.saltID(salt)))
        let root = try #require(try Self.serverRoot(server))
        #expect(root.saltID == RecordNaming.saltID(salt))
        #expect(root.fields["salt"]?.stringValue == salt.base64EncodedString())
        #expect(root.fields["saltID"]?.stringValue == RecordNaming.saltID(salt))
        #expect(root.fields["kind"]?.stringValue == "personal")
        #expect(Self.seed(root)["state"] == .string("seeding"))
        #expect(root.fields["seedClaim"]?["device"]?.stringValue == "macaaaaa")
        #expect(Set(server.zoneNames(owner: Self.user)).isSuperset(of: ["Library", "Catalog", "Content"]))
        for zone in ["Library", "Catalog", "Content"] {
            #expect(try await mac.zone(zone)?.saltID == RecordNaming.saltID(salt))
        }
        #expect(try await mac.clock()?.serverOffset != nil, "the root's save gave the first server offset")
        // Stamped provisionally: the device had no offset when it made the root.
        if case .value(let stamp)? = root.stamps["kind"] { #expect(stamp.milliseconds == 1) } else { Issue.record("no stamp") }
    }

    @Test("A device that held a root never creates a zone again: a missing root or zone is a purge")
    func heldRootNeverRecreated() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, server: server).run()
        server.deleteZone("Library", owner: Self.user, reason: .deleted)
        server.resetCalls()
        #expect(try await mac.bootstrap(.macHoldingLibrary, server: server).run() == .purged(.rootMissing))
        #expect(!server.zoneNames(owner: Self.user).contains("Library"))
        #expect(!server.calls.contains { $0.operation == .modifyZones || $0.operation == .modifyRecords })

        server.deleteZone("Catalog", owner: Self.user, reason: .purged)
        _ = server.put([], zone: "Library", owner: Self.user)
        #expect(try await mac.bootstrap(.macHoldingLibrary, server: server).run() == .purged(.rootMissing))
        #expect(!server.calls.contains { $0.operation == .modifyZones || $0.operation == .modifyRecords })
    }

    @Test("A root with another salt than the one held is a purge, not an adoption")
    func otherSaltIsPurge() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        let other = try Device(server, name: "other")
        _ = try await mac.bootstrap(.macHoldingLibrary, salt: 3, server: server).run()
        server.deleteZone("Library", owner: Self.user, reason: .purged)
        #expect(try await other.bootstrap(.macHoldingLibrary, salt: 4, server: server).run() == .created(saltID: RecordNaming.saltID(Data(repeating: 4, count: 32))))
        #expect(try await mac.bootstrap(.macHoldingLibrary, server: server).run() == .purged(.saltChanged))
        #expect(try await mac.zone("Library")?.saltID == RecordNaming.saltID(Data(repeating: 3, count: 32)))
    }

    @Test("A replica written in another container is not a purge: the root is made in the new one")
    func otherContainerIsNotPurge() async throws {
        let first = FakeCloudKit()
        let second = FakeCloudKit()
        let mac = try Device(first, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, salt: 3, server: first).run()
        // The same Apple Account, an empty container of another team: the replica's salt names nothing there.
        let moved = second.transport(user: Self.user, container: "iCloud.com.example.company", device: "mac")
        let outcome = try await mac.bootstrap(.macHoldingLibrary, salt: 5, server: second, transport: moved).run()
        #expect(outcome == .created(saltID: RecordNaming.saltID(Data(repeating: 5, count: 32))))
        #expect(try await mac.zone("Library")?.saltID == RecordNaming.saltID(Data(repeating: 5, count: 32)))
    }

    @Test("A replica from before the container binding, written for another account's user record, is not a purge either")
    func otherAccountRecordIsNotPurge() async throws {
        let first = FakeCloudKit()
        let second = FakeCloudKit()
        let mac = try Device(first, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, salt: 3, server: first).run()
        try await mac.store.perform { state in
            try state.replica.setEngineState(ReplicaStore.EngineScope.containerBinding, nil)
            try state.replica.setEngineState(ReplicaStore.EngineScope.account, Data("_oldcontaineruser".utf8))
        }
        let outcome = try await mac.bootstrap(.macHoldingLibrary, salt: 5, server: second,
                                              transport: second.transport(user: Self.user, device: "mac")).run()
        #expect(outcome == .created(saltID: RecordNaming.saltID(Data(repeating: 5, count: 32))))
    }

    @Test("In the same container a missing root is still a purge once the binding is written")
    func sameContainerStaysPurge() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, server: server).run()
        let bound = try await mac.store.perform { try $0.replica.engineState(ReplicaStore.EngineScope.containerBinding) }
        #expect(bound == Data("\(FakeCloudKit.libraryContainer)|".utf8))
        server.deleteZone("Library", owner: Self.user, reason: .purged)
        #expect(try await mac.bootstrap(.macHoldingLibrary, server: server).run() == .purged(.zoneDeleted(reason: .purged)))
    }

    @Test("A Mac with no library writes the empty complete seed and never claims the seed")
    func macWithoutLibrary() async throws {
        let newServer = FakeCloudKit()
        let fresh = try Device(newServer, name: "mac")
        _ = try await fresh.bootstrap(.macWithoutLibrary, server: newServer).run()
        #expect(try Self.serverRoot(newServer)?.fields["seedClaim"] == nil, "a Mac holding no library never claims the seed")
        let seed = Self.seed(try Self.serverRoot(newServer))
        #expect(seed["state"] == .string("complete"))
        #expect(seed["metadataCompleteAt"]?.numberValue != nil)
        #expect(seed["completedAt"]?.numberValue != nil)
        #expect(seed["counts"] == .object(["records": SyncJSON(0), "satellites": SyncJSON(0), "bytes": SyncJSON(0)]))
    }

    @Test("An iPhone writes only the empty complete seed")
    func phone() async throws {
        let newServer = FakeCloudKit()
        let fresh = try Device(newServer, name: "phone")
        _ = try await fresh.bootstrap(.phone, server: newServer).run()
        #expect(Self.seed(try Self.serverRoot(newServer))["state"] == .string("complete"))
    }

    @Test("A client holding no library waits while another device's zones have no root yet, but finishes what it started itself")
    func zonesWithoutRoot() async throws {
        let server = FakeCloudKit()
        let other = try Device(server, name: "other")
        _ = try await other.transport.modifyZones(saving: PrivateSyncZones.all, deleting: [], in: .private)
        let phone = try Device(server, name: "phone")
        #expect(try await phone.bootstrap(.phone, server: server).run() == .waiting(.zonesWithoutRoot))

        // The phone's own root save failed after it made the zones: it picks up where it stopped.
        let alone = FakeCloudKit()
        let mac = try Device(alone, name: "mac")
        alone.failNext(.modifyRecords, with: CloudError(.networkFailure))
        await #expect(throws: CloudError.self) { _ = try await mac.bootstrap(.macWithoutLibrary, server: alone).run() }
        #expect(alone.recordNames(zone: "Library", owner: Self.user).isEmpty)
        #expect(try await mac.bootstrap(.macWithoutLibrary, server: alone).run() == .created(saltID: RecordNaming.saltID(Data(repeating: 1, count: 32))))
    }

    @Test("Adopting a root re-saves it once to learn the server offset; a root asking for a newer client stops here")
    func adoptAndGate() async throws {
        let server = FakeCloudKit()
        let first = try Device(server, name: "first")
        _ = try await first.bootstrap(.macHoldingLibrary, server: server).run()
        let second = try Device(server, name: "second")
        server.advance(by: 30)
        server.resetCalls()
        #expect(try await second.bootstrap(.macWithoutLibrary, server: server).run() == .adopted(saltID: RecordNaming.saltID(Data(repeating: 1, count: 32))))
        #expect(server.calls.filter { $0.operation == .modifyRecords }.count == 1)
        #expect(try await second.clock()?.serverOffset != nil)
        server.resetCalls()
        _ = try await second.bootstrap(.macWithoutLibrary, server: server).run()
        #expect(!server.calls.contains { $0.operation == .modifyRecords }, "a device with an offset does not probe again")

        // A newer build raised minClientRevision.
        var root = try #require(try Self.serverRoot(server))
        var patch = RecordPatch(.zoneRoot, id: "root")
        patch.changes["minClientRevision"] = .value(SyncJSON(SyncSchema.schemaRevision + 1))
        try root.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: 1_900_000_000_000, counter: 0, deviceID: "newerbld") }
        let held = try #require(server.storedRecord("root", zone: "Library", owner: Self.user))
        _ = server.put([CloudRecord(id: held.id, recordType: held.recordType, encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])],
                       zone: "Library", owner: Self.user)
        #expect(try await second.bootstrap(.macWithoutLibrary, server: server).run() == .updateRequired(minClientRevision: SyncSchema.schemaRevision + 1))
    }
}
