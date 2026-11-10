import Foundation
import Testing
@testable import ForeverLM

/// The generation-2 activation's journal and the steps every mode shares (D46, D49,
/// docs/cloudkit-schema-design.md §13.3 step 3), and schema 175, which records generation 1's history in
/// the journal and drops its tables. The modes' launch behaviour is `ActivationModeTests` (WP16a).
@Suite("Generation activation")
struct GenerationActivationTests {
    private typealias Fixture = OutboxTestProjections

    /// A library left by a generation-1 build at `version`, opened by generation 2 as the next launch
    /// would: the open copies it to `knowledge.pre-v2.db` and migrates it.
    private static func generation2Store(_ name: String, version: Int32? = 174) throws -> (root: URL, store: KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot(name)
        try Schema154Fixture.makeLibrary(at: root, version: version)
        Schema154Fixture.newLaunch(root)
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
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

    @Test("A fresh activation makes no network call, to either container")
    func freshMakesNoNetworkCall() async throws {
        let server = FakeCloudKit()
        _ = server.transport(user: "_learner", container: FakeCloudKit.legacyContainer, device: "mac")
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
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try Schema154Fixture.restoreGeneration1Tables(store)
        try store.executeScript(extraSQL)
        try store.execForTesting("PRAGMA user_version = 174")
        Schema154Fixture.newLaunch(root)
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
        _ = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
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
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        #expect(try store.scalarInteger("PRAGMA user_version") == 175)
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
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
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
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        let journal = try #require(try store.activationJournal())
        #expect(journal.mode == .full && journal.step == .activated && journal.activatedAt != nil)
        #expect(try Schema154Fixture.count(store, Self.generation1TableCount) == 0)
    }

    @Test("The copy step 1 took is recorded with the user_version read from the copy")
    func copyIsRecorded() throws {
        let (root, store) = try Self.generation2Store("copy", version: 174)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.scalarInteger("PRAGMA user_version") == Int64(KnowledgeStore.schemaVersion), "the store itself migrated")
        #expect(Schema154Fixture.scalar(at: root, "PRAGMA user_version", file: "knowledge.pre-v2.db") == "153")
        let journal = try Self.activation(store).run(.freshNoHistory)
        #expect(journal.clonePath == "knowledge.pre-v2.db")
        #expect(journal.cloneUserVersion == 153)
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
        #expect(stopped.clonePath == "knowledge.pre-v2.db", "the steps before it are recorded")

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
            Schema154Fixture.newLaunch(twiceRoot)
            let twice = try KnowledgeStore(storeDirectory: twiceRoot, freeSpace: Schema154Fixture.roomy)

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
}
