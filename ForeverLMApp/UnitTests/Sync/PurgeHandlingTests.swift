import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The private library leaving iCloud (docs/cloudkit-schema-design.md §2.5, D37): the device stops,
/// keeps its own data, drops what described the server, and never re-creates a zone by itself.
@Suite("Purge handling")
struct PurgeHandlingTests {
    private typealias Device = ZoneBootstrapTests.Device
    private static let user = ZoneBootstrapTests.user

    private static func held(_ device: Device) async throws -> (records: Int64, stop: PurgeHandler.Event?, saltID: String?) {
        try await device.store.perform { state in
            (
                try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_records") ?? 0,
                try PurgeHandler.stopReason(in: state),
                try state.replica.zone(key: PrivateSyncZones.libraryKey)?.saltID
            )
        }
    }

    @Test("`.purged`, `.deleted` and `.encryptedDataReset` stop the private database and drop the replica, keeping the zones' salt")
    func purgeKinds() async throws {
        for reason in [CloudZoneDeletionReason.purged, .deleted, .encryptedDataReset] {
            let server = FakeCloudKit()
            let mac = try Device(server, name: "mac")
            _ = try await mac.bootstrap(.macHoldingLibrary, server: server).run()
            try await mac.store.perform { state in
                try state.connection.execute("UPDATE ck_zones SET change_token = x'01', last_complete_pass_at = 1")
                try state.connection.execute(
                    "INSERT INTO ck_pending_deletes (zone_key, record_name, record_type, wire_id, deleted_at) VALUES ('private/Catalog', 'src_x', 'Source', 'x', 1)"
                )
                try PurgeHandler.handle(.zoneDeleted(reason: reason), in: state)
            }
            let (records, stop, saltID) = try await Self.held(mac)
            #expect(records == 0, "\(reason): the replica's rows go")
            #expect(stop == .zoneDeleted(reason: reason))
            #expect(saltID != nil, "\(reason): the zone rows keep their salt, so the bootstrap keeps finding a purge")
            let leftovers = try await mac.store.perform { state in
                (try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_pending_deletes") ?? -1,
                 try state.connection.scalarInteger("SELECT COUNT(*) FROM ck_zones WHERE change_token IS NOT NULL OR last_complete_pass_at IS NOT NULL") ?? -1)
            }
            #expect(leftovers == (0, 0))
        }
    }

    @Test("After a purge the bootstrap creates nothing; only Upload my library again makes new zones, with a new salt")
    func reupload() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, salt: 1, server: server).run()
        server.deleteZone("Library", owner: Self.user, reason: .purged)
        try await mac.store.perform { try PurgeHandler.handle(.zoneDeleted(reason: .purged), in: $0) }
        server.resetCalls()
        #expect(try await mac.bootstrap(.macHoldingLibrary, salt: 2, server: server).run() == .purged(.zoneDeleted(reason: .purged)))
        #expect(!server.calls.contains { $0.operation == .modifyZones || $0.operation == .modifyRecords })

        try await mac.store.perform { try PurgeHandler.reupload(in: $0) }
        #expect(try await Self.held(mac).stop == nil)
        #expect(try await mac.bootstrap(.macHoldingLibrary, salt: 2, server: server).run() == .created(saltID: RecordNaming.saltID(Data(repeating: 2, count: 32))))
    }

    @Test("A sign-out stops sending but keeps the replica, and the same account signing in resumes; a switch drops it")
    func accountChanges() async throws {
        let server = FakeCloudKit()
        let mac = try Device(server, name: "mac")
        _ = try await mac.bootstrap(.macHoldingLibrary, server: server).run()
        try await mac.store.perform { try PurgeHandler.handle(.accountChanged(signedOut: true), in: $0) }
        var held = try await Self.held(mac)
        #expect(held.records == 1, "the root stays")
        #expect(held.stop == .accountChanged(signedOut: true))
        try await mac.store.perform { try PurgeHandler.resumeAfterSignIn(in: $0) }
        #expect(try await Self.held(mac).stop == nil)

        try await mac.store.perform { try PurgeHandler.handle(.accountChanged(signedOut: false), in: $0) }
        held = try await Self.held(mac)
        #expect(held.records == 0, "another account's library is never this replica's")
        #expect(held.stop == .accountChanged(signedOut: false))
        try await mac.store.perform { try PurgeHandler.resumeAfterSignIn(in: $0) }
        #expect(try await Self.held(mac).stop == .accountChanged(signedOut: false), "only the learner's choice lifts a switch")
    }

    @Test("Every stop reason survives its stored code")
    func codes() {
        let events: [PurgeHandler.Event] = [
            .zoneDeleted(reason: .purged), .zoneDeleted(reason: .deleted), .zoneDeleted(reason: .encryptedDataReset),
            .rootMissing, .saltChanged, .accountChanged(signedOut: true), .accountChanged(signedOut: false),
        ]
        for event in events { #expect(PurgeHandler.Event(code: event.code) == event) }
        #expect(PurgeHandler.Event(code: "zoneDeleted.other") == nil)
    }

    // MARK: - Through the engine

    private static func syncedMac() async throws -> (FakeCloudKit, EngineTestDevice) {
        let server = EngineTestDriver.server()
        let mac = try EngineTestDevice(server, name: "purge-mac", deviceID: "macaaaaa")
        try await mac.bootstrap()
        try mac.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await mac.sync()
        #expect(try mac.serverEnvelope(.course, "c1") != nil)
        return (server, mac)
    }

    @Test("A zone deletion the database feed reports stops the engine: the replica goes, the learner's rows stay, nothing is sent")
    func purgeThroughTheFeed() async throws {
        for (reason, remove) in [
            (CloudZoneDeletionReason.purged, { (server: FakeCloudKit) in server.deleteZone("Library", owner: "alice", reason: .purged) }),
            (.deleted, { (server: FakeCloudKit) in server.deleteZone("Catalog", owner: "alice", reason: .deleted) }),
            (.encryptedDataReset, { (server: FakeCloudKit) in server.resetEncryptedData(owner: "alice") }),
        ] {
            let (server, mac) = try await Self.syncedMac()
            remove(server)
            try mac.exec("UPDATE test_courses SET title = 'After the purge' WHERE id = 'c1'")
            server.resetCalls()
            try await mac.sync()
            #expect(await mac.engine.stopped == .zoneDeleted(reason: reason))
            #expect(try mac.count("SELECT COUNT(*) FROM ck_records") == 0)
            #expect(try mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "After the purge", "knowledge.db is kept")
            #expect(!server.calls.contains { $0.operation == .modifyRecords || $0.operation == .modifyZones }, "\(reason): nothing re-created or re-sent")
        }
    }

    @Test("userDeletedZone on a save stops the engine as a purge")
    func userDeletedZoneOnSave() async throws {
        let (server, mac) = try await Self.syncedMac()
        server.deleteZone("Library", owner: "alice", reason: .purged)
        try mac.exec("UPDATE test_courses SET title = 'Edited' WHERE id = 'c1'")
        try await mac.send()
        #expect(await mac.engine.stopped == .zoneDeleted(reason: .purged))
        server.resetCalls()
        try await mac.sync()
        #expect(server.calls.isEmpty, "a stopped engine asks nothing")
        let relaunched = PrivateSyncEngine(transport: mac.transport, store: mac.local, pacer: SyncPacer(), deviceID: "macaaaaa")
        try await relaunched.start()
        #expect(await relaunched.stopped == .zoneDeleted(reason: .purged), "the stop survives a relaunch")
    }

    @Test("A record named with an old salt is ignored on fetch")
    func oldSaltIgnored() async throws {
        let (server, mac) = try await Self.syncedMac()
        let oldSalt = Data(repeating: 9, count: 32)
        var envelope = SyncEnvelope.new(.course, id: "ghost", saltID: RecordNaming.saltID(oldSalt))
        var patch = RecordPatch(.course, id: "ghost")
        patch.changes["title"] = .value(.string("From a dead salt"))
        patch.changes["status"] = .value(.string("active"))
        try envelope.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: SyncTime.milliseconds(Date()), counter: 0, deviceID: "oldsaltz") }
        let name = RecordNaming.recordName(type: .course, id: "ghost", salt: oldSalt)
        _ = server.put([CloudRecord(id: CloudRecordID(name, in: PrivateSyncZones.library), recordType: "Course",
                                    encryptedFields: [CloudRecord.payloadKey: .bytes(try envelope.storedPayload())])],
                       zone: "Library", owner: "alice")
        try await mac.fetch()
        #expect(try mac.count("SELECT COUNT(*) FROM test_courses WHERE id = 'ghost'") == 0)
        #expect(try mac.count("SELECT COUNT(*) FROM ck_records WHERE record_name = ?", [.text(name)]) == 0)
        #expect(await mac.engine.stopped == nil)
    }
}
