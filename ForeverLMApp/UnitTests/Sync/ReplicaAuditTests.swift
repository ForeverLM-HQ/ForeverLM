import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The names-only sweep after a token reset (docs/cloudkit-schema-design.md §2.3, §6.4, D30): a pass
/// from nil never returns the deletions it missed, so the replica audit removes them, and a
/// deterministic record deleted meanwhile is never written back.
@Suite("Replica audit", .serialized)
struct ReplicaAuditTests {
    private typealias Device = EngineTestDevice

    private static func pair() async throws -> (FakeCloudKit, Device, Device) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "audit-a", deviceID: "macaaaaa")
        try await a.bootstrap()
        let b = try Device(server, name: "audit-b", deviceID: "macbbbbb")
        try await b.bootstrap(.macWithoutLibrary)
        try await a.sync()
        try await b.sync()
        return (server, a, b)
    }

    @Test("An expired token after a deletion leaves no ghost: the pass from nil misses the deletion, the audit sweeps it")
    func expiredTokenLeavesNoGhost() async throws {
        let (server, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells'); INSERT INTO test_courses (id, title) VALUES ('c2', 'Genes');")
        try await a.sync()
        try await b.sync()
        try b.exec("DELETE FROM test_courses WHERE id = 'c1'")
        try await b.sync()
        server.expireZoneChangeTokens(zone: "Library", owner: "alice")
        try await a.sync()
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 0, "the ghost is swept")
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c2'") == 1)
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE record_type = 'Course'") == 1)
        #expect(try a.serverEnvelope(.course, "c1") == nil, "and never sent back")
        #expect(try a.outboxRows() == 0)
    }

    @Test("An expired token after a deletion leaves no re-create: a pending edit to a deterministic record deleted meanwhile is dropped")
    func expiredTokenLeavesNoRecreate() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("""
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
            INSERT INTO test_lessons (id, course_id, title, order_key) VALUES ('l1', 'c1', 'Membranes', 'a0');
            INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('x1', 'l1', 's1', 'approved', 'a0');
        """)
        try await a.sync()
        let entryID = OutboxTestProjections.Entries.entryID(lessonID: "l1", itemID: "s1")
        let other = server.transport(user: "alice", device: "other")
        _ = try await other.modifyRecords(deleting: [CloudRecordID(try a.recordName(.entry, entryID), in: PrivateSyncZones.library)], in: .private)
        server.expireZoneChangeTokens(zone: "Library", owner: "alice")
        await EngineTestDriver.pause()
        try a.exec("UPDATE test_entries SET approval = 'pending' WHERE id = 'x1'")
        try await a.sync()
        try await a.sync()
        #expect(try a.serverEnvelope(.entry, entryID) == nil, "no re-create")
        #expect(try a.count("SELECT COUNT(*) FROM test_entries WHERE id = 'x1'") == 0, "the delete wins")
        #expect(try a.count("SELECT COUNT(*) FROM test_lessons WHERE id = 'l1'") == 1)
    }

    @Test("The walk marks what it saw, makes its pass the zone's last complete pass, and spares rows acknowledged after it began")
    func walkBookkeeping() async throws {
        let (server, a, _) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        // A row the server does not have, acknowledged after the walk begins.
        try a.store.replica.upsertRecord(ReplicaRecord(
            zoneKey: "private/Library", recordName: "crs_late", recordType: "Course", wireID: "late",
            systemFields: nil, payload: try OutboxTestProjections.payload(.course, "late", ["title": "Late", "status": "active"]),
            seenPass: Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate
        ))
        let start = Date()
        let audit = ReplicaAudit(transport: a.transport, store: a.local, moveMaps: MoveMapIndex(), clock: { start })
        let result = try await audit.run(PrivateSyncZones.library)
        #expect(result.swept == 0)
        #expect(result.walked == 2, "the root and c1")
        let pass = start.timeIntervalSinceReferenceDate
        #expect(try a.store.replica.zone(key: "private/Library")?.lastCompletePassAt == pass)
        #expect(try a.store.replica.record(zoneKey: "private/Library", recordName: try a.recordName(.course, "c1"))?.seenPass == pass)
        #expect(try a.count("SELECT COUNT(*) FROM ck_records WHERE record_name = 'crs_late'") == 1)
        #expect(server.calls.last { $0.operation == .zoneChanges } != nil)

        let due = try await a.local.perform { state in
            [
                try ReplicaAudit.isDue(PrivateSyncZones.library, in: state, now: start.addingTimeInterval(86_400), interval: 7 * 86_400),
                try ReplicaAudit.isDue(PrivateSyncZones.library, in: state, now: start.addingTimeInterval(8 * 86_400), interval: 7 * 86_400),
                try ReplicaAudit.isDue(PrivateSyncZones.catalog, in: state, now: start, interval: 7 * 86_400),
            ]
        }
        #expect(due == [false, true, false], "weekly; and the first sync walked Catalog too")
    }

    @Test("A walk that cannot finish sweeps nothing")
    func failedWalkSweepsNothing() async throws {
        let (server, a, b) = try await Self.pair()
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try await a.sync()
        try await b.sync()
        try b.exec("DELETE FROM test_courses WHERE id = 'c1'")
        try await b.sync()
        server.failNext(.zoneChanges, device: a.name, with: CloudError(.networkFailure))
        let audit = ReplicaAudit(transport: a.transport, store: a.local, moveMaps: MoveMapIndex())
        await #expect(throws: CloudError.self) { try await audit.run(PrivateSyncZones.library) }
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 1)
    }
}
