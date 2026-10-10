import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// What runs before a Mac reconciles or takes over a seed (docs/cloudkit-schema-design.md §13.4 steps 0 and 1,
/// §13.5, WP16b2): its refresh, then one import pass from the shared base, and neither while a question waits
/// (R8-m5). The cases that need WP16's `CutoverReconcile` and `CutoverSeeder` (an old-world edit that survives the
/// reconcile, a record late-imported and then deleted that a later Mac does not re-upload, a pre-canary takeover,
/// a record created between two walks that is uploaded, a deferred Mac's offline rename that survives its reconcile,
/// R8-m1's dropped patch) are `ReconcileImportPassTests` cases of that package's wiring and are not built here: the
/// refresh and the deferred catch-up that feed them are pinned by `MigrationRefreshTests` and
/// `MigrationDeferredCatchUpTests`, and this suite pins the two passes in their order with what they hand the caller.
@Suite("Reconcile import pass")
struct ReconcileImportPassTests {
    private typealias Rig = MigrationImportRig

    private static func later() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private static func entryID(_ notebookID: String, _ sourceID: String) -> String {
        SyncIdentity.entryID(containerID: notebookID, itemKind: "source", itemID: sourceID)
    }

    private func passes(_ rig: Rig) -> MigrationCutoverPasses {
        MigrationCutoverPasses(store: rig.local, gate: StoreMigrationFetchGate(store: rig.local), refresh: rig.refresher(), importPass: rig.importer())
    }

    @Test("An old-world edit this Mac's walk saw before the importer imported it reaches the patches through the import pass")
    func importPassBringsWhatTheBaseLacks() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try rig.syncedHere(.learningGoal, notebook)
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Renamed after the base")
        try await rig.ownSnapshot()

        let result = try await passes(rig).run(role: .other)
        #expect(result.proceeds)
        guard case .refreshed(let refreshed)? = result.refresh else { Issue.record("no refresh: \(String(describing: result.refresh))"); return }
        #expect(refreshed.changed == 0, "this Mac's snapshot already holds the edit: \(refreshed)")
        guard case .imported(let imported)? = result.imported else { Issue.record("no import pass: \(String(describing: result.imported))"); return }
        #expect(imported.changed == 1 && imported.advanced == false, "\(imported)")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"]?.stringValue?.contains("Renamed after the base") == true, "the edit is a pending change before the reconcile")
        #expect(rig.base.advances == 0, "a Mac that reconciles never moves the base")
    }

    @Test("After a takeover the Mac is the importer: the base and the tokens advance once its patches are acknowledged")
    func takeoverImports() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try await rig.seed()
        try await Self.later()
        try rig.rename(notebook, to: "Renamed meanwhile")

        let proceeds = try await passes(rig).afterTakeover()
        #expect(proceeds)
        #expect(try rig.patch(.notebook, notebook) != nil && rig.base.advances == 0, "its patches carry every old-world change since the base's tokens")
        try await rig.sendPatches()
        _ = try await passes(rig).afterTakeover()
        #expect(rig.base.advances >= 1, "and the base moves once they are acknowledged")
    }

    @Test("While the refresh's or the import pass's question waits, the Mac neither reconciles, takes over nor sends")
    func questionHolds() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Pool")
        let sources = (0..<10).map { "src-\($0)" }
        for id in sources {
            try rig.source(id)
            try rig.file(id, into: notebook)
            try rig.syncedHere(.source, id)
        }
        try rig.syncedHere(.learningGoal, notebook)
        try await rig.ownSnapshot()
        try await Self.later()
        // The gap: the old world took five sources out before Mac A walked and seeded, so the server never held those Entries.
        for id in sources.prefix(5) { try rig.unfile(id, from: notebook) }
        try await rig.seed()

        let first = try await passes(rig).run(role: .other)
        #expect(!first.proceeds, "the refresh tripped its guard")
        guard case .guardTripped? = first.refresh else { Issue.record("the refresh did not ask: \(String(describing: first.refresh))"); return }
        #expect(first.imported == nil, "the import pass never ran")

        let second = try await passes(rig).run(role: .other)
        #expect(!second.proceeds && second.refresh == nil && second.imported == nil, "nothing runs while the question waits")
        #expect(try await passes(rig).beforeReconcile() == false)

        try await rig.local.perform { try MigrationImportState.answer(.apply, $0.connection) }
        let third = try await passes(rig).run(role: .other)
        #expect(third.proceeds || third.imported != nil, "the learner's answer lets it go on: \(third)")
    }

    @Test("A pass does not run before this Mac's fetch is complete, and a changed account stops it")
    func gates() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mitochondria")
        try await rig.seed()
        var library = try #require(try rig.store.replica.zone(key: Rig.N.libraryZoneKey))
        library.lastCompletePassAt = nil
        try rig.store.replica.upsertZone(library)
        await #expect(throws: MigrationCutoverPasses.Failure.fetchIncomplete) { try await passes(rig).beforeReconcile() }

        library.lastCompletePassAt = 1
        try rig.store.replica.upsertZone(library)
        try rig.activate(.full, account: "another-account")
        await #expect(throws: MigrationCutoverPasses.Failure.accountChanged) { try await passes(rig).beforeReconcile() }
    }

    @Test("A Mac whose root holds no base has nothing to import from, and goes on")
    func noBase() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mitochondria")
        let result = try await passes(rig).run(role: .other)
        #expect(result.proceeds && result.imported == .notReady)
    }
}
