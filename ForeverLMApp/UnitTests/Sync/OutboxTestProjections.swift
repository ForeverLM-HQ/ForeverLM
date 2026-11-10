import Foundation
@testable import ForeverLM

/// Test-only projections on tables of their own, with real foreign keys, for the outbox and
/// re-projection suites (docs/cloudkit-schema-design.md §5.7, §6.6): a course (`test_courses`), its
/// lessons (`test_lessons`, `course_id` cascading from the course) and the lessons' entries
/// (`test_entries`, `lesson_id` cascading from the lesson; its record is named by the lesson and the
/// item, never by its own `id`, as `learning_goal_items` is). Each table has an `opened_at` no
/// projection reads. They borrow the Course, Lesson and Entry record types and encode only fields
/// those types have.
enum OutboxTestProjections {
    static let tablesSQL = """
        CREATE TABLE IF NOT EXISTS test_courses (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            opened_at REAL
        );
        CREATE TABLE IF NOT EXISTS test_lessons (
            id TEXT PRIMARY KEY,
            course_id TEXT NOT NULL REFERENCES test_courses(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            order_key TEXT NOT NULL,
            opened_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_test_lessons_course ON test_lessons(course_id);
        CREATE TABLE IF NOT EXISTS test_entries (
            id TEXT PRIMARY KEY,
            lesson_id TEXT NOT NULL REFERENCES test_lessons(id) ON DELETE CASCADE,
            item_id TEXT NOT NULL,
            approval TEXT,
            order_key TEXT NOT NULL,
            opened_at REAL,
            UNIQUE(lesson_id, item_id)
        );
        """

    static let registry = ProjectionRegistry([Courses(), Lessons(), Entries()])

    // MARK: Stores and replicas for the suites

    static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outbox-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A generation-2 store in a folder of its own with the test tables, and their triggers unless
    /// `triggers` is false.
    static func makeStore(_ name: String, triggers: Bool = true) throws -> (root: URL, store: KnowledgeStore) {
        let root = try temporaryRoot(name)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.executeScript(tablesSQL)
        if triggers { try store.installOutboxTriggers(registry) }
        return (root, store)
    }

    static let salt = Data((0..<32).map { UInt8($0) })
    static var saltID: String { RecordNaming.saltID(salt) }
    static let libraryZoneKey = "private/Library"

    /// What the feeder needs to send to the personal library: the zone, its root with the salt, and a
    /// clock that knows its server offset (`clock: false` leaves the device without one).
    static func prepareReplica(_ store: KnowledgeStore, clock: Bool = true) throws {
        try store.replica.upsertZone(ReplicaZone(
            zoneKey: libraryZoneKey, database: .private, zoneName: "Library", kind: "library", saltID: saltID
        ))
        try store.replica.upsertRecord(ReplicaRecord(
            zoneKey: libraryZoneKey, recordName: SyncSchema.rootRecordName, recordType: SyncRecordType.zoneRoot.rawValue,
            wireID: "root", systemFields: nil,
            payload: try payload(.zoneRoot, "root", ["kind": "personal", "salt": .string(salt.base64EncodedString()), "saltID": .string(saltID)]),
            seenPass: nil
        ))
        if clock {
            try OutboxFeeder(connection: store, registry: registry).saveClock(StampClock(deviceID: "macaaaaa", offsetSamples: [0]))
        }
    }

    /// A record's stored payload as another device would have written it.
    static func payload(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON]) throws -> Data {
        var envelope = SyncEnvelope.new(type, id: id, saltID: saltID)
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields { patch.changes[field] = .value(value) }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: counter, deviceID: "otheraaa")
        }
        return try envelope.storedPayload()
    }

    /// A record of the personal library as the server delivers it.
    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], zoneKey: String = libraryZoneKey) throws -> ReplicaRecord {
        ReplicaRecord(
            zoneKey: zoneKey, recordName: RecordNaming.recordName(type: type, id: id, salt: salt), recordType: type.rawValue,
            wireID: id, systemFields: Data([1]), payload: try payload(type, id, fields), seenPass: nil
        )
    }

    /// What the server answers a save with: the envelope as sent.
    static func serverRecord(for change: OutboxChange) throws -> ReplicaRecord {
        guard case .save(let envelope) = change.action else { throw RecordPatchError.wrongRecord }
        return ReplicaRecord(
            zoneKey: change.zoneKey, recordName: change.recordName, recordType: change.recordType.rawValue,
            wireID: change.wireID, systemFields: Data([7]), payload: try envelope.storedPayload(), seenPass: nil
        )
    }

    /// `local_key|column` of every outbox field row of `table`, sorted.
    static func fieldRows(_ store: KnowledgeStore, _ table: String) throws -> [String] {
        var rows: [String] = []
        try store.query(
            "SELECT local_key, column FROM ck_outbox_fields WHERE source_table = ? ORDER BY local_key, column", [.text(table)]
        ) { rows.append("\($0.text(0) ?? "")|\($0.text(1) ?? "")") }
        return rows
    }

    /// The time an outbox field row records, in Cocoa seconds.
    static func fieldTime(_ store: KnowledgeStore, _ table: String, _ localKey: String, _ column: String) throws -> Double? {
        var time: Double?
        try store.query(
            "SELECT dirty_at FROM ck_outbox_fields WHERE source_table = ? AND local_key = ? AND column = ?",
            [.text(table), .text(localKey), .text(column)]
        ) { time = $0.real(0) }
        return time
    }

    /// A moment past every projection's 2-second debounce.
    static func afterDebounce() -> Date { Date().addingTimeInterval(5) }

    /// Whether a row of `table` with `id` exists.
    static func exists(_ connection: SQLiteConnection, _ table: String, id: String) throws -> Bool {
        try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", [.text(id)]) == 1
    }

    struct Courses: RecordProjection {
        struct Rows { let title: String; let status: String }

        var recordType: SyncRecordType { .course }
        var tables: [ProjectedTable] { [.records("test_courses", type: .course, syncedColumns: ["title", "status"])] }
        var feeds: [String: FieldFeed] {
            ["title": .columns(table: "test_courses", ["title"]), "status": .columns(table: "test_courses", ["status"])]
        }
        var missingRow: MissingRowOutcome { .delete }

        func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
            var rows: Rows?
            try connection.query("SELECT title, status FROM test_courses WHERE id = ?", [.text(record.localID)]) { row in
                rows = Rows(title: row.text(0) ?? "", status: row.text(1) ?? "")
            }
            return rows
        }

        static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
            ["title": .string(rows.title), "status": .string(rows.status)]
        }

        func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
            try connection.execute("""
                INSERT INTO test_courses (id, title, status) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, status = excluded.status
            """, [
                .text(record.localID), .text(envelope.fields["title"]?.stringValue ?? ""),
                .text(envelope.fields["status"]?.stringValue ?? "active"),
            ])
            return .projected
        }

        func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
            try connection.execute("DELETE FROM test_courses WHERE id = ?", [.text(record.localID)])
        }
    }

    struct Lessons: RecordProjection {
        struct Rows { let courseID: String; let title: String; let orderKey: String }

        var recordType: SyncRecordType { .lesson }
        var tables: [ProjectedTable] {
            [.records("test_lessons", type: .lesson, syncedColumns: ["course_id", "title", "order_key"], parents: [
                LocalParent("course_id", references: "test_courses", type: .course, role: .container),
            ])]
        }
        var feeds: [String: FieldFeed] {
            [
                "courseID": .columns(table: "test_lessons", ["course_id"]),
                "title": .columns(table: "test_lessons", ["title"]),
                "orderKey": .columns(table: "test_lessons", ["order_key"]),
            ]
        }
        var missingRow: MissingRowOutcome { .delete }

        func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
            var rows: Rows?
            try connection.query("SELECT course_id, title, order_key FROM test_lessons WHERE id = ?", [.text(record.localID)]) { row in
                rows = Rows(courseID: row.text(0) ?? "", title: row.text(1) ?? "", orderKey: row.text(2) ?? "")
            }
            return rows
        }

        static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
            ["courseID": .string(rows.courseID), "title": .string(rows.title), "orderKey": .string(rows.orderKey)]
        }

        func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
            let courseID = envelope.fields["courseID"]?.stringValue ?? ""
            guard try OutboxTestProjections.exists(connection, "test_courses", id: courseID) else {
                return .waiting([WaitingParent(type: .course, wireID: courseID)])
            }
            try connection.execute("""
                INSERT INTO test_lessons (id, course_id, title, order_key) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET course_id = excluded.course_id, title = excluded.title, order_key = excluded.order_key
            """, [
                .text(record.localID), .text(courseID), .text(envelope.fields["title"]?.stringValue ?? ""),
                .text(envelope.fields["orderKey"]?.stringValue ?? "a0"),
            ])
            return .projected
        }

        func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
            try connection.execute("DELETE FROM test_lessons WHERE id = ?", [.text(record.localID)])
        }
    }

    /// A lesson's entries: the record is `en:<lesson>:source:<item>`, so removing an item and adding
    /// it again (two `id`s) is one record, and a row that leaves while its lesson stays flips the
    /// Entry to `removed`.
    struct Entries: RecordProjection {
        struct Rows { let lessonID: String; let itemID: String; let approval: String?; let orderKey: String }

        static func entryID(lessonID: String, itemID: String) -> String {
            SyncIdentity.entryID(containerID: lessonID, itemKind: "source", itemID: itemID)
        }

        var recordType: SyncRecordType { .entry }
        var tables: [ProjectedTable] {
            [ProjectedTable(
                "test_entries", localKey: ["id"], keyColumns: ["lesson_id", "item_id"],
                syncedColumns: ["approval", "order_key"],
                parents: [LocalParent("lesson_id", references: "test_lessons", type: .lesson, role: .container)],
                recordTypes: [.entry],
                record: { values in
                    guard let lesson = values["lesson_id"]?.textValue, let item = values["item_id"]?.textValue else { return nil }
                    let id = Self.entryID(lessonID: lesson, itemID: item)
                    return RowRecord(type: .entry, localID: id, personalID: id)
                },
                localIDSQL: { "'en:' || \($0).lesson_id || ':source:' || \($0).item_id" },
                personalIDSQL: { "'en:' || \($0).lesson_id || ':source:' || \($0).item_id" }
            )]
        }
        var feeds: [String: FieldFeed] {
            [
                "state": .rowExistence(table: "test_entries"),
                "approval": .columns(table: "test_entries", ["approval"]),
                "orderKey": .columns(table: "test_entries", ["order_key"]),
                "containerID": .rowExistence(table: "test_entries"),
                "itemID": .rowExistence(table: "test_entries"),
                "containerKind": .rowExistence(table: "test_entries"),
                "itemKind": .rowExistence(table: "test_entries"),
            ]
        }
        var missingRow: MissingRowOutcome { .fields(["state": .string("removed")]) }

        /// The lesson and item an Entry id names.
        static func parts(_ wireID: String) -> (lessonID: String, itemID: String)? {
            let parts = wireID.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "en", parts[2] == "source" else { return nil }
            return (String(parts[1]), String(parts[3]))
        }

        func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows? {
            guard let parts = Self.parts(record.wireID) else { return nil }
            var rows: Rows?
            try connection.query(
                "SELECT approval, order_key FROM test_entries WHERE lesson_id = ? AND item_id = ?",
                [.text(parts.lessonID), .text(parts.itemID)]
            ) { row in
                rows = Rows(lessonID: parts.lessonID, itemID: parts.itemID, approval: row.text(0), orderKey: row.text(1) ?? "")
            }
            return rows
        }

        static func encodeRows(_ rows: Rows) -> [String: SyncJSON] {
            [
                "containerKind": .string("lesson"), "containerID": .string(rows.lessonID),
                "itemKind": .string("source"), "itemID": .string(rows.itemID),
                "state": .string("active"), "approval": rows.approval.map(SyncJSON.string) ?? .null,
                "orderKey": .string(rows.orderKey),
            ]
        }

        func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
            guard let parts = Self.parts(record.wireID) else { return .projected }
            guard envelope.fields["state"]?.stringValue != "removed" else {
                try connection.execute("DELETE FROM test_entries WHERE lesson_id = ? AND item_id = ?", [.text(parts.lessonID), .text(parts.itemID)])
                return .projected
            }
            guard try OutboxTestProjections.exists(connection, "test_lessons", id: parts.lessonID) else {
                return .waiting([WaitingParent(type: .lesson, wireID: parts.lessonID)])
            }
            try connection.execute("""
                INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(lesson_id, item_id) DO UPDATE SET approval = excluded.approval, order_key = excluded.order_key
            """, [
                .text(UUID().uuidString.lowercased()), .text(parts.lessonID), .text(parts.itemID),
                .text(envelope.fields["approval"]?.stringValue), .text(envelope.fields["orderKey"]?.stringValue ?? "a0"),
            ])
            return .projected
        }

        func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
            guard let parts = Self.parts(record.wireID) else { return }
            try connection.execute("DELETE FROM test_entries WHERE lesson_id = ? AND item_id = ?", [.text(parts.lessonID), .text(parts.itemID)])
        }
    }
}
