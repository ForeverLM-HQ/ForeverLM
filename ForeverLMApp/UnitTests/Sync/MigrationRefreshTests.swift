import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The refresh (docs/cloudkit-schema-design.md §13.4 step 0, WP16b2): before it reconciles or takes over a seed
/// whose root holds a base, a Mac fetches the old zones' changes from the tokens in its own snapshot and applies
/// them as patches for the records the server does not hold, advances its snapshot once they are acknowledged, and
/// asks Apply or Keep when more than 5% of what its snapshot names would go. The old world is another Mac's
/// generation-1 store writing a `FakeCloudKit` old container; this Mac's tables and snapshot stand as its own walk
/// left them (`MigrationOwnViewFixture`).
@Suite("Migration refresh")
struct MigrationRefreshTests {
    private typealias Rig = MigrationImportRig

    private static func later() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private static func entryID(_ notebookID: String, _ sourceID: String) -> String {
        SyncIdentity.entryID(containerID: notebookID, itemKind: "source", itemID: sourceID)
    }

    // MARK: Nothing to refresh

    @Test("A Mac with no snapshot has nothing to refresh, and neither has one that reads nothing from the old zones")
    func nothingToRefresh() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mine")
        #expect(try await rig.refresh() == .nothingToRefresh, "a fresh or deferred Mac before its catch-up has no snapshot")

        try await rig.ownSnapshot()
        try rig.activate(.fresh)
        var journal = try #require(try rig.store.activationJournal())
        journal.freshReason = .knowledgeMissing
        try rig.store.writeActivationJournal(journal)
        #expect(try await rig.refresh() == .nothingToRefresh, "a knowledgeMissing store never reads the old zones for itself again")
    }

    @Test("No refresh runs before this Mac's fetch of Library and Catalog is complete")
    func fetchGate() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mine")
        try await rig.ownSnapshot()
        var library = try #require(try rig.store.replica.zone(key: Rig.N.libraryZoneKey))
        library.lastCompletePassAt = nil
        try rig.store.replica.upsertZone(library)
        #expect(try await rig.refresh() == .notReady)
    }

    // MARK: From its own snapshot

    @Test("The refresh patches a record only this Mac's rows hold from the changes since its walk, and a second refresh starts from the first's acknowledged snapshot (R5-m12)")
    func patchesFromOwnSnapshot() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mitochondria")
        try rig.syncedHere(.learningGoal, notebook)
        try await rig.ownSnapshot()
        let first = try #require(try await rig.ownToken())
        try await Self.later()
        try rig.rename(notebook, to: "Renamed after the walk")

        let report = try await rig.refreshed()
        #expect(report.changed == 1 && report.failed.isEmpty, "\(report)")
        let patch = try #require(try rig.patch(.notebook, notebook))
        #expect(patch.changes["title"]?.stringValue?.contains("Renamed after the walk") == true)
        guard case .value(let stamp)? = patch.stamps["title"] else { Issue.record("title has no stamp"); return }
        #expect(stamp.deviceID == SyncIdentity.legacyDeviceID, "stamped with the old record's date by the migration's device")
        #expect(try await rig.ownToken() == first, "the snapshot waits for the acknowledgement")
        #expect(try await rig.refresh() == .waitingForAcknowledgement, "an earlier refresh's patches are on their way")

        try await rig.sendPatches()
        let second = try await rig.refreshed()
        #expect(second.changed == 0, "the second refresh starts from where the first ended: \(second)")
        #expect(try await rig.ownToken() != first, "the snapshot's token advanced")
    }

    @Test("A gap edit and a gap deletion made between this Mac's walk and the base are neither reverted nor resurrected (R4-3, R7-x1)")
    func gap() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Gap")
        try rig.source("s1")
        try rig.source("s2")
        try rig.file("s1", into: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.source, "s2")
        try rig.syncedHere(.learningGoal, notebook)
        try await rig.ownSnapshot()
        try await Self.later()
        // The gap: the old world renamed the notebook and took s1 out of it, then Mac A walked and seeded.
        try rig.rename(notebook, to: "Gap rename")
        try rig.unfile("s1", from: notebook)
        try await rig.seed()
        // Mac A renamed it on build N, and an old iPhone filed another source afterwards.
        try rig.newWorldEdit(.notebook, notebook, ["title": "Mac A's title"], ms: SyncTime.milliseconds(Date().addingTimeInterval(86_400)))
        try await Self.later()
        try rig.file("s2", into: notebook)

        let report = try await rig.refreshed(guardLifted: true)
        #expect(report.removals == 1 && report.creates == 1, "\(report)")
        #expect(try !rig.hasEntryRow(notebook, "s1"), "the deletion in the gap is not resurrected: this Mac's rows lose the Entry")
        #expect(try rig.patch(.entry, Self.entryID(notebook, "s1")) == nil, "and nothing is queued for a server that never held it")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] == nil && rig.localTitle(notebook) == "Mac A's title", "the edit is not reverted: the server holds the notebook")
        #expect(try rig.patch(.entry, Self.entryID(notebook, "s2")) != nil, "the filed source arrives")

        try await rig.imported(.other)
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] == nil && rig.localTitle(notebook) == "Mac A's title", "nor by the import pass that follows")
    }

    @Test("What the refresh creates is listed in a manifest delta once acknowledged, so a record deleted later stays deleted (R5-3)")
    func delta() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Chats")
        try rig.chat("chat-1", in: notebook)
        try rig.syncedHere(.learningGoal, notebook)
        try rig.syncedHere(.reviewSession, "chat-1")
        try await rig.ownSnapshot()
        try await Self.later()
        try rig.addTurn(to: "chat-1", question: "A turn since the walk")

        let report = try await rig.refreshed()
        #expect(report.creates == 1, "\(report)")
        #expect(try rig.manifestPending() == 1 && rig.ledger.deltas.isEmpty, "nothing is listed before the server has it")
        try await rig.sendPatches()
        try await rig.refreshed()
        let key = try #require(rig.ledger.deltas.keys.first)
        #expect(key.hasPrefix("\(Rig.deviceID).") && rig.ledger.deltas[key]?.contains { $0.type == .exchange } == true)
        #expect(try rig.manifestPending() == 0)
    }

    // MARK: The 5% guard (R7-m3, R8-m5)

    private func guardRig() async throws -> (rig: Rig, notebook: String) {
        let rig = try Rig()
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
        for id in sources.prefix(5) { try rig.unfile(id, from: notebook) }
        return (rig, notebook)
    }

    @Test("A refresh that would remove more than 5% of what its snapshot names asks, applies nothing and keeps the Mac from going on; Apply runs it once")
    func guardApply() async throws {
        let (rig, notebook) = try await guardRig()
        defer { rig.cleanUp() }

        guard case .guardTripped(let question) = try await rig.refresh() else { Issue.record("the guard did not trip"); return }
        #expect(question.removing == 5 && question.of >= 10 && question.answer == nil, "\(question)")
        #expect(try await rig.local.perform { try MigrationImportState.waitingQuestion($0.connection) } != nil, "Settings shows it")
        #expect(try await rig.local.perform { try MigrationImportState.guardQuestion($0.connection, pass: .importPass) } == nil, "the importer's own question is another")
        #expect(try rig.hasEntryRow(notebook, "src-0"), "nothing applied")
        #expect(try await rig.refresh() == .waitingForQuestion)

        try await rig.local.perform { try MigrationImportState.answer(.apply, $0.connection) }
        let report = try await rig.refreshed()
        #expect(report.removals == 5, "\(report)")
        #expect(try !rig.hasEntryRow(notebook, "src-0") && rig.hasEntryRow(notebook, "src-9"))
        #expect(try await rig.local.perform { try MigrationImportState.guardQuestion($0.connection, pass: .refresh) } == nil, "the answer is consumed")
    }

    @Test("Keep applies the rest, lists the removals as kept and moves the snapshot past them; the answer is never Not this library")
    func guardKeep() async throws {
        let (rig, notebook) = try await guardRig()
        defer { rig.cleanUp() }
        try rig.rename(notebook, to: "Renamed meanwhile")

        guard case .guardTripped = try await rig.refresh() else { Issue.record("the guard did not trip"); return }
        try await rig.local.perform { try MigrationImportState.answer(.keep, $0.connection) }
        let report = try await rig.refreshed()
        #expect(report.removals == 0 && report.kept >= 5, "\(report)")
        #expect(try rig.hasEntryRow(notebook, "src-0"), "the Entries stay")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] != nil, "the rest of the pass applies")
        let kept = try await rig.local.perform { try MigrationImportState.kept($0.connection) }
        #expect(kept.filter { $0.reason == .keptByAnswer && $0.type == "Entry" }.count == 5)

        try await rig.sendPatches()
        let again = try await rig.refreshed()
        #expect(again.removals == 0 && again.kept == 0, "the snapshot moved past the kept removals: \(again)")
    }
}
