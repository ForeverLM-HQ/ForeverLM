import Foundation
import Testing
@testable import ForeverLM

/// The generation-2 activation's journal and the steps every mode shares (D46, D49,
/// docs/cloudkit-schema-design.md §13.3 step 3), and generation 1's side of it (D40, §13.2). The modes'
/// launch behaviour (the read-only window, the fallbacks, the catch-up) is `ActivationModeTests` (WP16a).
@Suite("Generation activation")
struct GenerationActivationTests {
    private typealias Fixture = OutboxTestProjections

    /// A library left by a generation-1 build at `version`, opened by generation 2 as the next launch
    /// would: the open copies it to `knowledge.pre-v2.db` and migrates it.
    private static func generation2Store(_ name: String, version: Int32? = 153) throws -> (root: URL, store: KnowledgeStore) {
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

    @Test("The mode is decided once and recorded: no history is fresh without asking the account")
    func modeIsRecorded() async throws {
        var asked = 0
        let fresh = await GenerationActivation.decideMode(hasHistory: false) { asked += 1; return .unavailable }
        #expect(fresh == .freshNoHistory)
        #expect(asked == 0, "a store with no generation-1 history asks nothing of the network")
        let full = await GenerationActivation.decideMode(hasHistory: true) { .signedIn(userRecordName: "_8f2c") }
        #expect(full == ActivationModeDecision(mode: .full, freshReason: nil, account: "_8f2c"))
        let deferred = await GenerationActivation.decideMode(hasHistory: true) { .unavailable }
        #expect(deferred == ActivationModeDecision(mode: .deferred, freshReason: nil, account: nil))

        let (root, store) = try Self.generation2Store("mode")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM sync_metadata") ?? 0 > 0, "local writes leave sync_metadata rows")
        #expect(try GenerationActivation.hasGeneration1History(store) == false, "but a library that never synced has no history")
        try store.executeScript("UPDATE sync_metadata SET system_fields = X'00' WHERE rowid = (SELECT MIN(rowid) FROM sync_metadata)")
        #expect(try GenerationActivation.hasGeneration1History(store), "one record the server knows is history")
        let journal = try Self.activation(store).run(full)
        #expect(journal.mode == .full && journal.account == "_8f2c" && journal.freshReason == nil)
        #expect(try store.activationJournal() == journal)
    }

    @Test("A fresh activation makes no network call, to either container")
    func freshMakesNoNetworkCall() async throws {
        let server = FakeCloudKit()
        let legacy = server.transport(user: "_learner", container: FakeCloudKit.legacyContainer, device: "mac")
        _ = server.transport(user: "_learner", container: FakeCloudKit.libraryContainer, device: "mac")
        let (root, store) = try Self.generation2Store("fresh-offline")
        defer { try? FileManager.default.removeItem(at: root) }

        let decision = await GenerationActivation.decideMode(hasHistory: try GenerationActivation.hasGeneration1History(store)) {
            await GenerationActivation.account(of: legacy)
        }
        let journal = try Self.activation(store).run(decision)
        #expect(journal.mode == .fresh && journal.freshReason == .noHistory)
        #expect(journal.activatedAt != nil, "activated at once")
        #expect(server.calls.isEmpty, "no call reached the server: \(server.calls.map(\.operation))")

        // The same check with generation-1 history asks the old container, and only it.
        let withHistory = await GenerationActivation.decideMode(hasHistory: true) {
            await GenerationActivation.account(of: legacy)
        }
        #expect(withHistory == ActivationModeDecision(mode: .full, freshReason: nil, account: "_learner"))
        #expect(server.calls.map(\.operation) == [.accountStatus, .userRecordName])
        #expect(server.calls.allSatisfy { $0.container == FakeCloudKit.legacyContainer })
        server.resetCalls()
        server.signIn(legacy, as: nil)
        let signedOut = await GenerationActivation.decideMode(hasHistory: true) {
            await GenerationActivation.account(of: legacy)
        }
        #expect(signedOut.mode == .deferred, "history and no account: deferred")
    }

    @Test("The copy step 1 took is recorded with the user_version read from the copy")
    func copyIsRecorded() throws {
        let (root, store) = try Self.generation2Store("copy", version: 153)
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
