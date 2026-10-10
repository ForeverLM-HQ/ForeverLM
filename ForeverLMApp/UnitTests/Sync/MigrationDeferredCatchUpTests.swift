import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The deferred catch-up (docs/cloudkit-schema-design.md §13.3 `deferred`, §13.4 step 0, WP16b2): a Mac with
/// generation-1 history whose catch-up waited for its account walks the old zones against its own
/// `sync_metadata`, and writes patches for what the server does not hold. The old world is another Mac's
/// generation-1 store writing a `FakeCloudKit` old container; this Mac's tables stand as its last sync left them
/// (`MigrationOwnViewFixture`). Cases that need WP16's reconcile (`CutoverReconcile`: what the Mac then uploads or
/// deletes) are not here.
@Suite("Migration deferred catch-up")
struct MigrationDeferredCatchUpTests {
    private typealias Rig = MigrationImportRig

    /// A moment later than the last sync, so an old-world edit is stamped after it.
    private static func later() async throws { try await Task.sleep(nanoseconds: 30_000_000) }

    private static func entryID(_ notebookID: String, _ sourceID: String) -> String {
        SyncIdentity.entryID(containerID: notebookID, itemKind: "source", itemID: sourceID)
    }

    private static func oldName(_ entity: CloudKitSyncEntity, _ key: String) -> String {
        CloudKitRecordMapper.recordName(for: entity, logicalKey: key)
    }

    // MARK: Per record

    @Test("A changed old record is applied as patches stamped with the old date; an unchanged one is left alone; the walk is kept")
    func changedRecordIsApplied() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alpha = try rig.notebook("Alpha")
        let beta = try rig.notebook("Beta")
        try rig.syncedHere(.learningGoal, alpha)
        try rig.syncedHere(.learningGoal, beta)
        try rig.activate(.deferred)
        try await Self.later()
        try rig.rename(alpha, to: "Alpha renamed")

        let report = try await rig.caughtUp()
        #expect(report.applied == 1 && report.unchanged == 1 && report.failed.isEmpty, "\(report)")
        let patch = try #require(try rig.patch(.notebook, alpha))
        #expect(patch.changes["title"]?.stringValue?.contains("Alpha renamed") == true)
        guard case .value(let stamp)? = patch.stamps["title"] else { Issue.record("title has no stamp"); return }
        #expect(stamp.deviceID == SyncIdentity.legacyDeviceID && stamp.policy == .lastWriter, "the migration's device, the old record's date")
        #expect(try rig.localTitle(alpha)?.contains("Alpha renamed") == true, "projected under the guard")
        #expect(try rig.patch(.notebook, beta) == nil, "an unchanged record writes nothing")

        #expect(try rig.catchUpAt() != nil, "ck_activation.catch_up_at records the walk")
        #expect(try rig.hasSnapshotRows() && report.snapshotRows >= 2, "this Mac's snapshot")
        #expect(try await rig.ownToken() != nil, "and its token")
    }

    @Test("A pending change later than the old record's date keeps the local values; an earlier one takes the old world's",
          arguments: [3600.0, -3600.0])
    func pendingRule(offset: Double) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Original")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try await Self.later()
        try rig.rename(notebook, to: "From the old world")
        let old = try rig.oldRecord(.learningGoal, notebook)
        // This Mac's edit is generation 1's: a row change with a pending change dated `offset` from the old record's,
        // made before the activation. An edit made after it would queue its own, newer change and win either way.
        try Rig.N.quietly(rig.store) { try rig.store.execute("UPDATE learning_goals SET title = 'Mine here' WHERE id = ?", [.text(notebook)]) }
        try rig.pendingOldChange(.learningGoal, notebook, at: old.oldModifiedAt.addingTimeInterval(offset))

        let report = try await rig.caughtUp()
        if offset > 0 {
            #expect(report.keptLocal == 1 && report.applied == 0, "\(report)")
            #expect(try rig.localTitle(notebook) == "Mine here" && rig.patch(.notebook, notebook) == nil)
        } else {
            #expect(report.applied == 1 && report.keptLocal == 0, "\(report)")
            #expect(try rig.localTitle(notebook)?.contains("From the old world") == true)
        }
    }

    // MARK: What the old world dropped or deleted (R5-4, R6-1)

    @Test("A source the old world took out of a notebook while this Mac was offline is removed here, and an Entry added since the activation stays")
    func droppedChildIsRemoved() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Filing")
        try rig.source("s1")
        try rig.source("s2")
        try rig.file("s1", into: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.source, "s2")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try Rig.N.file(rig.store, "s2", into: notebook)
        #expect(try rig.hasEntryRow(notebook, "s2"), "the learner filed s2 here after the activation")
        try await Self.later()
        try rig.unfile("s1", from: notebook)

        let report = try await rig.caughtUp()
        #expect(report.removals == 1 && report.kept == 1, "\(report)")
        #expect(try !rig.hasEntryRow(notebook, "s1"), "the old world dropped it")
        #expect(try rig.patch(.entry, Self.entryID(notebook, "s1")) == nil, "and nothing is queued for a server that never held it")
        #expect(try rig.hasEntryRow(notebook, "s2"), "an Entry with an unsent change of this Mac's own stays")
        let kept = try await rig.local.perform { try MigrationImportState.kept($0.connection) }
        #expect(kept.contains { $0.type == "Entry" && $0.reason == .editedInNewWorld })
    }

    @Test("What the server holds is never removed from this Mac's view: a notebook and a chat the old world deleted stay for the importer")
    func serverHeldStays() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Shared")
        try rig.source("s1")
        try rig.file("s1", into: notebook)
        try rig.chat("chat-1", in: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.syncedHere(.reviewSession, "chat-1")
        try rig.activate(.deferred)
        let exchange = try #require(try rig.store.scalarText("SELECT id FROM review_exchanges WHERE session_id = 'chat-1'"))
        for (type, id) in [(SyncRecordType.notebook, notebook), (.chat, "chat-1"), (.exchange, exchange), (.entry, Self.entryID(notebook, "s1"))] {
            try rig.serverReceives(type, id)
        }
        try await rig.deleteFromOldWorld(Self.oldName(.learningGoal, notebook))
        try await rig.deleteFromOldWorld(Self.oldName(.reviewSession, "chat-1"))

        let report = try await rig.caughtUp(guardLifted: true)
        #expect(report.deletions == 2 && report.removals == 0, "\(report)")
        #expect(try rig.rowCount("SELECT COUNT(*) FROM learning_goals WHERE id = ?", [.text(notebook)]) == 1)
        #expect(try rig.rowCount("SELECT COUNT(*) FROM review_sessions WHERE id = 'chat-1'") == 1)
        #expect(try rig.hasEntryRow(notebook, "s1") && rig.rowCount("SELECT COUNT(*) FROM review_exchanges WHERE session_id = 'chat-1'") == 1)
        #expect(try rig.patchCount() == 0, "nothing is patched or deleted for records the server holds")
    }

    @Test("What the old world deleted is removed here where the server holds nothing, per-member state kept")
    func deletedRecordIsRemoved() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Gone")
        try rig.source("s1")
        try rig.file("s1", into: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try await rig.deleteFromOldWorld(Self.oldName(.learningGoal, notebook))

        let report = try await rig.caughtUp(guardLifted: true)
        #expect(report.deletions == 1 && report.removals >= 1, "\(report)")
        #expect(try rig.rowCount("SELECT COUNT(*) FROM learning_goals WHERE id = ?", [.text(notebook)]) == 0, "the notebook goes, as generation 1 would delete it")
        #expect(try rig.rowCount("SELECT COUNT(*) FROM sources WHERE id = 's1'") == 1, "a source it only held in a pool stays")
        #expect(try rig.patchCount() == 0)
    }

    // MARK: A base on the root (R7-1)

    @Test("With a base on the root a notebook the server holds keeps the title Mac A gave it on build N, and the source an old iPhone filed arrives")
    func baseOnRoot() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Notes")
        try rig.source("s1")
        try rig.source("s2")
        try rig.file("s1", into: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.source, "s2")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try await rig.seed()
        try rig.newWorldEdit(.notebook, notebook, ["title": "Mac A's title"], ms: SyncTime.milliseconds(Date().addingTimeInterval(86_400)))
        try await Self.later()
        try rig.file("s2", into: notebook)

        let report = try await rig.caughtUp()
        #expect(report.rootHadBase && report.failed.isEmpty, "\(report)")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] == nil, "the server holds it: the import pass, not this view, brings what changed")
        #expect(try rig.localTitle(notebook) == "Mac A's title")
        let entry = try #require(try rig.patch(.entry, Self.entryID(notebook, "s2")), "an Entry the server does not hold is created whole")
        #expect(entry.changes["state"]?.stringValue == "active" && entry.changes["itemID"]?.stringValue == "s2")

        #expect(try rig.manifestPending() >= 1 && rig.ledger.deltas.isEmpty, "its creates wait for the server")
        try await rig.sendPatches()
        try await rig.imported(.other)
        #expect(rig.ledger.deltas.keys.contains { $0.hasPrefix("\(Rig.deviceID).") }, "and are listed in a delta once acknowledged (R5-3)")
    }

    @Test("With no base on the root every field is applied and the stamps decide over what the server holds",
          arguments: [1, 4_000_000_000_000] as [Int64])
    func noBaseOnRoot(serverMs: Int64) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Notes")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try rig.serverReceives(.notebook, notebook, ms: serverMs)
        try await Self.later()
        try rig.rename(notebook, to: "Old world title")

        let report = try await rig.caughtUp()
        #expect(!report.rootHadBase, "\(report)")
        if serverMs == 1 {
            #expect(try rig.patch(.notebook, notebook)?.changes["title"] != nil, "an older stamp is overtaken by the old record's date")
        } else {
            #expect(try rig.patch(.notebook, notebook)?.changes["title"] == nil, "a later stamp stands")
        }
    }

    // MARK: Bodies (R7-3, R8-1)

    @Test("A Doc edited on this Mac and in the old world keeps this Mac's body and yields one Recovered Doc, whichever edit is later",
          arguments: [3600.0, -3600.0])
    func docEdits(offset: Double) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.doc("doc-a", title: "A", body: Rig.docBody)
        try rig.syncedHere(.artifact, "doc-a")
        try rig.store.saveArtifactMarkdownFromSync(Rig.docBody, artifactID: "doc-a")
        try rig.activate(.deferred)
        let mine = Rig.docBody.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, mine.")
        try rig.store.saveArtifactMarkdownAfterMerge(mine, artifactID: "doc-a")
        try await Self.later()
        try rig.doc("doc-a", title: "A", body: Rig.docBody.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, theirs."))
        let old = try rig.oldRecord(.artifact, "doc-a")
        try rig.pendingOldChange(.artifact, "doc-a", at: old.oldModifiedAt.addingTimeInterval(offset))

        try await rig.caughtUp()
        #expect(try rig.store.loadArtifactMarkdownForSync("doc-a") == mine, "this Mac's body stays")
        #expect(try rig.recoveredPatches(prefix: "recovered:doc-a:") == 1, "the old world's body is not dropped")
        #expect(try rig.patch(.artifact, "doc-a")?.changes["body"] == nil)
    }

    @Test("A Doc this Mac holds no edit of takes the old world's body, uploaded as the old package")
    func docTakesOldBody() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.doc("doc-a", title: "A", body: Rig.docBody)
        try rig.syncedHere(.artifact, "doc-a")
        try rig.store.saveArtifactMarkdownFromSync(Rig.docBody, artifactID: "doc-a")
        try rig.activate(.deferred)
        try await Self.later()
        try rig.doc("doc-a", title: "A", body: Rig.docBody.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited on the web."))

        try await rig.caughtUp()
        #expect(try rig.patch(.artifact, "doc-a")?.changes["body"] != nil && rig.recoveredPatches(prefix: "recovered:") == 0)
        #expect(rig.uploader.owners() == ["doc-a"])
    }

    @Test("Notes edited on this Mac with an unsent change and in the old world stay beside one Recovered Doc; the walk's notes become the notes base")
    func notesEdits() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Notes")
        try rig.setNotes(notebook, "First thoughts")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        try rig.store.execute("UPDATE learning_goals SET notes = 'Mine' WHERE id = ?", [.text(notebook)])
        try await Self.later()
        try rig.setNotes(notebook, "Theirs")
        try rig.pendingOldChange(.learningGoal, notebook, at: Date().addingTimeInterval(3_600))

        let report = try await rig.caughtUp()
        #expect(report.notesBases >= 1)
        #expect(try rig.store.scalarText("SELECT notes FROM learning_goals WHERE id = ?", [.text(notebook)]) == "Mine", "this Mac's notes stay")
        #expect(try rig.recoveredPatches(prefix: "recovered:notes:\(notebook):") == 1, "and the old world's are saved once")
        #expect(try rig.store.scalarText("SELECT base_text FROM ck_legacy_bodies WHERE record_type = 'Notebook' AND wire_id = ? AND field = 'notes'", [.text(notebook)]) == "Theirs",
                "the walk's notes are the notes base, whatever happened")
    }

    // MARK: The 5% guard (R5-m5, R6-m9)

    @Test("A walk that would delete more than 5% applies nothing and asks; Apply runs it once with the guard lifted")
    func guardApply() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let ids = (0..<25).map { "src-\($0)" }
        for id in ids {
            try rig.source(id)
            try rig.syncedHere(.source, id)
        }
        try rig.activate(.deferred)
        for id in ids.prefix(10) { try await rig.deleteFromOldWorld(Self.oldName(.source, id)) }

        guard case .guardTripped(let question) = try await rig.catchUp() else { Issue.record("the guard did not trip"); return }
        #expect(question.deleting == 10 && question.of == 25)
        #expect(try rig.rowCount("SELECT COUNT(*) FROM sources") == 25 && rig.catchUpAt() == nil, "nothing applied, nothing recorded")
        #expect(try await rig.catchUp() == .waitingForQuestion, "the Mac waits for the learner and sends nothing")
        let stored = try #require(try ActivationQuestion.load(rig.store))
        #expect(stored.answer == nil)

        try ActivationQuestion.answerApply(store: rig.store)
        let report = try await rig.caughtUp()
        #expect(report.deletions == 10)
        #expect(try rig.rowCount("SELECT COUNT(*) FROM sources") == 15, "the guard is lifted once")
        #expect(try ActivationQuestion.load(rig.store) == nil && rig.catchUpAt() != nil, "the question is consumed and the walk recorded")
    }

    // MARK: No history, no old world, no fetch

    @Test("With no sync history every old record counts as changed and nothing local is removed")
    func holdsMyLibrary() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mine")
        try rig.source("s1")
        try rig.file("s1", into: notebook)
        try rig.syncedHere(.source, "s1")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.store.execute("DELETE FROM sync_metadata")
        try rig.activate(.fresh)
        try await Self.later()
        try rig.unfile("s1", from: notebook)
        try rig.rename(notebook, to: "Renamed meanwhile")

        let report = try await rig.caughtUp()
        #expect(report.removals == 0 && report.applied >= 1, "\(report)")
        #expect(try rig.hasEntryRow(notebook, "s1"), "old-world drops come back: with no history nothing local is removed")
        #expect(try rig.patch(.notebook, notebook)?.changes["title"] != nil, "the old world's change still applies")
    }

    @Test("A missing Knowledge zone is no old world: nothing is applied, the Mac records fresh and reads nothing afterwards")
    func knowledgeMissing() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let notebook = try rig.notebook("Mine")
        try rig.syncedHere(.learningGoal, notebook)
        try rig.activate(.deferred)
        rig.server.deleteZone(Rig.zoneName, owner: Rig.learner, container: FakeCloudKit.legacyContainer, reason: .purged)

        guard case .noOldWorld = try await rig.catchUp() else { Issue.record("the old world was not found missing"); return }
        let journal = try #require(try rig.store.activationJournal())
        #expect(journal.mode == .fresh && journal.freshReason == .knowledgeMissing)
        #expect(try rig.rowCount("SELECT COUNT(*) FROM learning_goals WHERE id = ?", [.text(notebook)]) == 1, "nothing deleted")
        #expect(try await rig.catchUp() == .readsNothing, "a knowledgeMissing store never reads the old zones for itself again")
    }

    @Test("After a full activation that fell back to deferred while writing its snapshot, the deferred catch-up replaces the rows it left and records its walk")
    func recoversAHalfWrittenSnapshot() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let alpha = try rig.notebook("Alpha")
        let beta = try rig.notebook("Beta")
        try rig.syncedHere(.learningGoal, alpha)
        try rig.syncedHere(.learningGoal, beta)
        try rig.activate(.deferred)
        // What the full catch-up's failed run left: the first batch of its snapshot, one row with a tag the old world
        // has since moved past and one for a record it no longer returns, and no tokens and no catch_up_at.
        let alphaName = try rig.oldRecord(.learningGoal, alpha).id.recordName
        try rig.store.execute(
            "INSERT INTO ck_legacy_snapshot (old_zone, record_name, change_tag, field_hashes) VALUES (?, ?, 'stale-tag', '{\"r\":{},\"w\":false}')",
            [.text(Rig.zoneName), .text(alphaName)]
        )
        try rig.store.execute(
            "INSERT INTO ck_legacy_snapshot (old_zone, record_name, change_tag, field_hashes) VALUES (?, 'gone-record', 'gone-tag', '{\"r\":{},\"w\":false}')",
            [.text(Rig.zoneName)]
        )
        try await Self.later()
        try rig.rename(alpha, to: "Alpha renamed")

        let report = try await rig.caughtUp()
        #expect(report.failed.isEmpty && report.applied == 1, "\(report)")
        #expect(try rig.catchUpAt() != nil, "the walk is recorded, so the Mac may claim and send")
        #expect(try await rig.ownToken() != nil)
        let alphaTag = try rig.store.scalarText("SELECT change_tag FROM ck_legacy_snapshot WHERE old_zone = ? AND record_name = ?", [.text(Rig.zoneName), .text(alphaName)])
        #expect(alphaTag == (try rig.oldRecord(.learningGoal, alpha).changeTag), "the stale row now holds the walk's tag")
        #expect(try rig.rowCount("SELECT COUNT(*) FROM ck_legacy_snapshot WHERE record_name = 'gone-record'") == 0, "a row the walk did not return is gone")
    }

    @Test("No catch-up runs before this Mac's fetch of Library and Catalog is complete")
    func fetchGate() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        _ = try rig.notebook("Mine")
        try rig.activate(.deferred)
        var library = try #require(try rig.store.replica.zone(key: Rig.N.libraryZoneKey))
        library.lastCompletePassAt = nil
        try rig.store.replica.upsertZone(library)
        #expect(try await rig.catchUp() == .notReady, "a record that has not arrived must never be taken for absent")
        #expect(try rig.catchUpAt() == nil)
    }
}
