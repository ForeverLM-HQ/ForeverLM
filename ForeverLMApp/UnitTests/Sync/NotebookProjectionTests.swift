import Foundation
import Testing
@testable import ForeverLM

/// The Notebook, Goal and Entry projections (docs/cloudkit-schema-design.md §3.5.6–§3.5.8, WP8):
/// a round trip of every field the Mac holds, Entries applied before their notebook, a source delete
/// that leaves the notebook's Entry live on the server, and the back-pointer index.
@Suite("Notebook projection")
struct NotebookProjectionTests {
    typealias F = NotebookSyncFixture

    /// The always-on server derives the same id (`researchQuestionID` in schema/js/naming.js), and its
    /// test pins this literal too, so a question either host writes lands under one key.
    @Test("A research question's id is the one the hosted mirror derives from the same text")
    func researchQuestionIDMatchesTheMirror() {
        #expect(NotebookResearchQuestions.questionID(notebookID: "nb-1", text: "  Why ROS? ") == "rq_727513e2b82223402457512b")
        #expect(NotebookResearchQuestions.questionID(notebookID: "nb-1", text: "why ros?") == "rq_727513e2b82223402457512b")
    }

    @Test("A notebook's rows encode every field it holds, and the record projects back into the same rows")
    func roundTrip() throws {
        let (root, store) = try F.makeStore("nb-round")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try store.execute("UPDATE learning_goals SET summary = 'How cells make energy', repository = 'octo/mito', artifact_id = 'doc-1' WHERE id = 'nb-1'")
        try store.execute("UPDATE learning_goals SET research_questions = ? WHERE id = 'nb-1'", [.text(KnowledgeStore.encodeResearchQuestions(["Why ROS?", "What is OXPHOS?"]))])
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-1"])
        try store.execute("""
            INSERT INTO learning_goal_gaps (id, goal_id, summary, source_id, status, first_seen_at, last_seen_at)
            VALUES ('gap-1', 'nb-1', 'Complex I assembly', NULL, 'open', 5, 6)
        """)
        try F.addNotebook(store, "nb-2", title: "Other")
        try store.execute("INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES ('nb-1', 'nb-2', 7)")

        let fields = try #require(F.savedFields(try F.pending(store)["Notebook:nb-1"]))
        #expect(fields["title"] == .string("🧬 Mitochondria"))
        #expect(fields["instructions"] == .string("Read carefully"))
        #expect(fields["summary"] == .string("How cells make energy"))
        #expect(fields["topic"] == .string("mitochondria"))
        #expect(fields["discovery"]?["enabled"] == .bool(true))
        #expect(fields["repository"]?["url"] == .string("https://github.com/octo/mito"))
        #expect(fields["homeArtifactID"] == .string("doc-1"))
        #expect(fields["status"] == .string("active"))
        #expect(fields["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 1_000)))
        let questions = try #require(fields["researchQuestions"]?.objectValue)
        #expect(questions.count == 2)
        let why = try #require(questions[NotebookResearchQuestions.questionID(notebookID: "nb-1", text: "Why ROS?")])
        let what = try #require(questions[NotebookResearchQuestions.questionID(notebookID: "nb-1", text: "What is OXPHOS?")])
        #expect(why["text"] == .string("Why ROS?") && why["status"] == .string("open"))
        #expect((why["orderKey"]?.stringValue ?? "") < (what["orderKey"]?.stringValue ?? ""), "the list's order is the keys' order")
        #expect(fields["openQuestions"]?["gap-1"]?["text"] == .string("Complex I assembly"))
        #expect(fields["relatedNotebookIDs"] == .object(["nb-2": .bool(true)]))
        #expect(fields["notes"] == nil, "notes are the Notes Doc's body, never a Notebook field")

        // Another Mac holds none of it and projects the record into the same rows.
        let (otherRoot, other) = try F.makeStore("nb-round-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.apply(other, [try F.record(.notebook, "nb-1", fields)])
        let row = "SELECT title || '|' || description || '|' || summary || '|' || topic || '|' || repository || '|' || artifact_id || '|' || entity_kind || '|' || kind FROM learning_goals WHERE id = 'nb-1'"
        #expect(try F.text(other, row) == "🧬 Mitochondria|Read carefully|How cells make energy|mitochondria|octo/mito|doc-1|notebook|companion")
        #expect(try F.text(other, "SELECT end_at FROM learning_goals WHERE id = 'nb-1'") == String(F.openEnd))
        #expect(KnowledgeStore.decodeResearchQuestions(try F.text(other, "SELECT research_questions FROM learning_goals WHERE id = 'nb-1'")) == ["Why ROS?", "What is OXPHOS?"])
        #expect(try F.count(other, "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = 'nb-1' AND summary = 'Complex I assembly'") == 1)
        #expect(try F.count(other, "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE notebook_id = 'nb-1' AND related_notebook_id = 'nb-2'") == 1)
        #expect(try F.pending(other).isEmpty, "an apply sends nothing back")
        let back = try #require(try NotebookProjection.loadRows(localID: "nb-1", connection: other).map(NotebookProjection.encodeRows))
        for field in ["title", "instructions", "summary", "topic", "repository", "homeArtifactID", "status", "researchQuestions", "openQuestions", "relatedNotebookIDs", "createdAt"] {
            #expect(back[field] == fields[field], "\(field) round-trips")
        }
    }

    @Test("A local edit of one field sends that field alone, and an untouched notebook sends nothing")
    func editSendsOneField() throws {
        let (root, store) = try F.makeStore("nb-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.sendAll(store)
        #expect(try F.pending(store).isEmpty)
        try store.execute("UPDATE learning_goals SET updated_at = 99999 WHERE id = 'nb-1'")
        #expect(try F.pending(store).isEmpty, "touching the notebook (opening, filing) sends nothing")
        try store.execute("UPDATE learning_goals SET title = 'Renamed' WHERE id = 'nb-1'")
        let change = try #require(try F.pending(store)["Notebook:nb-1"])
        #expect(Set(change.stamps.keys.map(\.field)) == ["title"])
    }

    @Test("Entries applied before their notebook wait, then project when it arrives")
    func entriesBeforeNotebook() throws {
        let (root, store) = try F.makeStore("nb-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-a")
        try F.apply(store, [try F.entryRecord("nb-9", "src-a", orderKey: "a1")])
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Notebook' AND waiting_on_id = 'nb-9'") == 1)
        try F.apply(store, [try F.record(.notebook, "nb-9", ["title": .string("Late"), "status": .string("active"), "createdAt": SyncJSON(Int64(1_758_000_000_000))])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-9' AND source_id = 'src-a' AND order_key = 'a1'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try F.pending(store).values.allSatisfy { $0.recordType == .source }, "only the local source is new here")
    }

    @Test("A source deleted here leaves its notebook Entry live on the server, and a re-import shows it again")
    func sourceDeleteKeepsEntry() throws {
        let (root, store) = try F.makeStore("nb-source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try F.sendAll(store)
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        #expect(try F.held(store, .entry, entryID)?.fields["state"] == .string("active"))

        try store.deleteSourceRows("src-a")
        let pending = try F.pending(store)
        #expect(pending["Entry:\(entryID)"] == nil, "the Entry is not written")
        try F.sendAll(store)
        #expect(try F.held(store, .entry, entryID)?.fields["state"] == .string("active"))
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE source_id = 'src-a'") == 1, "the item stays, hidden while its source is missing")
        try F.addSource(store, "src-a")
        #expect(try F.count(store, """
            SELECT COUNT(*) FROM learning_goal_items i JOIN sources s ON s.id = i.source_id WHERE i.goal_id = 'nb-1'
        """) == 1)
    }

    @Test("A source removed from a notebook is state removed; added again it is active, one record either way")
    func removeAndReAdd() throws {
        let (root, store) = try F.makeStore("nb-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try F.sendAll(store)
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        try store.execute("DELETE FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'")
        #expect(F.savedFields(try F.pending(store)["Entry:\(entryID)"])?["state"] == .string("removed"))
        try F.sendAll(store)
        #expect(try F.held(store, .entry, entryID)?.fields["state"] == .string("removed"))
        // An inbound removal deletes the row; an inbound re-add writes it again.
        try F.apply(store, [try F.entryRecord("nb-1", "src-a", state: "active", ms: 1_800_000_000_000)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'") == 1)
        try F.apply(store, [try F.entryRecord("nb-1", "src-a", state: "removed", ms: 1_800_000_000_001)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'") == 0)
        #expect(try F.pending(store).isEmpty)
    }

    @Test("A notebook deleted here deletes its record and its Entries; one deleted elsewhere deletes the rows")
    func notebookDelete() throws {
        let (root, store) = try F.makeStore("nb-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try F.sendAll(store)
        try store.execute("DELETE FROM learning_goals WHERE id = 'nb-1'")
        let pending = try F.pending(store)
        #expect(pending["Notebook:nb-1"]?.action == .delete)
        #expect(pending["Entry:\(SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a"))"]?.action == .delete)

        let (otherRoot, other) = try F.makeStore("nb-delete-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.apply(other, [try F.record(.notebook, "nb-2", ["title": .string("Gone soon"), "status": .string("active")])])
        try other.replica.apply { _ in
            try ProjectionApply(store: other, registry: F.registry).projectDeletion(
                zoneKey: F.libraryZoneKey, recordName: RecordNaming.recordName(type: .notebook, id: "nb-2", salt: F.salt), type: .notebook, wireID: "nb-2"
            )
        }
        #expect(try F.count(other, "SELECT COUNT(*) FROM learning_goals WHERE id = 'nb-2'") == 0)
    }

    @Test("The back-pointer index lists every child filed into a notebook")
    func backPointerIndex() throws {
        let (root, store) = try F.makeStore("nb-children")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addNotebook(store, "nb-1")
        try F.addGoal(store, "goal-1", parent: "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try store.execute("INSERT INTO notebook_course_links (goal_id, course_id) VALUES ('nb-1', 'course-1')")
        try store.execute("INSERT INTO notebook_states (notebook_id, pinned) VALUES ('nb-1', 1)")
        var kinds: [String] = []
        try store.query("SELECT child_type FROM ck_notebook_children WHERE notebook_id = 'nb-1' ORDER BY child_type", []) { row in
            kinds.append(row.text(0) ?? "")
        }
        #expect(kinds == ["Entry", "Entry", "Goal", "NotebookState"])
    }

    @Test("A notebook's notes encode as its Notes Doc: gzip Markdown owned by notes:<id>, hashed over the trimmed text")
    func notesDoc() throws {
        let notes = "\n  ## What we know\nComplex I leaks electrons.  \n"
        let fields = try NotesDoc.fields(notebookID: "nb-1", notes: notes, createdAt: 1_758_000_000_000)
        #expect(NotesDoc.id(notebookID: "nb-1") == "notes:nb-1" && NotesDoc.notebookID(of: "notes:nb-1") == "nb-1")
        #expect(fields["kind"] == .string("notes") && fields["title"] == .string("Notes") && fields["bodyFormat"] == .string("markdown"))
        #expect(fields["notebookID"] == .string("nb-1"))
        #expect(fields["preview"] == .string("## What we know Complex I leaks electrons."))
        let body = try #require(fields["body"]?.objectValue)
        #expect(body["owner"] == .string("notes:nb-1") && body["role"] == .string("body") && body["enc"] == .string("gzip"))
        #expect(body["hash"] == .string(SyncIdentity.sha256Hex(Data("## What we know\nComplex I leaks electrons.".utf8))))
        #expect(try NotesDoc.fields(notebookID: "nb-1", notes: "  ", createdAt: 1)["body"] == .null, "empty notes have no body")
        #expect(SyncRecordType.artifact.spec.field("body")?.policy == .textBody)
    }

    @Test("notebook_resolution follows merges and moves to the last live notebook")
    func resolution() throws {
        let (root, store) = try F.makeStore("nb-resolve")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [
            try F.record(.notebook, "nb-c", ["title": .string("C"), "status": .string("active")]),
            try F.record(.notebook, "nb-b", ["title": .string("B"), "status": .string("merged"), "mergedInto": .string("nb-c"), "foldKind": .string("merge")]),
            try F.record(.notebook, "nb-a", ["title": .string("A"), "status": .string("merged"), "mergedInto": .string("nb-b"), "foldKind": .string("split")]),
        ])
        #expect(try NotebookResolutionTable.resolve("nb-a", connection: store) == SyncRecordLocation(zone: .library, id: "nb-c"))
        #expect(try NotebookResolutionTable.resolve("nb-c", connection: store) == SyncRecordLocation(zone: .library, id: "nb-c"))
        #expect(try F.text(store, "SELECT status || '|' || merged_into || '|' || fold_kind FROM learning_goals WHERE id = 'nb-a'") == "archived|nb-b|split")
        // A merged stub encodes as merged, so it re-sends nothing.
        #expect(try F.pending(store).isEmpty)
    }
}
