import Foundation
import Testing
@testable import ForeverLM

/// The generation-2 activation's journal and the steps every mode shares (D46, D49,
/// docs/cloudkit-schema-design.md §13.3 step 3), schema 175, which records generation 1's history in
/// the journal and drops its tables, and schema 176, which drops what nothing uses and renames the body-send table. The modes' launch behaviour is `ActivationModeTests` (WP16a).
@Suite("Generation activation")
struct GenerationActivationTests {
    private typealias Fixture = OutboxTestProjections

    /// A library at `version` with no activation yet, opened as the next launch would: the open migrates
    /// it.
    private static func generation2Store(_ name: String, version: Int32? = 174) throws -> (root: URL, store: KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot(name)
        try Schema154Fixture.makeLibrary(at: root, version: version)
        let store = try KnowledgeStore(storeDirectory: root)
        try store.executeScript(Fixture.tablesSQL)
        return (root, store)
    }

    private static func activation(_ store: KnowledgeStore) -> GenerationActivation {
        var activation = GenerationActivation(store: store)
        activation.registry = Fixture.registry
        return activation
    }

    @Test("The mode is decided once and recorded: a journal with no mode activates fresh")
    func modeIsRecorded() async throws {
        let (root, store) = try Self.generation2Store("mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let decision = GenerationActivationRunner(access: DirectStoreAccess(store: store), environment: ActivationEnvironment()).decideMode()
        #expect(decision == .freshNoHistory)
        let journal = try Self.activation(store).run(decision)
        #expect(journal.mode == .fresh && journal.freshReason == .noHistory && journal.account == nil)
        #expect(try store.activationJournal() == journal)
        // A recorded mode is kept: a second run with another decision changes nothing.
        #expect(try Self.activation(store).run(ActivationModeDecision(mode: .deferred, freshReason: nil, account: nil)) == journal)
    }

    @Test("A fresh activation makes no network call")
    func freshMakesNoNetworkCall() async throws {
        let server = FakeCloudKit()
        _ = server.transport(user: "_learner", container: FakeCloudKit.libraryContainer, device: "mac")
        let (root, store) = try Self.generation2Store("fresh-offline")
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = try Self.activation(store).run(.freshNoHistory)
        #expect(journal.mode == .fresh && journal.freshReason == .noHistory)
        #expect(journal.activatedAt != nil, "activated at once")
        #expect(server.calls.isEmpty, "no call reached the server: \(server.calls.map(\.operation))")
    }

    // MARK: Schema 175: generation 1's tables go

    /// A library at schema 174 as the last generation-1 build left it: today's store with generation 1's
    /// tables back (the only difference between 174 and 175), `extraSQL` run on it, stamped 174. The next
    /// open migrates it.
    private static func schema174Library(_ name: String, extraSQL: String) throws -> URL {
        let root = try Schema154Fixture.temporaryRoot(name)
        try Schema154Fixture.makeLibrary(at: root, version: nil)
        let store = try KnowledgeStore(storeDirectory: root)
        try Schema154Fixture.restoreGeneration1Tables(store)
        try store.executeScript(extraSQL)
        try store.execForTesting("PRAGMA user_version = 174")
        return root
    }

    private static let generation1TableCount = """
        SELECT COUNT(*) FROM sqlite_master WHERE name IN ('sync_changes', 'sync_metadata', 'sync_conflicts',
            'sync_asset_digests', 'sync_engine_states', 'source_sync_repair_queue', 'review_session_sync_repair_queue',
            'idx_sync_metadata_zone', 'idx_sync_conflicts_detected')
        """

    @Test("A fresh store has none of generation 1's tables")
    func freshStoreHasNoGeneration1Tables() throws {
        let root = try Schema154Fixture.temporaryRoot("175-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try KnowledgeStore(storeDirectory: root)
        #expect(Schema154Fixture.count(at: root, Self.generation1TableCount) == 0)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
    }

    @Test("Schema 175 records a synced library's history as a deferred journal, then drops generation 1's tables")
    func schema175RecordsHistoryAndDrops() async throws {
        let root = try Self.schema174Library("175-history", extraSQL: """
            INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at)
            VALUES ('preference', 'history.marker', 'Preference-history', X'00', 1),
                   ('preference', 'local.only', 'Preference-local', NULL, 1);
            INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at)
            VALUES ('preference', 'history.marker', 'Preference-history', 'save', 2);
            INSERT INTO sync_engine_states (scope, state_serialization) VALUES ('private', X'01');
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources")
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, Self.generation1TableCount) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources") == sources, "no library row is touched")
        let journal = try #require(try store.activationJournal())
        #expect(journal.mode == .deferred && journal.step == .recordCopy && journal.activatedAt == nil && journal.startedAt != nil)

        try store.executeScript(OutboxTestProjections.tablesSQL)
        var environment = ActivationEnvironment()
        environment.status = ActivationStatus()
        environment.derivations = []
        environment.registry = OutboxTestProjections.registry
        let activated = try await GenerationActivationRunner(access: DirectStoreAccess(store: store), environment: environment).run()
        #expect(activated.mode == .deferred && activated.activatedAt != nil, "the runner keeps the recorded mode")
    }

    @Test("Schema 175 leaves no journal for history generation 1 cleared at sign-out, and turns an unfinished full journal deferred",
          arguments: ["signedOut", "full"])
    func schema175Journals(_ shape: String) throws {
        let extra = shape == "signedOut"
            ? "INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at) VALUES ('preference', 'x', 'Preference-x', NULL, 1);"
            : "INSERT OR REPLACE INTO ck_activation (id, step, mode, account, started_at) VALUES (1, 'catchUp', 'full', '_8f2c', 1);"
        let root = try Self.schema174Library("175-\(shape)", extraSQL: extra)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try Schema154Fixture.count(store, Self.generation1TableCount) == 0)
        let journal = try store.activationJournal()
        if shape == "signedOut" {
            #expect(journal?.mode == nil, "a library with no record the server knows activates fresh")
        } else {
            #expect(journal?.mode == .deferred && journal?.step == .catchUp && journal?.account == "_8f2c")
        }
    }

    @Test("Schema 175 never touches an activated journal")
    func schema175KeepsAnActivatedJournal() throws {
        let root = try Self.schema174Library("175-activated", extraSQL: """
            INSERT OR REPLACE INTO ck_activation (id, step, mode, started_at, activated_at) VALUES (1, 'activated', 'full', 1, 2);
            INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at)
            VALUES ('preference', 'history.marker', 'Preference-history', X'00', 1);
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let journal = try #require(try store.activationJournal())
        #expect(journal.mode == .full && journal.step == .activated && journal.activatedAt != nil)
        #expect(try Schema154Fixture.count(store, Self.generation1TableCount) == 0)
    }

    @Test("Opening and activating a library takes no rollback copy and records none")
    func noCopyIsTaken() throws {
        let (root, store) = try Self.generation2Store("copy", version: 174)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion), "the store itself migrated")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-v2.db").path))
        let journal = try Self.activation(store).run(.freshNoHistory)
        #expect(journal.activatedAt != nil)
        #expect(journal.clonePath == nil && journal.cloneUserVersion == nil)
    }

    @Test("A Release build activates with no rollback build: none is named or recorded")
    func noRollbackBuild() throws {
        let (root, store) = try Self.generation2Store("release")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.activation(store).run(.freshNoHistory)
        #expect(journal.activatedAt != nil)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM ck_activation WHERE rollback_build IS NOT NULL OR rollback_schema IS NOT NULL") == 0)
    }

    @Test("The journal resumes at its step after a kill")
    func resumesAfterAKill() throws {
        let (root, store) = try Self.generation2Store("resume")
        defer { try? FileManager.default.removeItem(at: root) }
        final class Runs: @unchecked Sendable {
            var counts: [String: Int] = [:]
            var killDuring: String? = "two"
        }
        let runs = Runs()
        var activation = Self.activation(store)
        activation.derivations = ["one", "two", "three"].map { id in
            ActivationDerivation(id: id) { store in
                runs.counts[id, default: 0] += 1
                if runs.killDuring == id {
                    runs.killDuring = nil
                    throw KnowledgeStoreError.invalidData("the app was killed during \(id)")
                }
                try store.execute("""
                    INSERT INTO test_courses (id, title) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title
                """, [.text(id), .text("from \(id)")])
            }
        }
        #expect(throws: (any Error).self) { try activation.run(ActivationModeDecision(mode: .deferred, freshReason: nil, account: nil)) }
        let stopped = try #require(try store.activationJournal())
        #expect(stopped.step == .derive("two") && stopped.activatedAt == nil)

        let finished = try activation.run(.freshNoHistory)
        #expect(runs.counts == ["one": 1, "two": 2, "three": 1], "it resumed at two: \(runs.counts)")
        #expect(finished.mode == .deferred, "the recorded mode stands")
        #expect(finished.step == .activated && finished.activatedAt != nil && finished.derivedAt != nil)
        #expect(finished.triggerHash == OutboxTriggerSQL.hash(OutboxTriggerSQL.triggers(for: Fixture.registry, wireKeyedTables: Set(KnowledgeStore.wireKeyedTables))))
        #expect(try !store.installedOutboxTriggers().isEmpty)
        #expect(try activation.run(nil) == finished, "an activated store runs nothing again")
    }

    @Test("Every registered step run twice gives one result")
    func stepsAreIdempotent() throws {
        // The registered derivations, and one of the test's own so the check is never empty.
        let steps = KnowledgeStore.activationDerivations + [
            ActivationDerivation(id: "test.wireIDs") { store in
                try store.executeScript("BEGIN IMMEDIATE")
                try store.executeScript("UPDATE sources SET wire_id = id WHERE wire_id IS NULL")
                try store.executeScript("COMMIT")
            },
        ]
        for step in steps {
            let (onceRoot, once) = try Self.generation2Store("once-\(step.id)")
            defer { try? FileManager.default.removeItem(at: onceRoot) }
            let twiceRoot = try Schema154Fixture.temporaryRoot("twice-\(step.id)")
            defer { try? FileManager.default.removeItem(at: twiceRoot) }
            try once.executeScript("PRAGMA wal_checkpoint(TRUNCATE)")
            try FileManager.default.removeItem(at: twiceRoot)
            try FileManager.default.copyItem(at: onceRoot, to: twiceRoot)
            for side in ["knowledge.db-wal", "knowledge.db-shm"] {
                try? FileManager.default.removeItem(at: twiceRoot.appendingPathComponent(side))
            }
            let twice = try KnowledgeStore(storeDirectory: twiceRoot)

            try step.run(once)
            try step.run(twice)
            try step.run(twice)
            #expect(try Self.dump(once) == Self.dump(twice), "\(step.id)")
        }
    }

    /// Every row of every table but the full-text index's, as text, for comparing two stores.
    private static func dump(_ store: KnowledgeStore) throws -> [String] {
        var tables: [String] = []
        try store.query("""
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%fts%' ORDER BY name
        """, []) { tables.append($0.text(0) ?? "") }
        var rows: [String] = []
        for table in tables {
            var columns: [String] = []
            try store.query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [.text(table)]) { columns.append($0.text(0) ?? "") }
            guard !columns.isEmpty else { continue }
            let row = columns.map { "quote(\"\($0)\")" }.joined(separator: " || '|' || ")
            try store.query("SELECT '\(table)|' || \(row) FROM \"\(table)\" ORDER BY 1", []) { rows.append($0.text(0) ?? "") }
        }
        return rows
    }

    // MARK: Schema 176: the dead objects go, the body-send table is renamed

    private static let deadObjectCount = """
        SELECT COUNT(*) FROM sqlite_master WHERE name IN ('artifact_collaboration', 'idx_artifact_collaboration_zone',
            'journal_watch_excluded_notebooks', 'paper_figure_markdown_repair_queue',
            'idx_paper_figure_markdown_repair_order', 'ck_legacy_snapshot', 'ck_legacy_bodies')
        """
    private static let deadVideoColumnCount =
        "SELECT COUNT(*) FROM pragma_table_info('videos') WHERE name = 'legacy_cap_verified_at'"

    /// A library as a build at `version` (174 or 175) left it: today's store with the five dead objects
    /// back, holding rows, and the body-send table under its old name, stamped `version`.
    private static func schemaBefore176Library(_ name: String, version: Int32) throws -> URL {
        let root = try Schema154Fixture.temporaryRoot(name)
        try Schema154Fixture.makeLibrary(at: root, version: nil)
        let store = try KnowledgeStore(storeDirectory: root)
        if version == 174 { try Schema154Fixture.restoreGeneration1Tables(store) }
        try store.executeScript("""
            DROP TABLE ck_body_sends;
            CREATE TABLE ck_legacy_bodies (record_type TEXT NOT NULL, wire_id TEXT NOT NULL, field TEXT NOT NULL,
                base_hash TEXT, base_text TEXT, sent_at REAL, PRIMARY KEY (record_type, wire_id, field));
            INSERT INTO ck_legacy_bodies (record_type, wire_id, field, sent_at) VALUES ('Artifact', 'doc-1', 'body', 7), ('Artifact', 'doc-2', 'body', 8);
            INSERT INTO ck_legacy_bodies (record_type, wire_id, field, base_hash, base_text) VALUES ('Notebook', 'nb-1', 'notes', 'h', 'base');
            CREATE TABLE artifact_collaboration (artifact_id TEXT PRIMARY KEY, database_scope TEXT NOT NULL, zone_name TEXT NOT NULL,
                owner_name TEXT NOT NULL, share_record_name TEXT, permission TEXT NOT NULL, is_owner INTEGER NOT NULL DEFAULT 0,
                last_body_revision TEXT, updated_at REAL NOT NULL);
            CREATE INDEX idx_artifact_collaboration_zone ON artifact_collaboration(database_scope, owner_name, zone_name);
            INSERT INTO artifact_collaboration (artifact_id, database_scope, zone_name, owner_name, permission, updated_at)
            VALUES ('doc-1', 'shared', 'z', 'o', 'readWrite', 1);
            CREATE TABLE journal_watch_excluded_notebooks (notebook_id TEXT PRIMARY KEY, excluded_at REAL NOT NULL);
            INSERT INTO journal_watch_excluded_notebooks VALUES ('nb-1', 1);
            CREATE TABLE paper_figure_markdown_repair_queue (source_id TEXT PRIMARY KEY, enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT);
            CREATE INDEX idx_paper_figure_markdown_repair_order ON paper_figure_markdown_repair_queue(attempt_count, enqueued_at);
            INSERT INTO paper_figure_markdown_repair_queue (source_id, enqueued_at) VALUES ('s-1', 1);
            CREATE TABLE ck_legacy_snapshot (old_zone TEXT NOT NULL, record_name TEXT NOT NULL, change_tag TEXT, field_hashes TEXT,
                PRIMARY KEY (old_zone, record_name));
            INSERT INTO ck_legacy_snapshot (old_zone, record_name) VALUES ('Knowledge', 'Source-1');
            ALTER TABLE videos ADD COLUMN legacy_cap_verified_at REAL;
            INSERT INTO videos (source_id, url, legacy_cap_verified_at) SELECT id, 'https://example.org/video', 2 FROM sources LIMIT 1;
            """)
        try store.execForTesting("PRAGMA user_version = \(version)")
        return root
    }

    @Test("A fresh store has none of schema 176's dead objects and holds the renamed table")
    func freshStoreHasNoDeadObjects() throws {
        let root = try Schema154Fixture.temporaryRoot("176-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try KnowledgeStore(storeDirectory: root)
        #expect(Schema154Fixture.count(at: root, Self.deadObjectCount) == 0)
        #expect(Schema154Fixture.count(at: root, Self.deadVideoColumnCount) == 0)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ck_body_sends'") == 1)
    }

    @Test("Schema 176 drops the dead objects and keeps the body-send rows, from 174 and from 175", arguments: [Int32(174), Int32(175)])
    func schema176DropsAndRenames(_ version: Int32) throws {
        let root = try Self.schemaBefore176Library("176-from-\(version)", version: version)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources")
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, Self.deadObjectCount) == 0)
        #expect(try Schema154Fixture.count(store, Self.deadVideoColumnCount) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM videos") == 1, "the video row stays")
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ck_body_sends'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_body_sends") == 3)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_body_sends WHERE record_type = 'Artifact' AND field = 'body' AND sent_at IN (7, 8)") == 2)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM ck_body_sends WHERE base_hash = 'h' AND base_text = 'base'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources") == sources, "no library row is touched")
        _ = try store.scalarInteger("SELECT COUNT(*) FROM source_projection")
    }

    // MARK: Schema 177: a notebook's own Board lists

    @Test("Schema 177 adds the Board's lists and a task's list to a 176 store, keeping its tasks")
    func schema177AddsBoardLists() throws {
        let root = try Schema154Fixture.temporaryRoot("177-from-176")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: nil)
        do {
            // A 176 store: no lists table, no `list_id`, one task.
            let store = try KnowledgeStore(storeDirectory: root)
            try store.executeScript("""
                DROP TABLE notebook_task_lists;
                ALTER TABLE notebook_tasks DROP COLUMN list_id;
                INSERT INTO notebook_tasks (id, notebook_id, title, created_at, updated_at) VALUES ('task-1', 'nb-1', 'Read', 1, 1);
                """)
            try store.execForTesting("PRAGMA user_version = 176")
        }
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('notebook_tasks') WHERE name = 'list_id'") == 0)
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM pragma_table_info('notebook_tasks') WHERE name = 'list_id'") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM notebook_task_lists") == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM notebook_tasks WHERE id = 'task-1' AND list_id IS NULL") == 1)
    }

    // MARK: Schema 179: the learner's chat skills are gone

    @Test("Schema 179 drops a 178 store's skills table and its index, rows and all")
    func schema179DropsSkills() throws {
        let root = try Schema154Fixture.temporaryRoot("179-from-178")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: nil)
        do {
            // A 178 store: the skills table, its index and one skill.
            let store = try KnowledgeStore(storeDirectory: root)
            try store.executeScript("""
                CREATE TABLE skills (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL,
                    instructions TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                CREATE INDEX idx_skills_name ON skills(name, updated_at DESC);
                INSERT INTO skills VALUES ('s1', 'outline', 'Headings', 'Make them.', 1, 1);
                """)
            try store.execForTesting("PRAGMA user_version = 178")
        }
        let skillObjects = "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('skills', 'idx_skills_name')"
        #expect(Schema154Fixture.count(at: root, skillObjects) == 2)
        let sources = Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources")
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, skillObjects) == 0)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM sources") == sources, "no library row is touched")
    }

    // MARK: Schema 180: a mark's follow-up flag, apart from its color

    @Test("Schema 180 adds follow_up_at and flags a 179 store's blue and pink marks as of when they were made")
    func schema180FlagsOpenColors() throws {
        let root = try Schema154Fixture.temporaryRoot("180-from-179")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: nil)
        do {
            // A 179 store: no `follow_up_at`, one mark of each kind.
            let store = try KnowledgeStore(storeDirectory: root)
            try store.executeScript("""
                ALTER TABLE source_highlights DROP COLUMN follow_up_at;
                INSERT INTO source_highlights (highlight_id, source_id, page_index, quads_json, text, color, created_at, updated_at)
                VALUES ('hl-blue', 's1', 0, '[]', 'Blue', 'blue', 10, 11),
                       ('hl-pink', 's1', 0, '[]', 'Pink', 'pink', 20, 21),
                       ('hl-yellow', 's1', 0, '[]', 'Yellow', 'yellow', 30, 31);
                """)
            try store.execForTesting("PRAGMA user_version = 179")
        }
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('source_highlights') WHERE name = 'follow_up_at'") == 0)
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion))
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_highlights WHERE highlight_id = 'hl-blue' AND follow_up_at = 10") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_highlights WHERE highlight_id = 'hl-pink' AND follow_up_at = 20") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_highlights WHERE highlight_id = 'hl-yellow' AND follow_up_at IS NULL") == 1)
        #expect(try Schema154Fixture.count(store, "SELECT COUNT(*) FROM source_highlights WHERE updated_at IN (11, 21, 31)") == 3, "the flag is no edit")
    }
}
