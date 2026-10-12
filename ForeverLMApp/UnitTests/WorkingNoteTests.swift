import Foundation
import Testing
@testable import ForeverLM

@Suite("Working notes")
struct WorkingNoteTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func note(
        _ text: String,
        kind: WorkingNoteKind = .thread,
        id: String = UUID().uuidString,
        age days: Double = 0,
        vector: [Float]? = nil
    ) -> WorkingNote {
        var note = WorkingNote(id: id, kind: kind, text: text, now: now.addingTimeInterval(-days * 86_400))
        note.vector = vector
        note.embeddingModel = vector == nil ? nil : EmbeddingSettings.modelID
        return note
    }

    // MARK: Ranking

    @Test("The note nearest the query comes first, whatever its age")
    func nearestFirst() {
        let berlin = note("Berlin conference on October 21", id: "a", age: 30, vector: [1, 0])
        let sleep = note("Reading the sleep-pressure paper", id: "b", age: 0, vector: [0, 1])
        let ranked = WorkingNoteRanking.rank(
            [sleep, berlin], queryVector: [1, 0], embeddingModel: EmbeddingSettings.modelID, topK: 2
        )
        #expect(ranked.map(\.id) == ["a", "b"])
    }

    @Test("With no query vector the newest note leads, and topK bounds the answer")
    func recencyWithoutQuery() {
        let notes = (0..<5).map { note("note \($0)", id: "n\($0)", age: Double($0)) }
        let ranked = WorkingNoteRanking.rank(notes, queryVector: nil, embeddingModel: EmbeddingSettings.modelID, topK: 3)
        #expect(ranked.map(\.id) == ["n0", "n1", "n2"])
        #expect(WorkingNoteRanking.rank([], queryVector: [1], embeddingModel: "m", topK: 3).isEmpty)
        #expect(WorkingNoteRanking.rank(notes, queryVector: nil, embeddingModel: "m", topK: 0).isEmpty)
    }

    @Test("A vector from another embedding model is not compared")
    func staleVectorIgnored() {
        var stale = note("old model", id: "s", age: 5, vector: [1, 0])
        stale.embeddingModel = "retired-model"
        let fresh = note("new", id: "f", age: 0)
        let ranked = WorkingNoteRanking.rank(
            [stale, fresh], queryVector: [1, 0], embeddingModel: EmbeddingSettings.modelID, topK: 2
        )
        #expect(ranked.first?.id == "f", "only recency ranks the stale vector's note")
    }

    // MARK: Operations

    @Test("A model's operations are applied only where they name something real")
    func opsAreValidated() throws {
        let kept = note("Reading NAD+ papers", id: "keep")
        let json = """
        {"add":[{"kind":"fact","text":"Berlin is on Oct 21","source_ids":["s1"]},
                {"kind":"mood","text":"seems tired"},
                {"kind":"thread","text":"   "}],
         "update":[{"id":"keep","text":"Reading NAD+ papers, two left"},{"id":"ghost","text":"x"}],
         "forget":["keep","ghost"],"right_now":"- NAD+","log":["Read one paper"]}
        """
        let extraction = try JSONDecoder().decode(WorkingNoteExtraction.self, from: Data(json.utf8))
        let ops = extraction.ops.validated(against: [kept])
        #expect(ops.add.map(\.text) == ["Berlin is on Oct 21"], "an unknown kind and a blank sentence are dropped")
        #expect(ops.update.map(\.id) == ["keep"], "an invented id is dropped")
        #expect(ops.forget == ["keep"])
        #expect(extraction.rightNow == "- NAD+")
        #expect(extraction.log == ["Read one paper"])
    }

    @Test("A response without add, update or forget is an empty set of operations")
    func missingKeysAreEmpty() throws {
        let extraction = try JSONDecoder().decode(WorkingNoteExtraction.self, from: Data("{}".utf8))
        #expect(extraction.ops.isEmpty)
        #expect(extraction.log.isEmpty)
        #expect(extraction.rightNow == nil)
    }

    // MARK: Consolidation

    @Test("The same sentence twice is one note, an ended thread goes, a fact stays")
    func consolidation() {
        let first = note("Reading the NAD+ papers.", kind: .thread, id: "1", age: 2)
        var again = note("reading the nad+ papers", kind: .interest, id: "2", age: 1)
        again.recallCount = 3
        let ended = note("Old reading thread", kind: .thread, id: "3", age: 90)
        let fact = note("Berlin conference on Oct 21", kind: .fact, id: "4", age: 90)

        let result = WorkingNoteConsolidation.consolidate([first, again, ended, fact], now: now)
        #expect(Set(result.map(\.id)) == ["1", "4"])
        let merged = result.first { $0.id == "1" }
        #expect(merged?.kind == .interest)
        #expect(merged?.recallCount == 3)
    }

    @Test("The store is bounded to the most recently touched notes")
    func bounded() {
        let notes = (0..<(WorkingNoteConsolidation.maximumNotes + 20)).map {
            note("fact number \($0)", kind: .fact, id: "n\($0)", age: Double($0) / 10)
        }
        let result = WorkingNoteConsolidation.consolidate(notes, now: now)
        #expect(result.count == WorkingNoteConsolidation.maximumNotes)
        #expect(result.contains { $0.id == "n0" })
        #expect(!result.contains { $0.id == "n\(WorkingNoteConsolidation.maximumNotes + 19)" })
    }

    // MARK: The store

    private func storeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("working-notes-\(UUID().uuidString)", isDirectory: true)
    }

    /// A stand-in embedder: a note about Berlin points one way, anything else another.
    private static let embed: @Sendable (String) async throws -> [Float] = { text in
        text.lowercased().contains("berlin") ? [1, 0] : [0, 1]
    }

    @Test("Notes are written, recalled by embedding, and survive a reload")
    func storeRoundTrip() async throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkingNoteStore(directory: directory, embed: Self.embed)

        let added = await store.apply(WorkingNoteOps(
            add: [
                .init(kind: "fact", text: "Berlin conference on Oct 21"),
                .init(kind: "thread", text: "Reading the sleep-pressure paper"),
            ],
            update: [], forget: []
        ), now: now)
        #expect(added.count == 2)

        let recalled = await store.recall(query: "what do I need for Berlin?", topK: 1, now: now)
        #expect(recalled.map(\.text) == ["Berlin conference on Oct 21"])
        #expect(recalled.first?.recallCount == 1)

        let reloaded = WorkingNoteStore(directory: directory, embed: Self.embed)
        let all = await reloaded.allNotes()
        #expect(all.count == 2)
        #expect(all.first { $0.text.contains("Berlin") }?.recallCount == 1)
        #expect(all.allSatisfy { $0.vector != nil && $0.embeddingModel == EmbeddingSettings.modelID })
    }

    @Test("A failing embedder never fails recall, and its notes are embedded later")
    func embedderFailureIsSoft() async throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct Down: Error {}
        let store = WorkingNoteStore(directory: directory, embed: { _ in throw Down() })
        await store.apply(WorkingNoteOps(add: [.init(kind: "fact", text: "Berlin on Oct 21")], update: [], forget: []), now: now)
        let recalled = await store.recall(query: "Berlin", topK: 3, now: now)
        #expect(recalled.count == 1)
        #expect(await store.allNotes().first?.vector == nil)
    }

    @Test("Update rewrites a note in place and forget removes it")
    func updateAndForget() async throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkingNoteStore(directory: directory, embed: Self.embed)
        let added = await store.apply(WorkingNoteOps(add: [
            .init(kind: "thread", text: "Reading NAD+ papers"),
            .init(kind: "fact", text: "Berlin on Oct 21"),
        ], update: [], forget: []), now: now)
        let thread = try #require(added.first { $0.kind == .thread })
        let fact = try #require(added.first { $0.kind == .fact })

        await store.apply(WorkingNoteOps(
            add: [], update: [.init(id: thread.id, text: "Finished the NAD+ papers")], forget: [fact.id]
        ), now: now.addingTimeInterval(60))
        let all = await store.allNotes()
        #expect(all.map(\.text) == ["Finished the NAD+ papers"])
        #expect(all.first?.id == thread.id)
        #expect(all.first?.updatedAt == now.addingTimeInterval(60))
    }

    @Test("An unreadable file is moved aside, not overwritten")
    func unreadableFileKept() async throws {
        let directory = storeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent(WorkingNoteStore.fileName))
        let store = WorkingNoteStore(directory: directory, embed: Self.embed)
        #expect(await store.allNotes().isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("working-notes.unreadable.json").path))
    }

    // MARK: The log Doc and the prompt

    @Test("A run replaces Right now and stamps new entries above the old ones")
    func logUpdate() {
        let before = "## Right now\n\nNothing recorded yet.\n\n## Log\n\n- 2026-10-09 18:00 Older entry\n"
        let after = WorkingLog.updated(
            markdown: before, rightNow: "- NAD+ papers, touched today", entries: ["First", "Second"], now: now
        )
        let lines = after.components(separatedBy: "\n")
        #expect(after.contains("- NAD+ papers, touched today"))
        #expect(!after.contains("Nothing recorded yet."))
        let first = lines.firstIndex { $0.hasSuffix(" Second") }
        let second = lines.firstIndex { $0.hasSuffix(" First") }
        let older = lines.firstIndex { $0.hasSuffix("Older entry") }
        #expect(first != nil && second != nil && older != nil)
        #expect(first! < second! && second! < older!, "newest first")
        #expect(WorkingLog.rightNowSection(of: after) == "- NAD+ papers, touched today")
    }

    @Test("A Doc the learner rewrote keeps every word they wrote")
    func logUpdateKeepsLearnersText() {
        let after = WorkingLog.updated(markdown: "my own notes\nsecond line", rightNow: nil, entries: ["Did a thing"], now: now)
        #expect(after.contains("my own notes"))
        #expect(after.contains("second line"))
        #expect(after.contains("## Right now"))
        #expect(after.contains("Nothing recorded yet."))
    }

    @Test("Recalled notes ride in the prompt as dated lines, and nothing when there are none")
    func promptBlock() {
        #expect(ReviewSessionManager.workingNotesBlock([]).isEmpty)
        let block = ReviewSessionManager.workingNotesBlock([note("Berlin conference on Oct 21", kind: .fact, id: "abcdefgh-1")])
        #expect(block.contains("<working_notes>"))
        #expect(block.contains("[fact,"))
        #expect(block.contains("id abcdefgh]"))
        #expect(block.contains("Berlin conference on Oct 21"))
    }

    // MARK: The mirror Doc

    @Test("Notes render as kind-prefixed bullets and parse back, with prose ignored")
    func mirrorRoundTrip() {
        let notes = [
            note("Berlin conference on Oct 21", kind: .fact, id: "1"),
            note("Reading the NAD+ papers", kind: .thread, id: "2"),
        ]
        let markdown = WorkingNoteMirror.render(notes)
        #expect(markdown == "- thread: Reading the NAD+ papers\n- fact: Berlin conference on Oct 21\n")
        #expect(WorkingNoteMirror.parse(markdown).map(\.text) == ["Reading the NAD+ papers", "Berlin conference on Oct 21"])
        #expect(WorkingNoteMirror.parse("# Title\nSome prose.\n- Plain line\n* interest: Mitophagy\n-\n").map(\.kind) == [.fact, .interest])
    }

    @Test("A line the learner edits becomes the note; a line they delete is forgotten; a line they add is learned")
    func mirrorMerge() {
        let kept = note("Reading the NAD+ papers", kind: .thread, id: "kept")
        let gone = note("Berlin conference on Oct 21", kind: .fact, id: "gone")
        let local = [kept, gone]
        let exported: Set<String> = [kept.normalizedText, gone.normalizedText]

        // The learner deleted the Berlin line and added one of their own.
        let doc = WorkingNoteMirror.parse("- thread: Reading the NAD+ papers\n- I like a review after every paper\n")
        let merged = WorkingNoteMirror.merge(local: local, doc: doc, exported: exported, now: now)
        #expect(merged.map(\.text) == ["Reading the NAD+ papers", "I like a review after every paper"])
        #expect(merged.first?.id == "kept", "the note a line still names keeps its history")
        #expect(merged.last?.kind == .fact, "a line with no kind is a fact")
    }

    @Test("A note this Mac wrote and never exported survives a Doc that lacks it")
    func mirrorKeepsNewLocalNotes() {
        let fresh = note("Wrote this on the other Mac's blind side", id: "new")
        let merged = WorkingNoteMirror.merge(local: [fresh], doc: [], exported: [], now: now)
        #expect(merged.map(\.id) == ["new"])
    }

    @Test("Syncing writes the notes out, then reads a deletion in the Doc back as forgetting")
    func storeMirrorSync() async throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkingNoteStore(directory: directory, embed: Self.embed)
        await store.apply(WorkingNoteOps(add: [
            .init(kind: "fact", text: "Berlin on Oct 21"),
            .init(kind: "thread", text: "Reading the sleep paper"),
        ], update: [], forget: []), now: now)

        // The Doc is empty: both notes are written out.
        let first = await store.syncWithMirror(markdown: "", revision: "r0", now: now)
        #expect(first.needsWrite)
        #expect(first.markdown.contains("- fact: Berlin on Oct 21"))
        await store.recordMirror(revision: "r1")

        // The Doc at r1 is what was written: nothing more to do.
        let steady = await store.syncWithMirror(markdown: first.markdown, revision: "r1", now: now)
        #expect(!steady.needsWrite)

        // The learner deleted the Berlin line in the editor: r2.
        let after = await store.syncWithMirror(markdown: "- thread: Reading the sleep paper\n", revision: "r2", now: now)
        #expect(!after.needsWrite)
        #expect(await store.allNotes().map(\.text) == ["Reading the sleep paper"])
    }

    @Test("A note's edit and forget are the learner's, and the file keeps the mirror state across a reload")
    func editForgetAndReload() async throws {
        let directory = storeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkingNoteStore(directory: directory, embed: Self.embed)
        let added = await store.apply(WorkingNoteOps(add: [.init(kind: "fact", text: "Berlin on Oct 21")], update: [], forget: []), now: now)
        let id = try #require(added.first?.id)
        await store.edit(id: id, text: "Berlin on Oct 22", kind: .outcome, now: now.addingTimeInterval(5))
        let edited = try #require(await store.allNotes().first)
        #expect(edited.text == "Berlin on Oct 22")
        #expect(edited.kind == .outcome)
        #expect(edited.updatedAt == now.addingTimeInterval(5))
        await store.recordMirror(revision: "r9")

        let reloaded = WorkingNoteStore(directory: directory, embed: Self.embed)
        let sync = await reloaded.syncWithMirror(markdown: WorkingNoteMirror.render(await reloaded.allNotes()), revision: "r9", now: now)
        #expect(!sync.needsWrite, "the reloaded file remembers the revision it last saw")

        #expect(await reloaded.forget(id: id))
        #expect(await reloaded.allNotes().isEmpty)
    }

    // MARK: MCP

    @Test("A note is found by its id or by an unambiguous start of it, and by nothing else")
    func resolvesNotes() throws {
        let a = note("one", id: "abcdefgh-1111")
        let b = note("two", id: "abcdefgh-2222")
        let c = note("three", id: "zyxwvuts-3333")
        let notes = [a, b, c]
        #expect(try MCPDataStore.resolveWorkingNote("zyxwvuts", in: notes).text == "three")
        #expect(try MCPDataStore.resolveWorkingNote("abcdefgh-1111", in: notes).text == "one")
        #expect(throws: (any Error).self) { try MCPDataStore.resolveWorkingNote("abcdefgh", in: notes) }
        #expect(throws: (any Error).self) { try MCPDataStore.resolveWorkingNote("zyx", in: notes) }
        #expect(throws: (any Error).self) { try MCPDataStore.resolveWorkingNote("", in: notes) }
    }

    @Test("Notes are on until the learner switches them off")
    func switchDefaultsOn() {
        let defaults = UserDefaults(suiteName: "working-notes-\(UUID().uuidString)")!
        #expect(WorkingNotesPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: WorkingNotesPreference.enabledKey)
        #expect(!WorkingNotesPreference.isEnabled(defaults: defaults))
    }

    // MARK: Kept in the background

    @Test("The working memory is kept in the background: no list shows it, its writers find it by id, the Doc tools refuse it")
    func workingMemoryIsNoDoc() async throws {
        let directory = storeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPDataStore(dbPath: directory.appendingPathComponent("knowledge.db").path)
        let storage = store.notebookFileStorage
        let page = try await storage.createArtifact(
            title: "Berlin talk", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "# Berlin talk"
        ).artifact
        let log = try await storage.ensureWorkingLog()
        let notes = try await storage.ensureWorkingNotesDoc()
        #expect(Set([log.id, notes.id]) == WorkingMemoryRecords.ids)

        // No listing shows them; a lookup by id, as sync and their writers make, does.
        #expect(try await storage.loadArtifacts().map(\.id) == [page.id])
        #expect(try await storage.myLibraryArtifacts().map(\.id) == [page.id])
        let knowledge = try store.knowledgeStore()
        #expect(try knowledge.loadArtifact(WorkingLog.id)?.id == WorkingLog.id)
        #expect(try knowledge.loadArtifacts(listing: .everyRecord).count == 3)

        // An untouched log rides in no prompt; a written one does, and
        // Forget All puts it back to the seed.
        #expect(try await storage.workingLogPromptExcerpt() == nil)
        let snapshot = try await storage.artifactMarkdown(WorkingLog.id)
        _ = try await storage.writeArtifactMarkdownAndSync(
            artifactID: WorkingLog.id,
            markdown: WorkingLog.updated(
                markdown: snapshot.markdown, rightNow: "- Berlin talk, touched today",
                entries: ["Wrote the Berlin talk outline"], now: now
            ),
            expectedRevision: snapshot.revision,
            versionReason: .assistantEdit
        )
        #expect(try await storage.workingLogPromptExcerpt()?.contains("Berlin talk outline") == true)
        try await storage.resetWorkingLog()
        #expect(try await storage.workingLogPromptExcerpt() == nil)

        let registry = MCPToolRegistry(store: store)
        for id in WorkingMemoryRecords.ids.sorted() {
            let answer = await registry.callTool(name: "read_doc", arguments: ["doc_id": id], access: .internalFullAccess)
            #expect(answer.contains("background memory"), "read_doc \(id): \(answer)")
        }
        let listed = await registry.callTool(name: "list_docs", arguments: [:], access: .internalFullAccess)
        for id in WorkingMemoryRecords.ids { #expect(!listed.contains(id), "list_docs shows \(id)") }
    }

    @Test("The four tools are registered, and only the read is read-only")
    func toolsAreRegistered() {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        for tool in ["list_working_notes", "save_working_note", "update_working_note", "forget_working_note"] {
            #expect(names.contains(tool), "\(tool) is not registered")
        }
    }
}
