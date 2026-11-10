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
