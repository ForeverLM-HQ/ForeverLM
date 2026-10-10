import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The outbox triggers and the feeder that reads them (docs/cloudkit-schema-design.md §6.6, D9, D32),
/// on the test-only course, lesson and entry projections (`OutboxTestProjections`).
@Suite("Outbox triggers")
struct OutboxTriggerTests {
    private typealias Fixture = OutboxTestProjections

    /// Stands in for `StorageService`: the store belongs to one actor, as the storage actor owns it.
    private actor StorageStandIn {
        let store: KnowledgeStore
        var queued: Task<Void, Error>?

        init(store: KnowledgeStore) { self.store = store }

        /// An apply during which another write is queued on this actor: the write can only run once the
        /// apply's transaction has ended, since nothing in the apply suspends (§6.6 step 2).
        func applyWhileAWriteIsQueued() throws {
            try store.replica.apply { _ in
                queued = Task { try self.write("queued") }
                try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('applied', 'From the server')")
            }
        }

        func write(_ id: String) throws {
            try store.execute("INSERT INTO test_courses (id, title) VALUES (?, 'Local')", [.text(id)])
        }
    }

    @Test("A write through the MCP store's own connection lands in the outbox; an apply under the guard does not")
    func mcpConnectionAndApply() throws {
        let (root, store) = try Fixture.makeStore("mcp")
        defer { try? FileManager.default.removeItem(at: root) }
        let mcp = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        try mcp.withDB { db in
            #expect(sqlite3_exec(db, "INSERT INTO test_courses (id, title) VALUES ('from-mcp', 'Written by a tool')", nil, nil, nil) == SQLITE_OK)
        }
        try store.replica.apply { _ in
            try store.executeScript("""
                INSERT INTO test_courses (id, title) VALUES ('from-server', 'Applied');
                UPDATE test_courses SET title = 'Applied again' WHERE id = 'from-server';
            """)
        }
        #expect(try Fixture.fieldRows(store, "test_courses") == ["from-mcp|__row"])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox") == 0)
    }

    @Test("An MCP-connection write between two applies is enqueued, and so is a write queued on the storage actor during an apply")
    func writesAroundAnApply() async throws {
        let (root, store) = try Fixture.makeStore("around")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try store.executeScript("DELETE FROM ck_outbox_fields")
        let mcp = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        try store.replica.apply { _ in try store.executeScript("UPDATE test_courses SET title = 'Applied 1' WHERE id = 'c1'") }
        try mcp.withDB { db in
            #expect(sqlite3_exec(db, "UPDATE test_courses SET status = 'archived' WHERE id = 'c1'", nil, nil, nil) == SQLITE_OK)
        }
        try store.replica.apply { _ in try store.executeScript("UPDATE test_courses SET title = 'Applied 2' WHERE id = 'c1'") }
        #expect(try Fixture.fieldRows(store, "test_courses") == ["c1|status"])

        let standIn = StorageStandIn(store: store)
        try await standIn.applyWhileAWriteIsQueued()
        try await standIn.queued?.value
        #expect(try Fixture.fieldRows(store, "test_courses") == ["c1|status", "queued|__row"])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_apply_guard") == 0)
    }

    @Test("A write to a column no projection reads, and a same-value full-row save, fire nothing")
    func unreadColumnsAndSameValues() throws {
        let (root, store) = try Fixture.makeStore("unread")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try store.executeScript("DELETE FROM ck_outbox_fields")
        try store.executeScript("""
            UPDATE test_courses SET opened_at = 812000000 WHERE id = 'c1';
            UPDATE test_courses SET title = 'Cells', status = 'active' WHERE id = 'c1';
            INSERT INTO test_courses (id, title, status) VALUES ('c1', 'Cells', 'active')
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, status = excluded.status;
        """)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields") == 0)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox") == 0)
        try store.executeScript("UPDATE test_courses SET title = 'Cells and energy' WHERE id = 'c1'")
        #expect(try Fixture.fieldRows(store, "test_courses") == ["c1|title"], "a changed column records itself, and only itself")
    }

    @Test("An INSERT writes only __row, whose time every column takes, and a row deleted and inserted again takes the insert time everywhere")
    func insertTimes() throws {
        let (root, store) = try Fixture.makeStore("insert")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let feeder = OutboxFeeder(connection: store, registry: Fixture.registry)

        try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        #expect(try Fixture.fieldRows(store, "test_courses") == ["c1|__row"])
        let inserted = try #require(try Fixture.fieldTime(store, "test_courses", "c1", "__row"))
        Thread.sleep(forTimeInterval: 0.02)
        try store.executeScript("UPDATE test_courses SET title = 'Cells, revised' WHERE id = 'c1'")
        let edited = try #require(try Fixture.fieldTime(store, "test_courses", "c1", "title"))
        let create = try #require(try feeder.nextBatch(now: Fixture.afterDebounce()).first)
        #expect(create.stamps[StampedPath("status")]?.milliseconds == SyncTime.milliseconds(cocoaSeconds: inserted),
                "a column that never changed takes the insert time")
        #expect(create.stamps[StampedPath("title")]?.milliseconds == SyncTime.milliseconds(cocoaSeconds: edited),
                "a column that changed takes its own time")
        try feeder.acknowledgeSave(create, serverRecord: try Fixture.serverRecord(for: create))

        // Edit, delete, insert again: no column keeps a time from before the delete.
        try store.executeScript("UPDATE test_courses SET status = 'archived' WHERE id = 'c1'")
        Thread.sleep(forTimeInterval: 0.02)
        try store.executeScript("DELETE FROM test_courses WHERE id = 'c1'")
        Thread.sleep(forTimeInterval: 0.02)
        try store.executeScript("INSERT INTO test_courses (id, title, status) VALUES ('c1', 'Cells, again', 'archived')")
        let reinserted = try #require(try Fixture.fieldTime(store, "test_courses", "c1", "__row"))
        let again = try #require(try feeder.nextBatch(now: Fixture.afterDebounce()).first)
        #expect(again.action != .delete, "the record is sent as it is now, not deleted")
        for field in ["title", "status"] {
            #expect(again.stamps[StampedPath(field)]?.milliseconds == SyncTime.milliseconds(cocoaSeconds: reinserted), "\(field)")
        }
    }

    @Test("A deleted row carries its record key")
    func deletedRowCarriesItsRecordKey() throws {
        let (root, store) = try Fixture.makeStore("removal")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.executeScript("""
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
            INSERT INTO test_lessons (id, course_id, title, order_key) VALUES ('l1', 'c1', 'One', 'a0');
            INSERT INTO test_entries (id, lesson_id, item_id, order_key) VALUES ('row-7', 'l1', 'src-1', 'a0');
            DELETE FROM test_entries WHERE id = 'row-7';
        """)
        var removals: [String] = []
        try store.query("SELECT local_key, record_key_json, op FROM ck_outbox WHERE source_table = 'test_entries'", []) {
            removals.append("\($0.text(0) ?? "")|\($0.text(1) ?? "")|\($0.text(2) ?? "")")
        }
        let key = #"{"lesson_id":"l1","item_id":"src-1"}"#
        #expect(removals == ["row-7\u{1F}\(key)|\(key)|delete"], "the row is gone; its record key is not")
        #expect(try Fixture.fieldRows(store, "test_entries").contains("row-7\u{1F}\(key)|__row"))
    }

    @Test("A remove and a re-add under different local keys are sent as one record, with each field's latest time, and acknowledged together")
    func removeAndReAdd() throws {
        let (root, store) = try Fixture.makeStore("readd")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let feeder = OutboxFeeder(connection: store, registry: Fixture.registry)
        try store.executeScript("""
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
            INSERT INTO test_lessons (id, course_id, title, order_key) VALUES ('l1', 'c1', 'One', 'a0');
            INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('first', 'l1', 'src-1', 'pending', 'a0');
        """)
        for change in try feeder.nextBatch(now: Fixture.afterDebounce()) {
            try feeder.acknowledgeSave(change, serverRecord: try Fixture.serverRecord(for: change))
        }
        try store.executeScript("DELETE FROM test_entries WHERE id = 'first'")
        Thread.sleep(forTimeInterval: 0.02)
        try store.executeScript("INSERT INTO test_entries (id, lesson_id, item_id, approval, order_key) VALUES ('second', 'l1', 'src-1', 'approved', 'a0')")
        let readded = try #require(try Fixture.fieldTime(store, "test_entries", "second", "__row"))

        let batch = try feeder.nextBatch(now: Fixture.afterDebounce())
        let entryID = Fixture.Entries.entryID(lessonID: "l1", itemID: "src-1")
        #expect(batch.map(\.wireID) == [entryID], "one record for both local keys")
        let entry = try #require(batch.first)
        guard case .save(let envelope) = entry.action else {
            Issue.record("a save, since the row is back")
            return
        }
        #expect(envelope.fields["approval"] == "approved" && envelope.fields["state"] == "active", "encoded once, from the current row")
        #expect(entry.stamps[StampedPath("approval")]?.milliseconds == SyncTime.milliseconds(cocoaSeconds: readded))
        #expect(Set(entry.rows.map(\.localKey)).count == 2, "both local keys' rows are this change's")
        try feeder.acknowledgeSave(entry, serverRecord: try Fixture.serverRecord(for: entry))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields") == 0)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox") == 0)
    }

    @Test("A bulk insert of 10k rows writes one field row per row and none per column, at a small cost per row")
    func bulkInsert() throws {
        let rows = 10_000
        func insertLessons(_ store: KnowledgeStore) throws -> Double {
            try store.executeScript("INSERT INTO test_courses (id, title) VALUES ('bulk', 'Bulk')")
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(store.db, "INSERT INTO test_lessons (id, course_id, title, order_key) VALUES (?, 'bulk', ?, 'a0')", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let start = ContinuousClock.now
            try store.executeScript("BEGIN IMMEDIATE")
            for index in 0..<rows {
                SQLiteText.bind(statement, 1, "lesson-\(index)")
                SQLiteText.bind(statement, 2, "Lesson \(index) of a long course")
                #expect(sqlite3_step(statement) == SQLITE_DONE)
                sqlite3_reset(statement)
            }
            try store.executeScript("COMMIT")
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        var plain: [Double] = []
        var triggered: [Double] = []
        for round in 0..<3 {
            let (plainRoot, plainStore) = try Fixture.makeStore("bulk-plain-\(round)", triggers: false)
            let (root, store) = try Fixture.makeStore("bulk-\(round)")
            defer {
                try? FileManager.default.removeItem(at: plainRoot)
                try? FileManager.default.removeItem(at: root)
            }
            plain.append(try insertLessons(plainStore))
            triggered.append(try insertLessons(store))
            #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'test_lessons'") == Int64(rows))
            #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'test_lessons' AND column <> '__row'") == 0)
            #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_outbox") == 0)
        }
        // The triggers' own cost, the statement prepared once. A store that prepares every statement also
        // compiles the triggers into each one, and an import that commits every row also writes the
        // outbox's pages each time; docs/cloudkit-schema-design.md's WP4c corrections give those numbers.
        let perRow = (triggered.min()! - plain.min()!) / Double(rows) * 1e6
        print("OutboxTriggerTests.bulkInsert: \(rows) rows, plain \(plain.min()!) s, with triggers \(triggered.min()!) s, \(perRow) us per row")
        #expect(perRow < 25, "the triggers add \(perRow) us per inserted row")
    }

    @Test("No registered table is written with INSERT OR REPLACE or REPLACE INTO outside the migrations below 154")
    func noReplaceIntoRegisteredTables() throws {
        let scanner = ReplaceScanner(tables: Set(KnowledgeStore.projectionRegistry.tableNames))
        let findings = try scanner.findings(inSourcesUnder: Self.appFolder)
        #expect(findings.isEmpty, "convert these to INSERT … ON CONFLICT DO UPDATE: \(findings)")

        // The scanner itself: a replace into a registered table is found, in either spelling and case,
        // and one inside a migration step below 154 is not.
        let sample = ReplaceScanner(tables: ["hidden_sources", "test_courses"])
        let replace = ["INSERT OR", "REPLACE INTO"].joined(separator: " ")
        let text = """
            func save() { try execBind("\(replace) hidden_sources (source_id, hidden_at) VALUES (?, ?)") { _ in } }
            func other() { try exec("replace into "test_courses" (id) VALUES ('x')") }
            func unrelated() { try exec("\(replace) embeddings (id) VALUES (1)") }
            func migrate() {
                if currentVersion < 150 {
                    try exec("\(replace) hidden_sources (source_id, hidden_at) VALUES ('a', 1)")
                }
                if currentVersion < 155 {
                    try exec("\(replace) test_courses (id) VALUES ('b')")
                }
            }
            """
        let found = sample.findings(in: text, file: "KnowledgeStore+Schema.swift")
        #expect(found.map(\.table) == ["hidden_sources", "test_courses", "test_courses"], "\(found)")
    }

    private static var appFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sync
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
    }
}

/// Finds `INSERT OR REPLACE INTO` and `REPLACE INTO` a set of tables in Swift sources (§6.6 step 1):
/// SQLite fires only the INSERT trigger for a replace, which would re-date every column of the row.
/// The shipped migration steps below 154 in `KnowledgeStore+Schema.swift` never run on an activated
/// store and are left as released.
struct ReplaceScanner {
    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let table: String
        var description: String { "\(file):\(line) \(table)" }
    }

    let tables: Set<String>

    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:INSERT\s+OR\s+REPLACE|REPLACE)\s+INTO\s+["`\[]?([A-Za-z_][A-Za-z0-9_]*)"#,
        options: [.caseInsensitive]
    )
    private static let migrationStep = try! NSRegularExpression(pattern: #"if\s+currentVersion\s*<\s*(\d+)\s*\{"#)

    func findings(inSourcesUnder folder: URL) throws -> [Finding] {
        guard !tables.isEmpty else { return [] }
        var findings: [Finding] = []
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/.build/") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            findings += self.findings(in: text, file: url.lastPathComponent)
        }
        return findings
    }

    func findings(in text: String, file: String) -> [Finding] {
        let source = text as NSString
        let exempt = file == "KnowledgeStore+Schema.swift" ? Self.migrationStepsBelow154(source) : []
        var findings: [Finding] = []
        for match in Self.pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let table = source.substring(with: match.range(at: 1))
            guard tables.contains(table), !exempt.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
            let line = source.substring(to: match.range.location).components(separatedBy: "\n").count
            findings.append(Finding(file: file, line: line, table: table))
        }
        return findings
    }

    /// The bodies of `if currentVersion < N {` blocks with N up to 153, by brace matching.
    private static func migrationStepsBelow154(_ source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        for match in migrationStep.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            guard let version = Int(source.substring(with: match.range(at: 1))), version < 154 else { continue }
            var depth = 0
            var index = match.range.location + match.range.length - 1
            let start = index
            while index < source.length {
                let character = source.character(at: index)
                if character == 123 { depth += 1 }
                if character == 125 {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            ranges.append(NSRange(location: start, length: index - start + 1))
        }
        return ranges
    }
}
