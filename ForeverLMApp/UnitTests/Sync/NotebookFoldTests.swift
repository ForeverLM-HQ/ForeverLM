import Foundation
import Testing
@testable import ForeverLM

/// The fold (docs/cloudkit-schema-design.md §5.2, D48), today's `foldNotebookWordsInTransaction` on the
/// Notebook record and the Notes Doc under generation 2, and the hand-over of a member's NotebookState
/// sets from a stub: a merge unions the context-notebook ticks and collections into the survivor's once
/// and never its exclusions (R6-m2), and a Mac that sees a stub long after another member's device made
/// it, that member's other devices being an iPhone and the web, still hands their sets over (R7-m6).
/// The three-way merge of a target body edited meanwhile is the T path's, so WP11 pins it.
@Suite("Notebook fold")
struct NotebookFoldTests {
    typealias F = NotebookSyncFixture
    typealias M = NotebookMergeFixture

    private static func words(_ id: String, title: String, notes: String? = nil, instructions: String? = nil, summary: String? = nil,
                              topic: String? = nil, repository: String? = nil, questions: [String]? = nil) -> NotebookWords {
        NotebookWords(id: id, title: title, notes: notes, instructions: instructions, summary: summary, topic: topic,
                      repository: repository, researchQuestions: questions)
    }

    @Test("The target's words win, blanks are filled, questions are unioned and notes are concatenated under each title")
    func foldRule() {
        let target = Self.words("b", title: "Mito Phenotyping", notes: "Parent notes", instructions: "Keep it short", summary: "  ",
                                questions: ["Does Complex I set the pace?"])
        let folded = Self.words("a", title: "OXPHOS", notes: "Child notes", instructions: "Answer from papers", summary: "Respiratory chain",
                                topic: "oxphos", repository: "example/mito", questions: ["does complex i set the pace? ", "What limits flux?", ""])
        let result = NotebookFold.folded(target, from: [folded], title: "Mitochondria (merged)")
        #expect(result.title == "Mitochondria (merged)")
        #expect(result.notes == "## Mito Phenotyping\n\nParent notes\n\n## OXPHOS\n\nChild notes")
        #expect(result.instructions == "Keep it short", "the target's words win")
        #expect(result.summary == "Respiratory chain", "a blank is filled")
        #expect(result.topic == "oxphos")
        #expect(result.repository == "example/mito")
        #expect(result.researchQuestions == ["Does Complex I set the pace?", "What limits flux?"])

        let kept = NotebookFold.folded(target, from: [folded], mergeNotes: false)
        #expect(kept.notes == "Parent notes", "without merging notes the target keeps its own")
        #expect(kept.title == "Mito Phenotyping")
        let forwarded = NotebookFold.folded(target, from: [folded], fields: [.summary])
        #expect(forwarded.summary == "Respiratory chain" && forwarded.topic == nil && forwarded.notes == "Parent notes",
                "a forwarded edit carries its own field only")
        #expect(NotebookFold.folded(Self.words("x", title: "Empty"), from: [Self.words("y", title: "Also empty")]).notes == nil)
    }

    @Test("A merge folds into the survivor's Notebook record and its Notes Doc")
    func mergeFoldsIntoRecordAndNotesDoc() throws {
        let (root, store) = try F.makeStore("fold-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "OXPHOS")
        try F.addNotebook(store, "nb-b", title: "Mitochondria")
        try M.setWords(store, "nb-b", notes: "Parent notes", topic: "mitochondria", questions: ["Does Complex I set the pace?"])
        try M.setWords(store, "nb-a", notes: "Child notes", instructions: "Answer from primary papers only.", summary: "Respiratory chain",
                       topic: "oxphos", repository: "example/mito-notes", questions: ["What limits flux?", "does complex i set the pace?"])
        try store.execute("""
            INSERT INTO learning_goal_gaps (id, goal_id, summary, status, first_seen_at, last_seen_at)
            VALUES ('gap-a', 'nb-a', 'What is complex I?', 'open', 1000, 1000), ('gap-dup', 'nb-a', 'Why tissues differ', 'open', 1000, 1000),
                   ('gap-b', 'nb-b', 'why tissues differ ', 'open', 1000, 1000)
        """)
        try F.sendAll(store)

        let result = try M.merge(store, ["nb-a"], into: "nb-b", title: "Mitochondria (merged)")

        #expect(result.gapsAdded == 1)
        let words = try #require(try NotebookWords.load("nb-b", connection: store))
        #expect(words.notes == "## Mitochondria\n\nParent notes\n\n## OXPHOS\n\nChild notes")
        let record = try #require(F.savedFields(try F.pending(store)["Notebook:nb-b"]))
        #expect(record["title"] == .string("Mitochondria (merged)"))
        #expect(record["instructions"] == .string("Answer from primary papers only."))
        #expect(record["summary"] == .string("Respiratory chain"))
        #expect(record["topic"] == .string("mitochondria"), "the survivor's own topic stands")
        #expect(record["repository"]?["url"] == .string("https://github.com/example/mito-notes"))
        let questions = try #require(record["researchQuestions"]?.objectValue)
        #expect(Set(questions.values.compactMap { $0["text"]?.stringValue }) == ["Does Complex I set the pace?", "What limits flux?"])
        #expect(questions[NotebookResearchQuestions.questionID(notebookID: "nb-b", text: "What limits flux?")] != nil)
        let gaps = try #require(record["openQuestions"]?.objectValue)
        #expect(Set(gaps.keys) == ["gap-a", "gap-b"], "an open question the survivor asks already stays behind")
        // The Notes Doc the survivor's notes become: one body holding both notebooks' notes.
        let notesDoc = try NotesDoc.fields(notebookID: "nb-b", notes: words.notes, createdAt: 0)
        #expect(notesDoc["body"] != .null)
        #expect(notesDoc["preview"]?.stringValue?.contains("Child notes") == true)
    }

    @Test("An emptying split folds the parent into the heir, the heir keeping its own title")
    func splitFoldsIntoTheHeir() throws {
        let (root, store) = try F.makeStore("fold-split")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-p", title: "Mitochondria")
        for source in ["src-a", "src-b"] { try F.addSource(store, source); try F.file(store, source, into: "nb-p") }
        try M.setWords(store, "nb-p", notes: "Supercomplexes look tissue-specific.", instructions: "Answer from primary papers only.")
        try F.sendAll(store)

        let result = try M.split(store, "nb-p", [("OXPHOS", ["src-a", "src-b"])])

        let heir = try #require(result.heirGoalID)
        let words = try #require(try NotebookWords.load(heir, connection: store))
        #expect(words.title == "OXPHOS")
        #expect(words.notes == "## Mitochondria\n\nSupercomplexes look tissue-specific.")
        #expect(words.instructions == "Answer from primary papers only.")
        #expect(words.topic == "OXPHOS", "the heir's own topic stands")
    }

    @Test("A merged notebook's context-notebook ticks and collections are unioned into the survivor's once, and its exclusions are not")
    func mergeUnionsTicksAndCollectionsOnce() throws {
        let (root, store) = try F.makeStore("fold-union")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        for id in ["nb-a", "nb-b", "nb-x", "nb-y"] { try F.addNotebook(store, id, title: id) }
        try F.addSource(store, "src-1")
        try F.file(store, "src-1", into: "nb-a")
        try M.link(store, "nb-a", to: "nb-x")
        try M.link(store, "nb-b", to: "nb-y")
        try F.sendAll(store)
        try store.setNotebookChatExclusions(notebookID: "nb-a", excluded: ["src-1"])
        try store.setNotebookContextNotebooks(notebookID: "nb-a", contextNotebookIDs: ["nb-x", "nb-b"])
        try store.setNotebookCollections(notebookID: "nb-a", collectionIDs: ["nbc-1"])
        try store.setNotebookContextNotebooks(notebookID: "nb-b", contextNotebookIDs: ["nb-y"])
        try store.setNotebookCollections(notebookID: "nb-b", collectionIDs: ["nbc-2"])
        try F.sendAll(store)

        _ = try M.merge(store, ["nb-a"], into: "nb-b")

        let survivor = try #require(try NotebookStateRow.load("nb-b", connection: store))
        #expect(survivor.contextNotebooks == ["nb-x", "nb-y"], "B's own tick of A is no tick of itself")
        #expect(survivor.collections == ["nbc-1", "nbc-2"])
        #expect(survivor.excluded.isEmpty, "A's sources arrive ticked")
        #expect(try store.notebookStateSnapshot().excluded["nb-b"] == nil)
        // Once: what the member does on A's NotebookState afterwards stays there.
        try store.setNotebookCollections(notebookID: "nb-a", collectionIDs: ["nbc-1", "nbc-3"])
        try store.keepNotebookStubs()
        #expect(try NotebookStateRow.load("nb-b", connection: store)?.collections == ["nbc-1", "nbc-2"])
    }

    @Test("A Mac that first sees a stub long after another device made it still hands the member's sets over, exclusions only for a split")
    func lateMacHandsOver() throws {
        let (root, store) = try F.makeStore("fold-late-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addSource(store, "src-1")
        let notebook: (String, String) -> [String: SyncJSON] = { _, title in
            ["title": .string(title), "status": .string("active"), "createdAt": SyncJSON(Int64(1_759_000_000_000))]
        }
        // Another member's Mac merged A into B; this member's iPhone had ticked and filed A long before.
        try F.apply(store, [
            try F.record(.notebook, "nb-b", notebook("nb-b", "Mitochondria")),
            try M.stubRecord("nb-a", into: "nb-b", title: "OXPHOS", extra: ["instructions": .string("Answer from primary papers only.")]),
        ])
        try store.keepNotebookStubs()
        #expect(try NotebookStateRow.load("nb-b", connection: store) == nil, "nothing to hand over yet")
        #expect(try F.text(store, "SELECT description FROM learning_goals WHERE id = 'nb-b'") == nil,
                "what the stub held when this Mac first saw it was the merging Mac's to fold")
        try F.apply(store, [try F.record(.notebookState, "ns:nb-a", [
            "notebookID": .string("nb-a"), "contextNotebooks": .object(["nb-x": .bool(true)]),
            "collections": .object(["nbc-1": .bool(true)]), "excluded": .object(["src-1": .string("L1759400000000.0001.phoneaaa|-")]),
        ], device: "phoneaaa")])
        try store.keepNotebookStubs()
        let survivor = try #require(try NotebookStateRow.load("nb-b", connection: store))
        #expect(survivor.contextNotebooks == ["nb-x"] && survivor.collections == ["nbc-1"])
        #expect(survivor.excluded.isEmpty, "a merge hands over no exclusions")
        #expect(F.savedFields(try F.pending(store)["NotebookState:ns:nb-b"])?["collections"]?["nbc-1"] == .bool(true))

        // The same for a split: the heir holds the source, so the untick goes with it unchanged.
        let pair = "L1759400000000.0002.phoneaaa|L1759400000000.0003.phoneaaa"
        try F.apply(store, [
            try F.record(.notebook, "nb-h", notebook("nb-h", "Biogenesis")),
            try F.entryRecord("nb-h", "src-1"),
            try M.stubRecord("nb-p", into: "nb-h", kind: "split", title: "Mitochondria (old)"),
            try F.record(.notebookState, "ns:nb-p", [
                "notebookID": .string("nb-p"), "excluded": .object(["src-1": .string(pair), "src-gone": .string(pair)]),
            ], device: "webaaaaa"),
        ])
        try store.keepNotebookStubs()
        #expect(try NotebookStateRow.load("nb-h", connection: store)?.excluded == ["src-1": pair], "only sources in the heir's pool")
    }
}
