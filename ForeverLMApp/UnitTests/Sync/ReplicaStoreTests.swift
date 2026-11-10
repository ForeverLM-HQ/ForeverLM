import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The replica's tables and its inbound apply (docs/cloudkit-schema-design.md §6.6 steps 2 and 3).
/// The projection rows an apply writes come from the test's own closure: the projection registry
/// arrives in WP4c.
@Suite("Replica store")
struct ReplicaStoreTests {
    private static func record(_ name: String, zone: String = "private/Library") -> ReplicaRecord {
        ReplicaRecord(
            zoneKey: zone, recordName: name, recordType: "Notebook", wireID: "nb-\(name)",
            systemFields: Data([1, 2, 3]), payload: Data(#"{"env":1}"#.utf8), seenPass: 812_000_000.5
        )
    }

    /// A replica file in WAL mode with a projection table whose outbox trigger fires only outside an
    /// apply, as the generated triggers will (§6.6 step 1).
    private static func replicaWithProjection() throws -> (root: URL, handle: SQLiteHandle, replica: ReplicaStore) {
        let root = try Schema154Fixture.temporaryRoot("replica")
        let handle = try SQLiteHandle(path: root.appendingPathComponent("replica.sqlite").path)
        try handle.executeScript("PRAGMA journal_mode = WAL")
        let replica = ReplicaStore(connection: handle)
        try replica.installSharedSchema()
        try handle.executeScript("""
            CREATE TABLE projection (id TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE fired (id TEXT);
            CREATE TRIGGER projection_outbox AFTER INSERT ON projection
            WHEN NOT EXISTS (SELECT 1 FROM ck_apply_guard)
            BEGIN INSERT INTO fired (id) VALUES (NEW.id); END;
        """)
        return (root, handle, replica)
    }

    @Test("The shared tables are the declared ones, and installing them twice changes nothing")
    func sharedTables() throws {
        let handle = try SQLiteHandle(path: ":memory:")
        let replica = ReplicaStore(connection: handle)
        try replica.installSharedSchema()
        try replica.installSharedSchema()
        for table in ReplicaStore.sharedTables {
            var columns: [String] = []
            try handle.query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.text(table.name)]) { columns.append($0.text(0) ?? "") }
            #expect(columns == table.columnNames, "\(table.name)")
            try handle.query(table.probe, []) { _ in }
        }
        #expect(ReplicaStore.sharedTables.count == 13)
        #expect(KnowledgeStore.macReplicaTables.count == 11)
        let replicaTables = ReplicaStore.sharedTables + KnowledgeStore.macReplicaTables
        #expect(Set(replicaTables.map(\.name)).count == 24)
        #expect(replicaTables.allSatisfy { $0.name.hasPrefix("ck_") })
    }

    @Test("An apply writes the replica and projection rows together, under a guard no other connection sees")
    func applyWritesTogether() throws {
        let (root, handle, replica) = try Self.replicaWithProjection()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try SQLiteHandle(path: root.appendingPathComponent("replica.sqlite").path)
        var guardInside = false
        var guardSeenElsewhere: Int64 = -1
        // A synchronous closure: nothing can suspend between BEGIN and COMMIT.
        let applied = try replica.apply { store -> String in
            try store.upsertRecord(Self.record("r1"))
            try handle.execute("INSERT INTO projection (id, value) VALUES ('a', 'from the record')")
            guardInside = try store.isApplying
            guardSeenElsewhere = try other.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") ?? -1
            return "done"
        }
        #expect(applied == "done")
        #expect(guardInside)
        #expect(guardSeenElsewhere == 0)
        #expect(try replica.record(zoneKey: "private/Library", recordName: "r1") == Self.record("r1"))
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM projection WHERE id = 'a'") == 1)
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM fired") == 0, "what an apply writes is never sent back")
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") == 0)
        #expect(try !replica.isApplying)
    }

    @Test("A throw inside an apply rolls back the replica row, the projection row and the guard")
    func applyRollsBack() throws {
        let (root, handle, replica) = try Self.replicaWithProjection()
        defer { try? FileManager.default.removeItem(at: root) }
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            try replica.apply { store in
                try store.upsertRecord(Self.record("r2"))
                try handle.execute("INSERT INTO projection (id, value) VALUES ('b', 'never')")
                throw Refused()
            }
        }
        #expect(try replica.record(zoneKey: "private/Library", recordName: "r2") == nil)
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM projection") == 0)
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") == 0)
        // The connection is usable again at once.
        try replica.apply { store in try store.upsertRecord(Self.record("r3")) }
        #expect(try replica.record(zoneKey: "private/Library", recordName: "r3") != nil)
    }

    @Test("Writes outside an apply, on this connection or on another between two applies, are enqueued")
    func writesOutsideAnApplyAreEnqueued() throws {
        let (root, handle, replica) = try Self.replicaWithProjection()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try SQLiteHandle(path: root.appendingPathComponent("replica.sqlite").path)
        try replica.apply { _ in try handle.execute("INSERT INTO projection (id, value) VALUES ('applied-1', 'x')") }
        try other.execute("INSERT INTO projection (id, value) VALUES ('other', 'y')")
        try handle.execute("INSERT INTO projection (id, value) VALUES ('local', 'z')")
        try replica.apply { _ in try handle.execute("INSERT INTO projection (id, value) VALUES ('applied-2', 'x')") }
        var fired: [String] = []
        try handle.query("SELECT id FROM fired ORDER BY id", []) { fired.append($0.text(0) ?? "") }
        #expect(fired == ["local", "other"])
    }

    @Test("An apply inside another transaction is refused")
    func applyIsNeverNested() throws {
        let (root, handle, replica) = try Self.replicaWithProjection()
        defer { try? FileManager.default.removeItem(at: root) }
        try handle.executeScript("BEGIN")
        #expect(throws: (any Error).self) {
            try replica.apply { _ in }
        }
        try handle.executeScript("ROLLBACK")
        #expect(try handle.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") == 0)
    }

    @Test("On the Mac the apply runs on KnowledgeStore's own connection")
    func applyOnKnowledgeStore() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.execForTesting("""
            CREATE TABLE fired (id TEXT);
            CREATE TRIGGER test_sources_outbox AFTER INSERT ON sources
            WHEN NOT EXISTS (SELECT 1 FROM ck_apply_guard)
            BEGIN INSERT INTO fired (id) VALUES (NEW.id); END;
        """)
        try store.replica.apply { replica in
            try replica.upsertRecord(ReplicaRecord(
                zoneKey: "private/Catalog", recordName: "src_x", recordType: "Source", wireID: "src-applied",
                systemFields: nil, payload: Data(#"{"env":1}"#.utf8), seenPass: nil
            ))
            try store.execForTesting("INSERT INTO sources (id, date_added) VALUES ('src-applied', 1)")
            #expect(try replica.isApplying)
        }
        try store.execForTesting("INSERT INTO sources (id, date_added) VALUES ('src-local', 2)")
        #expect(try store.replica.record(zoneKey: "private/Catalog", recordName: "src_x")?.wireID == "src-applied")
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources WHERE id IN ('src-applied', 'src-local')") == 2)
        #expect(try store.scalarText("SELECT group_concat(id) FROM fired") == "src-local")
    }

    @Test("Zones and records round-trip, text and blobs byte for byte")
    func roundTrips() throws {
        let handle = try SQLiteHandle(path: ":memory:")
        let replica = ReplicaStore(connection: handle)
        try replica.installSharedSchema()
        let zone = ReplicaZone(
            zoneKey: ReplicaZone.key(database: .shared, zoneName: "Space-x", ownerRecordName: "_owner"),
            database: .shared, zoneName: "Space-x", ownerRecordName: "_owner", kind: "space",
            primaryID: "nb-1", shareRecordName: "cloudkit.zoneshare", role: "member", permission: "readWrite",
            saltID: "3fa9c2d1", changeToken: Data([9, 8]), lastCompletePassAt: 812_000_000
        )
        try replica.upsertZone(zone)
        #expect(try replica.zone(key: zone.zoneKey) == zone)
        #expect(zone.zoneKey == "shared/_owner/Space-x")
        #expect(ReplicaZone.key(database: .private, zoneName: "Library") == "private/Library")

        var odd = Self.record("r-odd")
        odd.wireID = "id\u{0}with a NUL"
        odd.payload = Data()
        odd.systemFields = nil
        try replica.upsertRecord(odd)
        #expect(try replica.record(zoneKey: "private/Library", recordName: "r-odd") == odd)
        #expect(try replica.record(zoneKey: "private/Library", recordType: "Notebook", wireID: "id\u{0}with a NUL")?.recordName == "r-odd")
        try replica.deleteRecord(zoneKey: "private/Library", recordName: "r-odd")
        #expect(try replica.record(zoneKey: "private/Library", recordName: "r-odd") == nil)
    }

    @Test("ck_identity resolves a wire id in the preferred zones first, then in any zone")
    func identity() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.recordIdentity(zoneKey: "private/Library", recordType: "Notebook", wireID: "nb-1", localID: "nb-1")
        try store.recordIdentity(zoneKey: "shared/_owner/Space-a", recordType: "Notebook", wireID: "nb-1", localID: "proj_abc")
        #expect(try store.localID(forWire: "nb-1", recordType: "Notebook", preferring: ["shared/_owner/Space-a"]) == "proj_abc")
        #expect(try store.localID(forWire: "nb-1", recordType: "Notebook", preferring: ["private/Library"]) == "nb-1")
        #expect(try store.localID(forWire: "nb-1", recordType: "Notebook", preferring: ["shared/_x/Space-b"]) == "nb-1")
        #expect(try store.localID(forWire: "nb-1", recordType: "Chat", preferring: []) == nil)
    }
}
