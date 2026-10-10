import Foundation
import Testing
@testable import ForeverLM

/// Nothing depends on the order records arrive in (docs/cloudkit-schema-design.md §5.7): a record
/// whose local parent is missing waits in `ck_unprojected` and is projected when the parent's row
/// arrives, and a record a cascade took from the local tables comes back with its parent. Pinned on
/// the test-only course, lesson and entry projections, whose tables have real foreign keys. WP7 to
/// WP12b add their own projections' cases to their own suites.
@Suite("Apply out of order")
struct ApplyOutOfOrderTests {
    private typealias Fixture = OutboxTestProjections

    private static func apply(_ store: KnowledgeStore, _ records: [ReplicaRecord]) throws {
        try store.replica.apply { replica in
            let projections = ProjectionApply(store: store, registry: Fixture.registry)
            for record in records {
                try replica.upsertRecord(record)
                try projections.project(record)
            }
            try projections.drainReady()
        }
    }

    private static func applyDeletion(_ store: KnowledgeStore, _ type: SyncRecordType, _ id: String) throws {
        let name = RecordNaming.recordName(type: type, id: id, salt: Fixture.salt)
        try store.replica.apply { replica in
            try ProjectionApply(store: store, registry: Fixture.registry)
                .projectDeletion(zoneKey: Fixture.libraryZoneKey, recordName: name, type: type, wireID: id)
            try replica.deleteRecord(zoneKey: Fixture.libraryZoneKey, recordName: name)
            try ProjectionApply(store: store, registry: Fixture.registry).drainReady()
        }
    }

    private static let course = { try Fixture.record(.course, "c1", ["title": "Cells", "status": "active"]) }
    private static let lesson = { try Fixture.record(.lesson, "l1", ["courseID": "c1", "title": "One", "orderKey": "a0"]) }
    private static let entry = {
        try Fixture.record(.entry, Fixture.Entries.entryID(lessonID: "l1", itemID: "src-1"), [
            "containerKind": "lesson", "containerID": "l1", "itemKind": "source", "itemID": "src-1",
            "state": "active", "approval": "approved", "orderKey": "a0",
        ])
    }

    private static func count(_ store: KnowledgeStore, _ sql: String) throws -> Int64 {
        try store.scalarInteger(sql) ?? -1
    }

    @Test("A child applied before its parent is projected when the parent arrives, a whole chain in reverse")
    func childBeforeParent() throws {
        let (root, store) = try Fixture.makeStore("reverse")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)

        try Self.apply(store, [try Self.entry()])
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries") == 0, "the entry waits for its lesson")
        try Self.apply(store, [try Self.lesson()])
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_lessons") == 0, "the lesson waits for its course")
        var waits: [String] = []
        try store.query("SELECT waiting_on_type || ':' || waiting_on_id || ':' || ready FROM ck_unprojected ORDER BY 1", []) {
            waits.append($0.text(0) ?? "")
        }
        #expect(waits == ["Course:c1:0", "Lesson:l1:0"])

        try Self.apply(store, [try Self.course()])
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_courses WHERE id = 'c1'") == 1)
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_lessons WHERE id = 'l1' AND course_id = 'c1'") == 1, "the course freed the lesson")
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries WHERE lesson_id = 'l1' AND approval = 'approved'") == 1, "the lesson freed the entry")
        #expect(try Self.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try Self.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0, "nothing projected under the guard is sent back")
    }

    @Test("Child and parent in one apply, child first, end projected")
    func childFirstInOneApply() throws {
        let (root, store) = try Fixture.makeStore("one-apply")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.apply(store, [try Self.entry(), try Self.lesson(), try Self.course()])
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries") == 1)
        #expect(try Self.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
    }

    enum Removal: String, CaseIterable { case localCascade, inboundCascade }
    enum Return: String, CaseIterable { case localWrite, apply }

    @Test("Rows a cascade removed come back when the parent row is inserted again", arguments: Removal.allCases, Return.allCases)
    func cascadeComesBack(removal: Removal, comeback: Return) throws {
        let (root, store) = try Fixture.makeStore("cascade-\(removal.rawValue)-\(comeback.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.apply(store, [try Self.course(), try Self.lesson(), try Self.entry()])
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries") == 1)

        switch removal {
        case .localCascade:
            try store.executeScript("DELETE FROM test_courses WHERE id = 'c1'")
        case .inboundCascade:
            try Self.applyDeletion(store, .course, "c1")
        }
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_lessons") == 0, "the cascade took the lesson")
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries") == 0, "and the entry")
        var waits: [String] = []
        try store.query("SELECT waiting_on_type || ':' || waiting_on_id FROM ck_unprojected ORDER BY 1", []) {
            waits.append($0.text(0) ?? "")
        }
        #expect(waits == ["Course:c1", "Lesson:l1"], "the records the replica still holds wait for their parents: \(waits)")

        switch comeback {
        case .localWrite:
            try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
            #expect(try store.drainReadyProjections(Fixture.registry) >= 1)
        case .apply:
            try Self.apply(store, [try Self.course()])
        }
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_lessons WHERE id = 'l1'") == 1, "the lesson is back")
        #expect(try Self.count(store, "SELECT COUNT(*) FROM test_entries WHERE lesson_id = 'l1'") == 1, "and the entry with it")
        #expect(try Self.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try Fixture.fieldRows(store, "test_lessons").allSatisfy { $0.contains("\u{1F}") }, "re-projected under the guard: no change of its own")
    }

    @Test("A record whose type no projection reads stays raw and waits for nothing")
    func unknownTypeStaysRaw() throws {
        let (root, store) = try Fixture.makeStore("raw")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let idea = try Fixture.record(.idea, "idea-1", ["kind": "idea", "title": "An idea", "status": "open"])
        var outcome: ProjectionApplyOutcome?? = .none
        try store.replica.apply { replica in
            try replica.upsertRecord(idea)
            outcome = try ProjectionApply(store: store, registry: Fixture.registry).project(idea)
        }
        #expect(outcome == .some(nil), "not projected")
        #expect(try store.replica.record(zoneKey: Fixture.libraryZoneKey, recordName: idea.recordName) != nil, "kept in the replica")
    }

    @Test("Projecting outside an apply is refused, so nothing it writes is ever sent back")
    func projectingNeedsTheGuard() throws {
        let (root, store) = try Fixture.makeStore("guard")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProjectionApply.Failure.outsideApply) {
            try ProjectionApply(store: store, registry: Fixture.registry).project(try Self.course())
        }
    }
}
