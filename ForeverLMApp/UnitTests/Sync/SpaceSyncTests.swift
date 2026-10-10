import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Spaces (docs/cloudkit-schema-design.md §2.2, §2.3, §4.4, §6.2, §9.2, §9.7), on Macs with the test
/// course projection (`EngineTestDevice`) and FakeCloudKit: owned and joined spaces, the light walk,
/// compare-and-set sends, the write guard, a space that goes, moves, the audit and pushes.
@Suite("Space sync", .serialized)
struct SpaceSyncTests {
    /// A clock that runs with the wall clock, ahead of it like the engine's, and can jump.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset = EngineTestDevice.ahead
        var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
    }

    /// Passes calls through to a transport and keeps the desired keys of every fetch.
    final class RecordingTransport: CloudTransport, @unchecked Sendable {
        let inner: CloudTransport
        private let lock = NSLock()
        private var keys: [[String]?] = []
        var desiredKeys: [[String]?] { lock.withLock { keys } }

        init(_ inner: CloudTransport) { self.inner = inner }
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
            lock.withLock { keys += requests.map(\.desiredKeys) }
            return try await inner.zoneChanges(requests, in: database)
        }
        func records(_ ids: [CloudRecordID], in database: CloudDatabaseScope, desiredKeys: [String]?) async throws -> [CloudRecordID: Result<CloudRecord, CloudError>] {
            try await inner.records(ids, in: database, desiredKeys: desiredKeys)
        }
        func modifyRecords(saving: [CloudRecord], deleting: [CloudRecordID], in database: CloudDatabaseScope,
                           savePolicy: CloudSavePolicy, atomically: Bool) async throws -> CloudModifyResults {
            try await inner.modifyRecords(saving: saving, deleting: deleting, in: database, savePolicy: savePolicy, atomically: atomically)
        }
    }

    /// A Mac of `user` with its private engine and its SpaceSync.
    final class Device {
        let mac: EngineTestDevice
        let spaces: SpaceSync
        let clock = Clock()

        init(_ server: FakeCloudKit, name: String, deviceID: String, user: String, transport: CloudTransport? = nil) async throws {
            mac = try EngineTestDevice(server, name: name, deviceID: deviceID, user: user)
            var pacing = SyncPacerState.Configuration()
            pacing.capacity = 1_000_000
            pacing.refillPerSecond = 1_000_000
            let pacer = SyncPacer(configuration: pacing)
            let clock = clock
            spaces = SpaceSync(transport: transport ?? mac.transport, store: mac.local, moveMaps: MoveMapIndex(), deviceID: deviceID,
                               pacer: { _ in pacer }, clock: { clock.now })
            try await mac.bootstrap(.macHoldingLibrary, salt: user == "alice" ? 1 : 2)
        }

        func sync() async throws {
            EngineTestDriver.follow(mac.server)
            try await spaces.sync()
        }

        func send() async throws {
            EngineTestDriver.follow(mac.server)
            try await spaces.sendChanges()
        }
    }

    static let spaceSalt = Data(repeating: 7, count: 32)
    static let ownedKey = "private/Space-s1"
    static let joinedKey = "shared/alice/Space-s1"

    /// A record's stored payload as another device wrote it, named for the space's salt.
    static func payload(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], salt: Data = spaceSalt) throws -> Data {
        var envelope = SyncEnvelope.new(type, id: id, saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields { patch.changes[field] = .value(value) }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: counter, deviceID: "otheraaa")
        }
        return try envelope.storedPayload()
    }

    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], in zone: CloudZoneID, salt: Data = spaceSalt) throws -> CloudRecord {
        CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: type, id: id, salt: salt), in: zone), recordType: type.rawValue,
                    encryptedFields: [CloudRecord.payloadKey: .bytes(try payload(type, id, fields, salt: salt))])
    }

    /// Alice's team space `Space-s1`: its zone and root, made as SpaceService will.
    @discardableResult
    static func makeSpace(_ server: FakeCloudKit, owner: String = "alice") async throws -> CloudZoneID {
        let maker = server.transport(user: owner, device: "space-maker")
        let zone = CloudZoneID("Space-s1")
        _ = try await maker.modifyZones(saving: [zone], deleting: [], in: .private)
        let root = try SyncEnvelope(storedPayload: try payload(.zoneRoot, "root", [
            "kind": .string("team"), "salt": .string(spaceSalt.base64EncodedString()), "saltID": .string(RecordNaming.saltID(spaceSalt)),
            "owner": SyncPerson(user: owner, name: "Alice Owner").value, "createdAt": SyncJSON(1_759_400_000_000),
            "minClientRevision": SyncJSON(1), "editedAt": SyncJSON(1_759_400_000_000),
        ]))
        _ = try await maker.modifyRecords(saving: [CloudRecord(id: CloudRecordID("root", in: zone), recordType: "ZoneRoot",
                                                              encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])], in: .private)
        return zone
    }

    /// Alice owns Space-s1 and has sent course c1 into it; Bob has joined it with `permission`.
    static func team(_ permission: FakeCloudKit.Permission = .readWrite) async throws -> (server: FakeCloudKit, alice: Device, bob: Device) {
        let server = EngineTestDriver.server()
        let alice = try await Device(server, name: "alice-mac", deviceID: "macaaaaa", user: "alice")
        let bob = try await Device(server, name: "bob-mac", deviceID: "macbbbbb", user: "bob")
        try await makeSpace(server)
        server.share(zone: "Space-s1", owner: "alice", with: "bob", permission: permission)
        try await alice.sync()
        try alice.mac.exec("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES ('\(ownedKey)', 'Course', 'c1', 'c1');
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
        """)
        try await alice.send()
        try await bob.sync()
        return (server, alice, bob)
    }

    static func serverTitle(_ server: FakeCloudKit, _ id: String = "c1") throws -> String? {
        let name = RecordNaming.recordName(type: .course, id: id, salt: spaceSalt)
        guard let payload = server.storedRecord(name, zone: "Space-s1", owner: "alice")?.payload else { return nil }
        return try SyncEnvelope(storedPayload: payload).fields["title"]?.stringValue
    }

    @Test("An owned space is found in the private database, a joined one in the shared database, and edits go both ways by compare-and-set")
    func ownedAndJoined() async throws {
        let (server, alice, bob) = try await Self.team()
        #expect(try Self.serverTitle(server) == "Cells")
        #expect(try alice.mac.store.replica.zone(key: Self.ownedKey)?.role == "owner")
        let joined = try #require(try bob.mac.store.replica.zone(key: Self.joinedKey))
        #expect(joined.permission == "readWrite", "the share in the feed gives the member's permission")
        #expect(joined.saltID == RecordNaming.saltID(Self.spaceSalt))
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")
        #expect(try bob.mac.outboxRows() == 0, "an applied space record is never sent back")

        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Cell biology' WHERE id = 'c1'")
        try await bob.send()
        #expect(try Self.serverTitle(server) == "Cell biology")
        #expect(try bob.mac.outboxRows() == 0)
        let held = try #require(try bob.mac.store.replica.record(zoneKey: Self.joinedKey, recordType: "Course", wireID: "c1"))
        #expect(held.systemFields != nil, "the acknowledged record is the new base")

        // Alice's stale edit of another field meets a newer version: merged, both fields kept.
        await EngineTestDriver.pause()
        try alice.mac.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await alice.send()
        let name = RecordNaming.recordName(type: .course, id: "c1", salt: Self.spaceSalt)
        let merged = try SyncEnvelope(storedPayload: try #require(server.storedRecord(name, zone: "Space-s1", owner: "alice")?.payload))
        #expect(merged.fields["title"] == .string("Cell biology"))
        #expect(merged.fields["status"] == .string("archived"))
        #expect(try alice.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cell biology")

        // Nothing of the space went through the private engine.
        #expect(try alice.mac.serverEnvelope(.course, "c1") == nil)
    }

    @Test("The walk asks only for payload: a satellite's data and asset never ride the feed")
    func walkExcludesDataAndAsset() async throws {
        let server = EngineTestDriver.server()
        _ = try await Device(server, name: "alice-mac", deviceID: "macaaaaa", user: "alice")
        let zone = try await Self.makeSpace(server)
        server.share(zone: "Space-s1", owner: "alice", with: "bob")
        var satellite = try Self.record(.content, "ct:c1:cover:abc", ["ownerType": .string("Course"), "ownerID": .string("c1"), "role": .string("cover")], in: zone)
        satellite.encryptedFields[CloudRecord.dataKey] = .bytes(Data(repeating: 1, count: 10_000))
        server.put([satellite, try Self.record(.course, "c2", ["title": .string("Genes"), "status": .string("active")], in: zone)],
                   zone: "Space-s1", owner: "alice")
        let recording = RecordingTransport(server.transport(user: "bob", device: "bob-mac"))
        let bob = try await Device(server, name: "bob-mac", deviceID: "macbbbbb", user: "bob", transport: recording)
        try await bob.sync()
        #expect(!recording.desiredKeys.isEmpty)
        #expect(recording.desiredKeys.allSatisfy { $0 == ["payload"] || $0 == [] }, "\(recording.desiredKeys)")
        #expect(try bob.mac.count("SELECT COUNT(*) FROM ck_records WHERE zone_key = ? AND record_type = 'Content'", [.text(Self.joinedKey)]) == 1)
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c2'") == "Genes")
    }

    @Test("A read-only member's write is refused before it is sent, and the server's version comes back; CloudKit's own refusal is heard too")
    func readOnlyRefused() async throws {
        let (server, _, bob) = try await Self.team(.readOnly)
        #expect(try bob.mac.store.replica.zone(key: Self.joinedKey)?.permission == "readOnly")
        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Vandalised' WHERE id = 'c1'")
        server.resetCalls()
        try await bob.send()
        #expect(server.calls.filter { $0.operation == .modifyRecords && $0.device == "bob-mac" }.isEmpty)
        #expect(try bob.mac.outboxRows() == 0)
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")

        // A stale permission: CloudKit refuses, and the member is read-only from then on.
        try bob.mac.exec("UPDATE ck_zones SET permission = 'readWrite' WHERE zone_key = '\(Self.joinedKey)'")
        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Again' WHERE id = 'c1'")
        try await bob.send()
        #expect(try Self.serverTitle(server) == "Cells")
        #expect(try bob.mac.store.replica.zone(key: Self.joinedKey)?.permission == "readOnly")
        #expect(try bob.mac.outboxRows() == 0)
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")
    }

    @Test("A refused change takes its pending patch with it, so what waits for the patch's acknowledgement is not held for ever (F3)")
    func refusedChangeDropsItsPatch() async throws {
        let (_, _, bob) = try await Self.team(.readOnly)
        let stamp = SyncStamp(policy: .lastWriter, milliseconds: 1_759_500_000_000, counter: 0, deviceID: "macbbbbb").rawValue
        try bob.mac.exec("""
            INSERT INTO ck_patches (zone_key, record_type, wire_id, patch_json, dirty_at)
            VALUES ('\(Self.joinedKey)', 'Course', 'c1', '{"changes":{"title":"Patched"},"stamps":{"title":"\(stamp)"}}', 1)
        """)
        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Vandalised' WHERE id = 'c1'")
        try await bob.send()
        #expect(try bob.mac.count("SELECT COUNT(*) FROM ck_patches WHERE zone_key = ?", [.text(Self.joinedKey)]) == 0)
    }

    @Test("A joined space whose roster has not been read holds a member's edit: it is neither sent as read-write nor discarded as refused (F18)")
    func unknownPermissionHoldsTheEdit() async throws {
        let (server, _, bob) = try await Self.team()
        try bob.mac.exec("UPDATE ck_zones SET permission = NULL WHERE zone_key = '\(Self.joinedKey)'")
        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Held' WHERE id = 'c1'")
        server.resetCalls()
        try await bob.send()
        #expect(server.calls.filter { $0.operation == .modifyRecords && $0.device == "bob-mac" }.isEmpty, "nothing is sent on a guess")
        #expect(try bob.mac.outboxRows() == 1, "and the edit is still waiting")
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Held")
    }

    @Test("The guard leaves a refused field out and sends the rest, and refuses a private chat kind whole")
    func guardFields() throws {
        let writer = SpaceWriteGuard.Writer(user: "bob", permission: .readWrite, isOwner: false)
        let held = try SyncEnvelope(storedPayload: try Self.payload(.chat, "chat1", ["kind": .string("chat"), "title": .string("Talk")]))
        func change(_ fields: [String: SyncJSON]) throws -> OutboxChange {
            var envelope = held
            var patch = RecordPatch(.chat, id: "chat1")
            for (field, value) in fields { patch.changes[field] = .value(value) }
            try envelope.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: 1_759_500_000_000, counter: 0, deviceID: "macbbbbb") }
            return OutboxChange(zoneKey: Self.joinedKey, zone: .space("s1"), recordType: .chat, wireID: "chat1", recordName: "cht_x",
                                systemFields: nil, action: .save(envelope), priority: .structure, stamps: [:], mintedAgainst: [:], rows: [])
        }
        guard case .send(let sent) = SpaceSync.guarded(try change(["title": .string("Talk more"), "overallScore": SyncJSON(0.9)]), held: held, writer: writer),
              case .save(let envelope) = sent.action else { Issue.record("not sent"); return }
        #expect(envelope.fields["title"] == .string("Talk more"))
        #expect(envelope.fields["overallScore"] == nil)
        #expect(envelope.stamps["overallScore"] == nil)
        guard case .nothingLeft = SpaceSync.guarded(try change(["overallScore": SyncJSON(0.9)]), held: held, writer: writer) else {
            Issue.record("a change of only a refused field sends nothing"); return
        }
        guard case .refuse(.privateKind) = SpaceSync.guarded(try change(["kind": .string("review")]), held: held, writer: writer) else {
            Issue.record("a review never goes into a space"); return
        }
    }

    @Test("A space that goes keeps its local rows, its replica forgets it, and it is not walked again")
    func zoneGone() async throws {
        let (server, _, bob) = try await Self.team()
        server.deleteZone("Space-s1", owner: "alice")
        server.resetCalls()
        try await bob.sync()
        let gone = try await bob.spaces.goneSpaces()
        #expect(gone[Self.joinedKey]?.contains("deleted") == true)
        #expect(try bob.mac.count("SELECT COUNT(*) FROM ck_records WHERE zone_key = ? AND record_name <> 'root'", [.text(Self.joinedKey)]) == 0)
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells", "the space packages decide about local rows")
        server.resetCalls()
        try await bob.sync()
        #expect(server.calls.filter { $0.operation == .zoneChanges && $0.device == "bob-mac" }.isEmpty)
    }

    @Test("A member removed while their database token expired finds the space gone when the feed, read from nil, no longer lists it")
    func goneFoundFromNil() async throws {
        let (server, _, bob) = try await Self.team()
        server.removeParticipant("bob", zone: "Space-s1", owner: "alice")
        server.expireDatabaseChangeTokens(user: "bob", scope: .shared)
        server.resetCalls()
        try await bob.sync()
        #expect(try await bob.spaces.goneSpaces()[Self.joinedKey] != nil)
        #expect(server.calls.filter { $0.operation == .zoneChanges && $0.device == "bob-mac" }.isEmpty, "found by the zone list, not by a walk")
        #expect(try await bob.spaces.heldSpaces().isEmpty)
    }

    @Test("A pending write to a record moveMaps lists as moved back to Library goes to its copy there, with its stamps")
    func pendingWriteRetargeted() async throws {
        let (server, alice, _) = try await Self.team()
        let a = alice.mac
        let salt = try #require(try a.personalSalt())
        // The reverse move: the copy in Library (fields and stamps verbatim), the move listed, the space deleted.
        let spaceName = RecordNaming.recordName(type: .course, id: "c1", salt: Self.spaceSalt)
        var copy = try SyncEnvelope(storedPayload: try #require(server.storedRecord(spaceName, zone: "Space-s1", owner: "alice")?.payload))
        copy.saltID = RecordNaming.saltID(salt)
        server.put([CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: .course, id: "c1", salt: salt), in: PrivateSyncZones.library),
                                recordType: "Course", encryptedFields: [CloudRecord.payloadKey: .bytes(try copy.storedPayload())])],
                   zone: "Library", owner: "alice")
        let stored = try MoveMapIndex.encodeList([MoveMapMove(type: "Course", id: "c1", from: "Space-s1", to: "Library", at: SyncTime.milliseconds(Date()))])
        let file = FileRef(owner: "root", role: MoveMapIndex.role(forKey: "back1.0"), hash: SyncIdentity.sha256Hex(stored),
                           size: Int64(stored.count), mime: "application/json", encoding: "gzip", storedParts: [stored])
        server.put([CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: .content, id: file.satelliteIDs[0], salt: salt), in: PrivateSyncZones.content),
                                recordType: "Content", encryptedFields: [CloudRecord.dataKey: .bytes(stored)])], zone: "Content", owner: "alice")
        var root = try #require(try a.serverEnvelope(.zoneRoot, "root"))
        var patch = RecordPatch(.zoneRoot, id: "root")
        patch.changes["moveMaps"] = .elements(["back1.0": file.value])
        try root.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: SyncTime.milliseconds(Date()), counter: 0, deviceID: "moveraaa") }
        server.put([CloudRecord(id: CloudRecordID("root", in: PrivateSyncZones.library), recordType: "ZoneRoot",
                                encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])], zone: "Library", owner: "alice")
        try await a.fetch()
        server.deleteZone("Space-s1", owner: "alice")

        // An edit made before this Mac saw the move: the send meets zoneNotFound.
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET title = 'Edited before the move arrived' WHERE id = 'c1'")
        try await alice.send()
        let inLibrary = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(inLibrary.fields["title"] == .string("Edited before the move arrived"))
        #expect(inLibrary.fields["status"] == .string("active"))
        guard case .value(let titleStamp)? = inLibrary.stamps["title"], case .value(let copied)? = copy.stamps["title"] else {
            Issue.record("no stamps"); return
        }
        #expect(titleStamp.isLater(than: copied))
        #expect(try a.outboxRows() == 0)
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE zone_key = ? AND record_name = ?", [.text(Self.ownedKey), .text(spaceName)]) == 0)
        #expect(try await alice.spaces.goneSpaces()[Self.ownedKey] != nil)
    }

    @Test("After a token reset the walk starts from nil, and the audit sweeps what it never reports")
    func auditAfterTokenReset() async throws {
        let (server, alice, bob) = try await Self.team()
        try alice.mac.exec("INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES ('\(Self.ownedKey)', 'Course', 'c2', 'c2'); INSERT INTO test_courses (id, title) VALUES ('c2', 'Genes');")
        try await alice.send()
        try await bob.sync()
        #expect(try bob.mac.count("SELECT COUNT(*) FROM test_courses") == 2)
        let owner = server.transport(user: "alice", device: "other")
        _ = try await owner.modifyRecords(deleting: [CloudRecordID(RecordNaming.recordName(type: .course, id: "c2", salt: Self.spaceSalt), in: CloudZoneID("Space-s1"))], in: .private)
        server.expireZoneChangeTokens(zone: "Space-s1", owner: "alice")
        try await bob.sync()
        #expect(try bob.mac.count("SELECT COUNT(*) FROM test_courses") == 1)
        #expect(try bob.mac.text("SELECT title FROM test_courses") == "Cells")
        #expect(try bob.mac.store.replica.zone(key: Self.joinedKey)?.lastCompletePassAt != nil)
        #expect(try bob.mac.outboxRows() == 0)
    }

    @Test("The shared database gets the one subscription flm-shared-db, saved once")
    func sharedSubscription() async throws {
        let (server, _, bob) = try await Self.team()
        try await bob.sync()
        #expect(server.subscriptionIDs(user: "bob", scope: .shared) == [SpaceSync.sharedSubscriptionID])
        #expect(server.calls.filter { $0.operation == .saveSubscription && $0.device == "bob-mac" }.count == 1)
        try await bob.spaces.handleSharedPush()
    }

    @Test("Private-database pushes that name only Content are checked once per 30 seconds; others at once")
    func contentWakeupsCoalesced() async throws {
        let (server, alice, _) = try await Self.team()
        _ = try await alice.spaces.handlePrivatePush()
        let uploader = server.transport(user: "alice", device: "uploader")
        func upload(_ name: String) async throws {
            _ = try await uploader.modifyRecords(saving: [CloudRecord(id: CloudRecordID(name, in: PrivateSyncZones.content), recordType: "Content",
                                                                      encryptedFields: [CloudRecord.payloadKey: .bytes(Data("{}".utf8))])], in: .private)
        }
        try await upload("ct_one")
        let first = try await alice.spaces.handlePrivatePush()
        #expect(first.contentOnly)
        try await upload("ct_two")
        server.resetCalls()
        #expect(try await alice.spaces.handlePrivatePush().coalesced)
        #expect(server.calls.filter { $0.device == "alice-mac" }.isEmpty)
        alice.clock.advance(31)
        let later = try await alice.spaces.handlePrivatePush()
        #expect(!later.coalesced && later.contentOnly)

        // A change to the library is never held back by a check that found more than Content.
        try alice.mac.exec("INSERT INTO test_courses (id, title) VALUES ('p1', 'Personal')")
        try await alice.mac.sync()
        alice.clock.advance(31)
        let library = try await alice.spaces.handlePrivatePush()
        #expect(library.engineZones)
        #expect(!library.contentOnly)
    }
}
