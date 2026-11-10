import Foundation
import Testing
@testable import ForeverLM

/// How a library activates for generation 2 (docs/cloudkit-schema-design.md §13.3 step 3), run through
/// `GenerationActivationRunner` on a migrated store. The journal's steps are `GenerationActivationTests`.
@Suite("Activation modes")
struct ActivationModeTests {
    /// A migrated library with the outbox test projections' tables, as a launch finds it before it activates.
    private struct Rig {
        let root: URL
        let store: KnowledgeStore
        var access: DirectStoreAccess { DirectStoreAccess(store: store) }

        init() throws {
            root = try Schema154Fixture.temporaryRoot("activation-modes")
            try Schema154Fixture.makeLibrary(at: root, version: nil)
            Schema154Fixture.newLaunch(root)
            store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            try store.executeScript(OutboxTestProjections.tablesSQL)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// What schema 175 leaves in a library generation 1 had synced: a `deferred` journal at its first
        /// step (`KnowledgeStore.recordGeneration1HistoryInActivationJournal`).
        func giveHistory() throws {
            try store.exec("INSERT INTO ck_activation (id, step, mode, started_at) VALUES (1, 'copy', 'deferred', 1) ON CONFLICT(id) DO UPDATE SET step = excluded.step, mode = excluded.mode, started_at = excluded.started_at")
        }

        func recoveredDocs() throws -> [String] {
            var ids: [String] = []
            try store.query("SELECT id FROM global_artifacts WHERE id LIKE 'recovered:%' ORDER BY id", []) { ids.append($0.text(0) ?? "") }
            return ids
        }

        func body(_ id: String) throws -> String? { try store.loadArtifactMarkdownForSync(id) }
    }

    private static func environment() -> ActivationEnvironment {
        var environment = ActivationEnvironment()
        environment.status = ActivationStatus()
        environment.derivations = []
        environment.registry = OutboxTestProjections.registry
        return environment
    }

    private static func run(_ rig: Rig, _ environment: ActivationEnvironment) async throws -> ActivationJournal {
        try await GenerationActivationRunner(access: rig.access, environment: environment).run()
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: fresh and deferred

    @Test("A store with no journal mode activates fresh")
    func freshWithoutHistory() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let environment = Self.environment()
        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == .fresh && journal.freshReason == .noHistory)
        #expect(journal.activatedAt != nil)
        #expect(environment.status.current == .done)
    }

    @Test("A store generation 1 synced activates deferred, sending nothing and claiming nothing until its library is confirmed")
    func historyActivatesDeferred() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.giveHistory()

        let environment = Self.environment()
        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == .deferred && journal.activatedAt != nil && journal.catchUpAt == nil)
        #expect(journal.sendsWaitForCatchUp)
        #expect(environment.status.current == .done)
    }

    // MARK: Start order

    @Test("The MCP server and the relay start only after activated_at: the gate holds them until the activation opens it")
    func gateHoldsTheServer() async throws {
        let gate = GenerationActivationGate()
        await gate.close()
        let reached = Flag()
        let waiter = Task {
            await gate.waitUntilOpen()
            reached.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reached.isSet)
        await gate.open()
        await waiter.value
        #expect(reached.isSet)
        let open = GenerationActivationGate()
        await open.waitUntilOpen()
    }

    @Test("A gate made closed holds from the first instant, with no close() call to be late for (F28)")
    func gateBornClosedHolds() async throws {
        let gate = GenerationActivationGate(isOpen: false)
        let reached = Flag()
        let waiter = Task {
            await gate.waitUntilOpen()
            reached.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!reached.isSet, "a writer that starts before the launcher closes anything is held")
        await gate.open()
        await waiter.value
        #expect(reached.isSet)
    }

    // MARK: Held bodies (R8-m8)

    @Test("A document.remote.md becomes one Recovered Doc before the derivations in every mode, and the file is gone once that Doc is projected",
          arguments: [false, true])
    func heldRemoteBodyBecomesARecoveredDoc(hasHistory: Bool) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.store.saveArtifactRecord(ArtifactRecord(
            id: "doc-h", title: "Held", homeNotebookID: nil, linkedNotebookIDs: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 100), updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        ))
        try rig.store.saveArtifactMarkdownAsSynced("# Mine\n", artifactID: "doc-h")
        try rig.store.saveArtifactHeldRemoteMarkdown("# The other writer's\n", artifactID: "doc-h")
        var environment = Self.environment()
        environment.derivations = KnowledgeStore.activationDerivations
        if hasHistory { try rig.giveHistory() }

        let journal = try await Self.run(rig, environment)
        #expect(journal.mode == (hasHistory ? .deferred : .fresh))
        let recoveredID = RecoveredDoc.id(artifactID: "doc-h", hash: SyncIdentity.sha256Hex(Data("# The other writer's\n".utf8)))
        #expect(try rig.recoveredDocs() == [recoveredID])
        #expect(try rig.body(recoveredID) == "# The other writer's\n")
        #expect(try rig.store.loadArtifactHeldRemoteMarkdown("doc-h") == nil, "the held body is removed once its Doc is projected")
        #expect(try rig.body("doc-h") == "# Mine\n")
    }
}

extension KnowledgeStore {
    /// A Doc body as a sync round leaves it: document.md and the merge base beside it.
    func saveArtifactMarkdownAsSynced(_ markdown: String, artifactID: String) throws {
        try writeArtifactMarkdown(markdown, artifactID: artifactID)
        try saveArtifactBaseMarkdown(markdown, artifactID: artifactID)
    }
}
