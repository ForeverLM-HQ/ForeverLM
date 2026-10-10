import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The private engine (docs/cloudkit-schema-design.md §2.3, §6.2, §6.3, §6.6), on Macs with the test
/// course, lesson and entry projections and FakeCloudKit (`EngineTestDevice`).
@Suite("Private sync engine", .serialized)
struct PrivateSyncEngineTests {
    private typealias Device = EngineTestDevice

    /// Two Macs of one account: `a` made the root, `b` adopted it.
    private static func pair() async throws -> (server: FakeCloudKit, a: Device, b: Device) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "engine-a", deviceID: "macaaaaa")
        #expect(try await a.bootstrap() == .created(saltID: RecordNaming.saltID(Data(repeating: 1, count: 32))))
        let b = try Device(server, name: "engine-b", deviceID: "macbbbbb")
        _ = try await b.bootstrap(.macWithoutLibrary)
        return (server, a, b)
    }

    /// `c1` on both Macs, sent by `a` and fetched by `b`.
    private static func sharedCourse() async throws -> (server: FakeCloudKit, a: Device, b: Device) {
        let (server, a, b) = try await pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        try await b.sync()
        #expect(try b.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")
        await EngineTestDriver.pause()
        return (server, a, b)
    }

    private static func sends(_ server: FakeCloudKit, by device: Device) -> [FakeCloudKit.Call] {
        server.calls.filter { $0.operation == .modifyRecords && $0.device == device.name }
    }

    @Test("A local write reaches the server named with the salt, and another Mac applies it without writing it back")
    func roundTrip() async throws {
        let (server, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        let sent = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(sent.fields["title"] == .string("Cells"))
        #expect(sent.saltID == RecordNaming.saltID(Data(repeating: 1, count: 32)))
        #expect(server.recordNames(zone: "Library", owner: "alice").contains(try a.recordName(.course, "c1")))
        #expect(try a.outboxRows() == 0)
        try await b.sync()
        #expect(try b.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")
        #expect(try b.outboxRows() == 0, "an apply writes nothing back")
        #expect(try b.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Course'") == 1)
    }

    @Test("Records CKSyncEngine hands over are applied like a page, and deletions with them; CKSyncEngine keeps the token")
    func engineEvents() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells'); INSERT INTO test_courses (id, title) VALUES ('c2', 'Genes');")
        try await a.sync()
        let c = try Device(server, name: "engine-c", deviceID: "maccccca")
        _ = try await c.bootstrap(.macWithoutLibrary)
        guard case .success(let page) = try await c.transport.zoneChanges(PrivateSyncZones.library, in: .private) else { Issue.record("no page"); return }
        try await c.engine.absorbFetched(page.modified, deleted: [], in: PrivateSyncZones.library, passStart: Date())
        #expect(try c.count("SELECT COUNT(*) FROM test_courses") == 2)
        let c2 = CloudRecordID(try a.recordName(.course, "c2"), in: PrivateSyncZones.library)
        try await c.engine.absorbFetched([], deleted: [CloudRecordDeletion(id: c2, recordType: "Course")], in: PrivateSyncZones.library, passStart: Date())
        #expect(try c.count("SELECT COUNT(*) FROM test_courses") == 1)
        #expect(try c.store.replica.zone(key: "private/Library")?.changeToken == nil)
        #expect(try c.outboxRows() == 0)
    }

    @Test("A request carries at most 200 records and 800 KiB of payload")
    func batching() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "engine-batch", deviceID: "macaaaaa")
        try await a.bootstrap()
        var sql = "BEGIN;"
        for index in 0..<450 { sql += "INSERT INTO test_courses (id, title) VALUES ('c\(index)', 'Course \(index)');" }
        try a.exec(sql + "COMMIT;")
        server.resetCalls()
        try await a.send()
        let counts = Self.sends(server, by: a).map(\.recordNames.count)
        #expect(counts.count >= 3)
        #expect(counts.allSatisfy { $0 <= 200 }, "\(counts)")
        #expect(server.recordNames(zone: "Library", owner: "alice").count == 451)

        // Large payloads: each request stays under 800 KiB of stored payload.
        sql = "BEGIN;"
        var generator = SystemRandomNumberGenerator()
        for index in 0..<60 {
            let title = Data((0..<22_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
            sql += "INSERT INTO test_courses (id, title) VALUES ('big\(index)', '\(title)');"
        }
        try a.exec(sql + "COMMIT;")
        server.resetCalls()
        try await a.send()
        let requests = Self.sends(server, by: a)
        #expect(requests.count >= 2)
        for request in requests {
            let bytes = request.recordNames.compactMap { server.storedRecord($0, zone: "Library", owner: "alice")?.payload?.count }.reduce(0, +)
            #expect(bytes <= SyncSchema.Limits.batchMaxBytes, "a request carried \(bytes) bytes")
        }
        #expect(try a.outboxRows() == 0)
    }

    @Test("At most 1,000 changes wait in the engine")
    func pendingCap() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "engine-cap", deviceID: "macaaaaa")
        try await a.bootstrap()
        var sql = "BEGIN;"
        for index in 0..<1_200 { sql += "INSERT INTO test_courses (id, title) VALUES ('c\(index)', 'Course \(index)');" }
        try a.exec(sql + "COMMIT;")
        #expect(try await a.engine.feed() == 1_000)
        #expect(try await a.engine.feed() == 1_000)
    }

    @Test("Nothing is sent before the root is held, nor before the device knows its server offset")
    func noRootNoOffset() async throws {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "engine-noroot", deviceID: "macaaaaa")
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.send()
        #expect(Self.sends(server, by: a).isEmpty)
        #expect(try a.outboxRows() > 0)

        try await a.bootstrap()
        try a.exec("DELETE FROM ck_clock")
        server.resetCalls()
        try await a.send()
        #expect(Self.sends(server, by: a).isEmpty, "no stamp before a server offset")
        try a.store.replica.saveClock(StampClock(deviceID: "macaaaaa", offsetSamples: [-5_000]))
        try await a.send()
        #expect(Self.sends(server, by: a).count == 1)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Cells"))
    }

    @Test("serverRecordChanged merges: the server's field and the local field both survive, and the local one goes out again")
    func mergeOnServerRecordChanged() async throws {
        let (server, a, b) = try await Self.sharedCourse()
        try b.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await b.sync()
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_courses SET title = 'Cell biology' WHERE id = 'c1'")
        server.resetCalls()
        try await a.send()
        let held = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(held.fields["title"] == .string("Cell biology"))
        #expect(held.fields["status"] == .string("archived"))
        #expect(try a.text("SELECT title || '/' || status FROM test_courses WHERE id = 'c1'") == "Cell biology/archived")
        #expect(Self.sends(server, by: a).count == 2, "the conflict, then the local winner on the server's tag")
        #expect(try a.outboxRows() == 0)
    }

    @Test("unknownItem: the delete wins for a record without a deterministic name, and nothing is re-created")
    func unknownItemDeleteWins() async throws {
        let (server, a, b) = try await Self.sharedCourse()
        try b.exec("DELETE FROM test_courses WHERE id = 'c1'")
        try await b.sync()
        #expect(try a.serverEnvelope(.course, "c1") == nil)
        try a.exec("UPDATE test_courses SET title = 'Edited elsewhere' WHERE id = 'c1'")
        try await a.send()
        try await a.send()
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 0)
        #expect(try a.serverEnvelope(.course, "c1") == nil)
        #expect(try a.outboxRows() == 0)
        _ = server
    }

    private static func entryFixture() async throws -> (server: FakeCloudKit, a: Device, entryID: String) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "engine-entry", deviceID: "macaaaaa")
        try await a.bootstrap()
        try await a.sync()
        try a.exec("""
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
            INSERT INTO test_lessons (id, course_id, title, order_key) VALUES ('l1', 'c1', 'Membranes', 'a0');
            INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('x1', 'l1', 's1', 'approved', 'a0');
        """)
        try await a.sync()
        let entryID = OutboxTestProjections.Entries.entryID(lessonID: "l1", itemID: "s1")
        #expect(try a.serverEnvelope(.entry, entryID)?.fields["approval"] == .string("approved"))
        // Another device deletes the Entry record outright.
        let other = server.transport(user: "alice", device: "other")
        _ = try await other.modifyRecords(deleting: [CloudRecordID(try a.recordName(.entry, entryID), in: PrivateSyncZones.library)], in: .private)
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_entries SET approval = 'pending' WHERE id = 'x1'")
        return (server, a, entryID)
    }

    @Test("unknownItem: a deterministic record the last complete pass saw is created again with the pending edit")
    func unknownItemRecreates() async throws {
        let (_, a, entryID) = try await Self.entryFixture()
        try await a.send()
        let entry = try #require(try a.serverEnvelope(.entry, entryID))
        #expect(entry.fields["approval"] == .string("pending"))
        #expect(entry.fields["state"] == .string("active"))
        #expect(try a.outboxRows() == 0)
    }

    @Test("unknownItem: a deterministic record the last complete pass did not see is not created again; the delete wins")
    func unknownItemGate() async throws {
        let (_, a, entryID) = try await Self.entryFixture()
        try a.exec("UPDATE ck_zones SET last_complete_pass_at = 1e12 WHERE zone_key = 'private/Library'")
        try await a.send()
        try await a.send()
        #expect(try a.serverEnvelope(.entry, entryID) == nil)
        #expect(try a.count("SELECT COUNT(*) FROM test_entries WHERE id = 'x1'") == 0)
    }

    @Test("unknownItem on a record moveMaps lists: its copy is kept and nothing is re-created where it was")
    func movedRecord() async throws {
        let (server, a, _) = try await Self.sharedCourse()
        let salt = try #require(try a.personalSalt())
        let stored = try MoveMapIndex.encodeList([MoveMapMove(type: "Course", id: "c1", from: "Library", to: "Space-s1", at: SyncTime.milliseconds(Date()))])
        let file = FileRef(owner: "root", role: MoveMapIndex.role(forKey: "job1.0"), hash: SyncIdentity.sha256Hex(stored),
                           size: Int64(stored.count), mime: "application/json", encoding: "gzip", storedParts: [stored])
        _ = server.put([CloudRecord(
            id: CloudRecordID(RecordNaming.recordName(type: .content, id: file.satelliteIDs[0], salt: salt), in: PrivateSyncZones.content),
            recordType: "Content", encryptedFields: [CloudRecord.dataKey: .bytes(stored)]
        )], zone: "Content", owner: "alice")
        var root = try #require(try a.serverEnvelope(.zoneRoot, "root"))
        var patch = RecordPatch(.zoneRoot, id: "root")
        patch.changes["moveMaps"] = .elements(["job1.0": file.value])
        try root.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: SyncTime.milliseconds(Date()), counter: 0, deviceID: "moveraaa") }
        _ = server.put([CloudRecord(id: CloudRecordID("root", in: PrivateSyncZones.library), recordType: "ZoneRoot",
                                    encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])], zone: "Library", owner: "alice")
        let mover = server.transport(user: "alice", device: "mover")
        _ = try await mover.modifyRecords(deleting: [CloudRecordID(try a.recordName(.course, "c1"), in: PrivateSyncZones.library)], in: .private)

        try a.exec("UPDATE test_courses SET title = 'Edited before the move arrived' WHERE id = 'c1'")
        try await a.send()
        try await a.send()
        #expect(try a.serverEnvelope(.course, "c1") == nil, "never created again in Library")
        #expect(try a.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Edited before the move arrived")
        #expect(try a.outboxRows() > 0, "the edit waits for the copy")
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE record_name = ?", [.text(try a.recordName(.course, "c1"))]) == 0,
                "the replica forgets the copy the server no longer has")

        // The deletion arriving by fetch keeps the local row too: it belongs to the copy now.
        try await a.fetch()
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 1)
    }

    @Test("An inbound record with a local change pending is merged, never skipped: the server's field lands, the local one stays to go out")
    func inboundMergesWithPending() async throws {
        let (_, a, b) = try await Self.sharedCourse()
        try a.exec("UPDATE test_courses SET title = 'Mine' WHERE id = 'c1'")
        await EngineTestDriver.pause()
        try b.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await b.sync()
        try await a.fetch()
        #expect(try a.text("SELECT title || '/' || status FROM test_courses WHERE id = 'c1'") == "Mine/archived")
        #expect(try a.outboxRows() > 0)
        try await a.send()
        let held = try #require(try a.serverEnvelope(.course, "c1"))
        #expect(held.fields["title"] == .string("Mine"))
        #expect(held.fields["status"] == .string("archived"))
        #expect(try a.outboxRows() == 0)
    }

    @Test("A pending local field older than the server's loses on fetch, and is never sent")
    func inboundWinsOverOlderPending() async throws {
        let (server, a, b) = try await Self.sharedCourse()
        try a.exec("UPDATE test_courses SET title = 'Older idea' WHERE id = 'c1'")
        await EngineTestDriver.pause()
        try b.exec("UPDATE test_courses SET title = 'Newer idea' WHERE id = 'c1'")
        try await b.sync()
        try await a.fetch()
        #expect(try a.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Newer idea")
        server.resetCalls()
        try await a.send()
        #expect(Self.sends(server, by: a).isEmpty)
        #expect(try a.outboxRows() == 0)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Newer idea"))
    }

    @Test("Patch fields count as pending changes: a newer one survives the merge and is projected, an older one leaves the patch")
    func patchFieldsArePending() async throws {
        let (_, a, b) = try await Self.sharedCourse()
        let sent = try #require(try a.serverEnvelope(.course, "c1"))
        guard case .value(let titleStamp)? = sent.stamps["title"] else { Issue.record("no title stamp"); return }
        let patch = PendingPatch(
            changes: ["title": .string("Patched"), "status": .string("draft")],
            stamps: [
                "title": .value(SyncStamp(policy: .lastWriter, milliseconds: titleStamp.milliseconds + 1, counter: 0, deviceID: "patchaaa")),
                "status": .value(SyncStamp(policy: .lastWriter, milliseconds: 2, counter: 0, deviceID: "patchaaa")),
            ],
            zoneKey: "private/Library", type: "Course", wireID: "c1"
        )
        try patch.save(in: a.store, now: Date())
        try b.exec("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        try await b.sync()
        try await a.fetch()
        #expect(try a.text("SELECT title || '/' || status FROM test_courses WHERE id = 'c1'") == "Patched/archived")
        let kept = try #require(try PendingPatch.load(zoneKey: "private/Library", type: "Course", wireID: "c1", in: a.store))
        #expect(kept.changes == ["title": .string("Patched")])
        #expect(Set(kept.stamps.keys) == ["title"])
    }

    @Test("After 5 rounds the local side won but could not land, the record is parked until the next launch re-queues it")
    func conflictRoundsPark() async throws {
        let (server, a, _) = try await Self.sharedCourse()
        let name = try a.recordName(.course, "c1")
        let serverCopy = try #require(server.storedRecord(name, zone: "Library", owner: "alice"))
        server.failRecord(name, times: 5, with: CloudError(.serverRecordChanged, serverRecord: serverCopy))
        try a.exec("UPDATE test_courses SET title = 'Stubborn' WHERE id = 'c1'")
        try await a.send()
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine WHERE reason = 'conflict'") == 1)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Cells"))
        server.resetCalls()
        try await a.send()
        #expect(Self.sends(server, by: a).isEmpty, "a parked record is not sent")

        let relaunched = PrivateSyncEngine(transport: a.transport, store: a.local, pacer: SyncPacer(), deviceID: "macaaaaa",
                                           clock: { Date().addingTimeInterval(EngineTestDevice.ahead) })
        try await relaunched.sendChanges()
        #expect(try a.count("SELECT COUNT(*) FROM ck_quarantine") == 0)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Stubborn"))
    }
}
