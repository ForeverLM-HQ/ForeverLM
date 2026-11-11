import Foundation
import Testing
@testable import ForeverLM

/// Runs `body` on a notebook state of its own (`NotebookStateStore.override`) and hands it the box
/// to seed and assert on.
private func withNotebookState<T>(_ body: (NotebookStateStore.Box) async throws -> T) async throws -> T {
    let box = NotebookStateStore.Box()
    return try await NotebookStateStore.$override.withValue(box) { try await body(box) }
}

// MARK: - MCP: notebook_id on the import tools

/// add_source, add_sources and import_paper_from_url file what they import in
/// the Notebook a notebook_id names, say so after the import's own answer, and
/// refuse an id that names no Notebook before anything is added
/// (docs/notebooks-design.md, "Imports").
extension MCPDataStoreTests {

    private func makeNotebookImportStore() throws -> (MCPDataStore, KnowledgeStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_nb_import_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), dir.path)
    }

    private func makeNotebook(_ title: String, in knowledge: KnowledgeStore) throws -> LearningGoalRecord {
        try knowledge.createCompanionGoal(
            title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
    }

    private func approved(_ notebookID: String, in knowledge: KnowledgeStore) throws -> [String] {
        try #require(try knowledge.loadLearningGoal(notebookID)).approvedSourceIDs
    }

    private func sourceID(at url: String, in knowledge: KnowledgeStore) -> String? {
        (knowledge.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? knowledge.sourceExistsByURL(url))?.id
    }

    @Test("add_source with a Notebook's notebook_id files the new source there, after the answer's own id")
    func addSourceFilesInNotebook() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Mitochondria", in: knowledge)
        let registry = MCPToolRegistry(store: store)
        let url = "https://example.org/essays/cristae"

        let outcome = await registry.callToolDetailed(name: "add_source", arguments: [
            "url": url, "title": "On cristae", "source_type": "article",
            "content": "The inner membrane folds.", "notebook_id": notebook.id,
        ])
        #expect(!outcome.isError)
        let id = try #require(sourceID(at: url, in: knowledge))
        // The mailbox reads "(id: src_…" out of the first line; the echo comes after it.
        #expect(outcome.text.hasPrefix("Added source 'On cristae' (id: \(id)"))
        #expect(outcome.text.hasSuffix("\nnotebook_id_applied: \(notebook.id) — filed in Notebook ‘Mitochondria’."))
        #expect(try approved(notebook.id, in: knowledge) == [id])

        // The same address again: already there, and already in the Notebook.
        let again = await registry.callToolDetailed(name: "add_source", arguments: [
            "url": url, "title": "On cristae", "source_type": "article", "notebook_id": notebook.id,
        ])
        #expect(again.text.hasPrefix("Source already exists (id: \(id)"))
        #expect(again.text.hasSuffix("notebook_id_applied: \(notebook.id) — already in Notebook ‘Mitochondria’."))
        #expect(try approved(notebook.id, in: knowledge) == [id])
    }

    @Test("A source the library already holds joins the Notebook without a second row")
    func addSourceFilesHeldSource() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Aging", in: knowledge)
        let url = "https://example.org/essays/senescence"
        _ = try store.addSource(url: url, title: "Senescence", sourceType: "article", content: "Cells stop.", parentGroup: nil, author: nil)
        let id = try #require(sourceID(at: url, in: knowledge))
        #expect(try approved(notebook.id, in: knowledge).isEmpty)

        let answer = try await store.addSourceNamingVideoChannel(
            url: url, title: "Senescence", sourceType: "article", content: nil, parentGroup: nil,
            author: nil, occurredAt: nil, connectorLabel: nil, notebookID: notebook.id
        )
        #expect(answer.hasPrefix("Source already exists (id: \(id)"))
        #expect(answer.hasSuffix("filed in Notebook ‘Aging’."))
        #expect(try approved(notebook.id, in: knowledge) == [id])
        #expect(try knowledge.loadSources().filter { $0.url == url }.count == 1)
    }

    @Test("A notebook_id that names no Notebook is refused before anything is added; blank and absent add to the library only")
    func addSourceRefusesNonNotebook() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Kept", in: knowledge)
        let archived = try makeNotebook("Put away", in: knowledge)
        try knowledge.setLearningGoalStatus(goalID: archived.id, status: .archived)
        let registry = MCPToolRegistry(store: store)
        _ = try store.addSource(url: "https://example.org/held", title: "Held", sourceType: "article", content: "x", parentGroup: nil, author: nil)
        let heldID = try #require(sourceID(at: "https://example.org/held", in: knowledge))

        // An unknown id, a source's id, and an archived Notebook: nothing is added.
        for (index, bad) in ["no-such-notebook", heldID, archived.id].enumerated() {
            let url = "https://example.org/refused-\(index)"
            let outcome = await registry.callToolDetailed(name: "add_source", arguments: [
                "url": url, "title": "Refused", "source_type": "article", "content": "y", "notebook_id": bad,
            ])
            #expect(outcome.isError, "\(bad)")
            #expect(sourceID(at: url, in: knowledge) == nil, "\(bad)")
        }

        // Absent, or blank as a model fills an unused slot: the library only.
        for (index, arguments) in [[:], ["notebook_id": ""], ["notebook_id": "  "]].enumerated() {
            let url = "https://example.org/library-only-\(index)"
            var call: [String: Any] = ["url": url, "title": "Library only", "source_type": "article", "content": "z"]
            call.merge(arguments) { $1 }
            let outcome = await registry.callToolDetailed(name: "add_source", arguments: call)
            #expect(!outcome.isError)
            #expect(!outcome.text.contains("notebook_id_applied"))
            #expect(sourceID(at: url, in: knowledge) != nil)
        }
        #expect(try approved(notebook.id, in: knowledge).isEmpty)
    }

    @Test("A Goal's id files the source on the Goal and on its Notebook")
    func addSourceFilesOnGoal() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Screens", in: knowledge)
        let goal = try knowledge.createCompanionGoal(
            title: "Understand pooled screens", topic: "screens", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let url = "https://example.org/screens"
        let answer = try await store.addSourceNamingVideoChannel(
            url: url, title: "Pooled screens", sourceType: "article", content: "Barcodes.", parentGroup: nil,
            author: nil, occurredAt: nil, connectorLabel: nil, notebookID: goal.id
        )
        let id = try #require(sourceID(at: url, in: knowledge))
        #expect(answer.hasSuffix("notebook_id_applied: \(goal.id) — filed in Goal ‘Understand pooled screens’."))
        #expect(try approved(goal.id, in: knowledge) == [id])
        #expect(try approved(notebook.id, in: knowledge) == [id])
    }

    @Test("add_sources files every item added, updated or already there, and counts them on its last line")
    func addSourcesFilesBatch() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Feed", in: knowledge)
        let registry = MCPToolRegistry(store: store)
        _ = try store.addSource(url: "https://example.org/in-it", title: "In it", sourceType: "article", content: "a", parentGroup: nil, author: nil)
        _ = try store.addSource(url: "https://example.org/held", title: "Held", sourceType: "article", content: "b", parentGroup: nil, author: nil)
        let inItID = try #require(sourceID(at: "https://example.org/in-it", in: knowledge))
        let heldID = try #require(sourceID(at: "https://example.org/held", in: knowledge))
        _ = try knowledge.addCompanionSeedSources(goalID: notebook.id, sourceIDs: [inItID])

        let outcome = await registry.callToolDetailed(name: "add_sources", arguments: [
            "notebook_id": notebook.id,
            "sources": [
                ["url": "https://example.org/new", "title": "New", "source_type": "article", "content": "c"],
                ["url": "https://example.org/in-it", "title": "In it", "source_type": "article"],
                ["url": "https://example.org/held", "title": "Held", "source_type": "article"],
                ["url": "https://example.org/untitled", "title": "", "source_type": "article"],
            ],
        ])
        #expect(!outcome.isError)
        let lines = outcome.text.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("Batch complete: 1 added, 0 updated, 2 already existed, 1 failed (of 4).") == true)
        #expect(lines.last == "notebook_id_applied: \(notebook.id) — Notebook ‘Feed’: 2 filed, 1 already in it, 0 not filed.")
        let newID = try #require(sourceID(at: "https://example.org/new", in: knowledge))
        #expect(Set(try approved(notebook.id, in: knowledge)) == [inItID, heldID, newID])
        #expect(sourceID(at: "https://example.org/untitled", in: knowledge) == nil)

        // Without notebook_id the answer is the batch's alone.
        let plain = await registry.callToolDetailed(name: "add_sources", arguments: [
            "sources": [["url": "https://example.org/plain", "title": "Plain", "source_type": "article", "content": "d"]],
        ])
        #expect(!plain.text.contains("notebook_id_applied"))
        #expect(!(try approved(notebook.id, in: knowledge)).contains(try #require(sourceID(at: "https://example.org/plain", in: knowledge))))

        // An id that names no Notebook: nothing in the batch is added.
        let refused = await registry.callToolDetailed(name: "add_sources", arguments: [
            "notebook_id": "no-such-notebook",
            "sources": [["url": "https://example.org/never", "title": "Never", "source_type": "article", "content": "e"]],
        ])
        #expect(refused.isError)
        #expect(sourceID(at: "https://example.org/never", in: knowledge) == nil)
    }

    @Test("An ingest-only plugin cannot name a notebook_id, and nothing is added")
    func ingestScopeRefusesNotebookID() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Private", in: knowledge)
        let registry = MCPToolRegistry(store: store)
        let ingest = MCPAccessContext(clientID: "dyn_test", scope: .ingest, connectorLabel: "Feed Bot")

        let single = await registry.callToolDetailed(name: "add_source", arguments: [
            "url": "https://example.org/bot-one", "title": "One", "source_type": "article", "content": "a", "notebook_id": notebook.id,
        ], access: ingest)
        #expect(single.isError)
        #expect(single.text.hasPrefix("Error: notebook_id is not available to an ingest-only plugin."))
        let batch = await registry.callToolDetailed(name: "add_sources", arguments: [
            "notebook_id": notebook.id,
            "sources": [["url": "https://example.org/bot-two", "title": "Two", "source_type": "article", "content": "b"]],
        ], access: ingest)
        #expect(batch.isError)
        #expect(sourceID(at: "https://example.org/bot-one", in: knowledge) == nil)
        #expect(sourceID(at: "https://example.org/bot-two", in: knowledge) == nil)
        #expect(try approved(notebook.id, in: knowledge).isEmpty)
    }

    @Test("import_paper_from_url checks notebook_id before any download, and files a paper the library holds")
    func importPaperFilesInNotebook() async throws {
        let (store, knowledge, path) = try makeNotebookImportStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebook = try makeNotebook("Papers to read", in: knowledge)
        let registry = MCPToolRegistry(store: store)
        // Seeded as an article: a ready paper needs the Paper Metadata model.
        let url = "https://example.org/papers/oxphos-2026"
        _ = try store.addSource(url: url, title: "OXPHOS", sourceType: "article", content: "Complex I.", parentGroup: nil, author: nil)
        let id = try #require(sourceID(at: url, in: knowledge))

        // Refused before the importer reaches the network: the address is never fetched.
        let refused = await registry.callToolDetailed(name: "import_paper_from_url", arguments: [
            "url": "https://example.invalid/papers/never-fetched", "notebook_id": "no-such-notebook",
        ])
        #expect(refused.isError)
        #expect(refused.text.contains("no-such-notebook"))
        #expect(sourceID(at: "https://example.invalid/papers/never-fetched", in: knowledge) == nil)

        // Absent: the import's own answer and nothing else.
        let plain = await registry.callToolDetailed(name: "import_paper_from_url", arguments: ["url": url])
        #expect(plain.text == "Source already exists (id: \(id), status: active)")
        #expect(try approved(notebook.id, in: knowledge).isEmpty)

        let filed = await registry.callToolDetailed(name: "import_paper_from_url", arguments: [
            "url": url, "notebook_id": notebook.id,
        ])
        #expect(!filed.isError)
        #expect(filed.text == "Source already exists (id: \(id), status: active)\nnotebook_id_applied: \(notebook.id) — filed in Notebook ‘Papers to read’.")
        #expect(try approved(notebook.id, in: knowledge) == [id])
    }

    @Test("The schemas offer notebook_id on the three import tools, never as required")
    func importSchemasOfferNotebookID() {
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        for name in ["add_source", "add_sources", "import_paper_from_url"] {
            let tool = tools.first { $0.name == name }
            let properties = tool?.inputSchema["properties"] as? [String: Any]
            #expect(properties?["notebook_id"] != nil, "\(name)")
            #expect((tool?.inputSchema["required"] as? [String])?.contains("notebook_id") == false, "\(name)")
        }
    }
}

// MARK: - A Notebook chat's imports

@Suite("A Notebook chat's imports")
@MainActor
struct NotebookChatImportScopeTests {
    @Test("An import a Notebook's chat asks for is pinned to that Notebook unless the model named one")
    func importsArePinned() {
        for tool in ["import_paper_from_url", "add_source", "add_sources"] {
            let filled = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: tool, arguments: ["url": "https://example.org/x"], notebookScopeID: "notebook-1"
            )
            #expect(filled["notebook_id"] as? String == "notebook-1", "\(tool)")
            let blank = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: tool, arguments: ["notebook_id": " "], notebookScopeID: "notebook-1"
            )
            #expect(blank["notebook_id"] as? String == "notebook-1", "\(tool)")
            let named = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: tool, arguments: ["notebook_id": "notebook-2"], notebookScopeID: "notebook-1"
            )
            #expect(named["notebook_id"] as? String == "notebook-2", "\(tool)")
        }
    }

    @Test("A Notebook that takes no imports, or one not yet read, has none pinned, and its prompt says where an import lands")
    func importsArePinnedOnlyWhereTheyCanLand() {
        typealias Filing = ReviewSessionManager.NotebookImportFiling
        for filing in [Filing.libraryOnly(.readOnlyTeam(teamName: "Theirs")), .libraryOnly(.archived), nil] as [Filing?] {
            let arguments = ReviewSessionManager.notebookScopedArgumentsForTesting(
                toolName: "add_source", arguments: ["url": "https://example.org/x"], notebookScopeID: "notebook-1", importFiling: filing
            )
            #expect(arguments["notebook_id"] == nil, "\(String(describing: filing))")
        }
        let tools = ["import_paper_from_url", "add_source"].map {
            ReviewSessionManager.AppToolDefinition(name: $0, description: $0, inputSchemaJSON: "{\"type\":\"object\"}")
        }
        func prompt(_ filing: Filing?) -> String {
            ReviewSessionManager.nativeSystemPromptForTesting(
                topic: "Mitochondria", hasAttachedSource: true, appTools: tools, notebookScopeID: "notebook-1", importFiling: filing
            )
        }
        let files = prompt(.files)
        #expect(files.contains("is filed in this Notebook as well as the library"))
        let readOnly = prompt(.libraryOnly(.readOnlyTeam(teamName: "Theirs")))
        #expect(readOnly.contains("This Notebook takes no new sources: team ‘Theirs’ is read-only for this account."))
        #expect(readOnly.contains("lands in the library only"))
        #expect(!readOnly.contains("is filed in this Notebook as well"))
        let unread = prompt(nil)
        #expect(!unread.contains("is filed in this Notebook as well"))
        #expect(!unread.contains("lands in the library only"))
    }
}

// MARK: - Calendar blocks that link a notebook

@Suite("Calendar block links")
struct CalendarEventLinkTests {
    private func event(url: String? = nil, notes: String?) -> AppleCalendarEvent {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return AppleCalendarEvent(
            calendarID: "CAL", eventIdentifier: "E1", occurrenceDate: nil, title: "Read the atlas",
            start: start, end: start.addingTimeInterval(5_400), isAllDay: false, isDeclined: false,
            isFree: false, isCancelled: false, isBirthday: false, location: nil, url: url,
            calendarTitle: "Work", notes: notes, hasOtherPeople: false, calendarAllowsModifications: true
        )
    }

    @Test("A block's notebook and sources are read from its URL field and notes")
    func readsNotebookAndSources() {
        let block = event(
            url: "foreverlm://source/src_url",
            notes: """
            Next: the methods section.
            Notebook: [Mitochondria](foreverlm://notebook/proj-123)
            [Atlas](foreverlm://source/src_abc "short quote") then foreverlm://source/src_def?q=complex%20I
            and [Atlas again](foreverlm://source/src_abc).
            Call: https://zoom.us/j/123 · not ours: https://foreverlm.com/notebook/web · other://notebook/elsewhere
            """
        )
        #expect(block.notebookID == "proj-123")
        #expect(block.sourceIDs == ["src_url", "src_abc", "src_def"])
    }

    @Test("A bare link's sentence punctuation and emphasis are not part of the id it names")
    func trailingPunctuationIsNotPartOfTheID() {
        let block = event(notes: """
        Open foreverlm://notebook/abc. Read **foreverlm://source/src_one**, then \u{201C}foreverlm://source/src_two\u{201D}; \
        also _foreverlm://source/src_three_! Was it foreverlm://source/src_four?
        """)
        #expect(block.notebookID == "abc")
        #expect(block.sourceIDs == ["src_one", "src_two", "src_three", "src_four"])
    }

    @Test("The running build's scheme names the same things; an event without links names none")
    func runtimeSchemeAndNone() {
        let scheme = ForeverLMRuntimeIdentity.urlScheme
        let block = event(notes: "[Dev](\(scheme)://notebook/p%20q) \(scheme)://source/src_dev")
        #expect(block.notebookID == "p q")
        #expect(event(notes: "[Before the rename](foreverlm://project/old-1)").notebookID == "old-1", "the address before the rename still names the notebook")
        #expect(block.sourceIDs == ["src_dev"])
        let plain = event(url: "https://meet.google.com/abc", notes: "Standup")
        #expect(plain.notebookID == nil)
        #expect(plain.sourceIDs.isEmpty)
        #expect(event(notes: nil).sourceIDs.isEmpty)
    }
}

// MARK: - In the app: importing a link into a notebook

@Suite("Importing a link into a notebook")
@MainActor
struct NotebookImportLinkTests {
    @Test("A link the library already holds joins the notebook without a second row, then reads as already in it")
    func heldLinkJoinsNotebook() async throws {
        // Adding to a notebook makes it the active Notebook, a shared default.
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let vm = makeViewModel()
        let url = "https://example.com/notebook-import"
        try await vm.addArticle(url: url, revealInReader: false)
        let sourceID = try #require(vm.librarySourceID(forURL: url))
        let notebook = try #require(await vm.createNotebookContext(title: "Mitochondria"))
        #expect(!vm.notebookHoldsSource(url: url, notebookID: notebook.id))

        let first = await vm.importLink(url, intoNotebook: notebook.id)
        #expect(first == StudioViewModel.NotebookImportOutcome(sourceID: sourceID, library: .alreadyHeld, membership: .added))
        #expect(first.landed)
        #expect(vm.notebook(id: notebook.id)?.approvedSourceIDs == [sourceID])
        #expect(vm.notebookHoldsSource(url: url, notebookID: notebook.id))
        #expect(vm.articles.filter { $0.url == url }.count == 1)

        let second = await vm.importLink(url, intoNotebook: notebook.id)
        #expect(second.membership == .alreadyIn)
        #expect(StudioViewModel.notebookImportToast(second, notebookTitle: "Mitochondria") == "Already in \u{201C}Mitochondria\u{201D}")

        // No notebook, or one that cannot take imports: the library alone.
        let libraryOnly = await vm.importLink(url, intoNotebook: nil)
        #expect(libraryOnly == StudioViewModel.NotebookImportOutcome(sourceID: sourceID, library: .alreadyHeld, membership: .none))
        let missing = await vm.importLink(url, intoNotebook: "no-such-notebook")
        #expect(missing.membership == .none)
    }

    @Test("The Reader's and the Browser pane's Add to Sources files a page into the window's notebook, and outside one into the library alone")
    func livePageAddFollowsTheWindow() async throws {
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let vm = makeViewModel()
        let notebook = try #require(await vm.createNotebookContext(title: "Mitochondria"))
        let inNotebook = StudioWindowState()
        inNotebook.NotebookID = notebook.id
        let outside = StudioWindowState()
        #expect(vm.notebookInScope(for: inNotebook)?.id == notebook.id)
        #expect(vm.notebookInScope(for: outside) == nil)

        // A page the library holds is done outside a notebook, and still to
        // add in the notebook's window; adding it there only files it.
        let held = try #require(URL(string: "https://example.com/live-page-held"))
        try await vm.addArticle(url: held.absoluteString, revealInReader: false)
        #expect(vm.livePageIsAdded(held, in: outside))
        #expect(!vm.livePageIsAdded(held, in: inNotebook))
        let joined = await vm.addLivePageToSources(held, in: inNotebook)
        #expect(joined == StudioViewModel.LivePageAdd(landed: true, addedSourceID: nil))
        #expect(vm.toastMessage == "Added to \u{201C}Mitochondria\u{201D}")
        #expect(vm.notebookHoldsSource(url: held.absoluteString, notebookID: notebook.id))
        #expect(vm.livePageIsAdded(held, in: inNotebook))

        // A new page in the notebook's window joins both, and says so.
        let fresh = try #require(URL(string: "https://example.com/live-page-fresh"))
        let added = await vm.addLivePageToSources(fresh, in: inNotebook)
        #expect(added.landed)
        #expect(added.addedSourceID != nil)
        #expect(added.addedSourceID == vm.librarySourceID(forURL: fresh.absoluteString))
        #expect(vm.toastMessage == "Added to Library and to \u{201C}Mitochondria\u{201D}")
        #expect(vm.notebookHoldsSource(url: fresh.absoluteString, notebookID: notebook.id))

        // Outside a notebook, and in a pop-out Reader (no window), the
        // library alone.
        let elsewhere = try #require(URL(string: "https://example.com/live-page-elsewhere"))
        let libraryOnly = await vm.addLivePageToSources(elsewhere, in: outside)
        #expect(libraryOnly.landed)
        #expect(vm.toastMessage == "Added to Library")
        #expect(vm.librarySourceID(forURL: elsewhere.absoluteString) != nil)
        #expect(!vm.notebookHoldsSource(url: elsewhere.absoluteString, notebookID: notebook.id))
        let again = await vm.addLivePageToSources(elsewhere, in: nil)
        #expect(again == StudioViewModel.LivePageAdd(landed: true, addedSourceID: nil))
        #expect(vm.toastMessage == "Already in Library")
    }

    @Test("A block's source links name library rows, and a notebook made from the block is found again by its title and sources")
    func blockSourcesAndMadeNotebook() async throws {
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let vm = makeViewModel()
        let url = "https://example.com/calendar-block-source"
        try await vm.addArticle(url: url, revealInReader: false)
        let sourceID = try #require(vm.librarySourceID(forURL: url))
        // A chat cites a source by a short prefix; one the library lacks is left out.
        let prefix = String(sourceID.prefix(10))
        #expect(vm.librarySourceIDs(forBlockLinks: [prefix, sourceID, "src_not_in_this_library"]) == [sourceID])
        #expect(vm.notebookMade(fromBlockTitled: "Read the atlas", sourceIDs: [sourceID]) == nil)

        let notebook = try #require(await vm.createNotebookContext(title: "Read the atlas"))
        await vm.addSourcesToNotebookContext([sourceID], notebookID: notebook.id, announce: false)
        #expect(vm.notebookMade(fromBlockTitled: " read the atlas ", sourceIDs: [prefix])?.id == notebook.id)
        #expect(vm.notebookMade(fromBlockTitled: "Another block", sourceIDs: [sourceID]) == nil)
    }

    @Test("A bout is filed under the notebook its block names, or the one made from the block this session, never a namesake")
    func boutNotebookIsNamedNotGuessed() async throws {
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let vm = makeViewModel()
        let namesake = try #require(await vm.createNotebookContext(title: "Read the atlas"))

        #expect(vm.boutNotebookID(forBlockNotebook: nil, blockKey: "E1") == nil, "a notebook titled as the block is not its notebook")
        #expect(vm.boutNotebookID(forBlockNotebook: namesake.id, blockKey: "E1") == namesake.id)
        #expect(vm.boutNotebookID(forBlockNotebook: "no-such-notebook", blockKey: "E1") == nil)

        // Make Notebook from This Block remembers the occurrence it was made from.
        vm.notebooksMadeFromBlocks["E1@1790000000"] = namesake.id
        #expect(vm.boutNotebookID(forBlockNotebook: nil, blockKey: "E1@1790000000") == namesake.id)
        #expect(vm.boutNotebookID(forBlockNotebook: nil, blockKey: "E1@1790086400") == nil, "another day's occurrence")
    }

    @Test("A link field imports a web address or a DOI, and leaves words to the search")
    func importableLinks() {
        #expect(StudioViewModel.importableLink(in: " https://www.nature.com/articles/s41586-024-1 ") == "https://www.nature.com/articles/s41586-024-1")
        #expect(StudioViewModel.importableLink(in: "10.1038/s41586-024-07000-1") == "https://doi.org/10.1038/s41586-024-07000-1")
        #expect(StudioViewModel.importableLink(in: "doi:10.1101/2026.01.01.123") == "https://doi.org/10.1101/2026.01.01.123")
        #expect(StudioViewModel.importableLink(in: "mitochondrial cristae") == nil)
        #expect(StudioViewModel.importableLink(in: "cristae") == nil)
        #expect(StudioViewModel.importableLink(in: "ftp://example.com/file") == nil)
        #expect(StudioViewModel.importableLink(in: "https://localhost") == nil)
        #expect(StudioViewModel.normalizedSourceAddress("  example.com/a ") == "https://example.com/a")
        #expect(StudioViewModel.normalizedSourceAddress("   ") == nil)
    }

    @Test("A cited page's title becomes the new source's first title, without the site's name")
    func citedPageTitles() {
        let host = "www.biorxiv.org"
        #expect(StudioViewModel.citedPageTitle("Mechanism of aging in blood | bioRxiv", host: host) == "Mechanism of aging in blood")
        #expect(StudioViewModel.citedPageTitle("Frontiers | Updating the Free Radical Theory of Aging", host: host) == "Updating the Free Radical Theory of Aging")
        #expect(StudioViewModel.citedPageTitle("", host: host) == nil)
        #expect(StudioViewModel.citedPageTitle(nil, host: host) == nil)
        #expect(StudioViewModel.citedPageTitle("WWW.biorxiv.org", host: host) == nil)
    }

    @Test("Each outcome says where the page went")
    func toasts() {
        typealias Outcome = StudioViewModel.NotebookImportOutcome
        let title = "Aging"
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .added, membership: .added), notebookTitle: title) == "Added to Library and to \u{201C}Aging\u{201D}")
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .alreadyHeld, membership: .added), notebookTitle: title) == "Added to \u{201C}Aging\u{201D}")
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .linkedPage, membership: .added), notebookTitle: title) == "Linked in \u{201C}Aging\u{201D}")
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .linkedPage, membership: .alreadyIn), notebookTitle: title) == "Already in \u{201C}Aging\u{201D}")
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .failed("Not a page."), membership: .none), notebookTitle: title) == "Not a page.")
        #expect(StudioViewModel.notebookImportToast(Outcome(library: .added, membership: .none), notebookTitle: nil) == "Added to Library")
        #expect(!Outcome(library: .added, membership: .failed("no")).landed)
    }
}

// MARK: - Team notebooks

/// A team's notebook holds the team's copies of the learner's own sources
/// (docs/teams-design.md, decision 10): every route that files into one —
/// add_source, import_paper_from_url, add_notebook_sources, the Sources +,
/// and a removal — goes through the team-aware write. A team this account
/// can only read takes nothing, and its notebook's chat imports to the
/// library alone.
@Suite("Imports into a team notebook")
@MainActor
struct NotebookTeamImportTests {

    private func makeStore() throws -> (MCPDataStore, KnowledgeStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_nb_team_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Generation 1's teams (zones of the old container); a space needs a running sync coordinator.
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), dir.path)
    }

    private func readySource(id: String, url: String, title: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        let text = "Enough readable text for \(title) to count as a source in the copy."
        article.content = text
        article.wordCount = text.split(separator: " ").count
        article.state = .ready
        return article
    }

    private func makeNotebook(_ title: String, in knowledge: KnowledgeStore) throws -> LearningGoalRecord {
        try knowledge.createCompanionGoal(
            title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
    }

    /// An editable team this account owns, holding a copy of a Notebook.
    private func teamNotebook(_ store: MCPDataStore, in knowledge: KnowledgeStore) async throws -> (teamID: String, notebookID: String) {
        let created = try #require(try JSONSerialization.jsonObject(with: Data(try await store.createTeam(name: "Nexus").utf8)) as? [String: Any])
        let teamID = try #require((created["team"] as? [String: Any])?["id"] as? String)
        let notebook = try makeNotebook("Mitochondria", in: knowledge)
        _ = try await store.shareWithTeam(teamID: teamID, kind: "notebook", ids: [notebook.id], includeSources: true, includeDocs: false)
        let notebookID = TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: notebook.id)
        #expect(try knowledge.loadLearningGoal(notebookID)?.teamID == teamID)
        return (teamID, notebookID)
    }

    /// A team this account can only read, and a notebook that arrived from its owner.
    private func readOnlyNotebook(in knowledge: KnowledgeStore) throws -> String {
        let now = Date()
        try knowledge.saveTeam(TeamRecord(
            id: "team-ro", name: "Theirs", role: .member, permission: .readOnly, zoneScope: .shared,
            zoneName: TeamRecord.zoneName(forTeamID: "team-ro"), zoneOwnerRecordName: "_owner-record",
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        try knowledge.saveLearningGoalRecord(LearningGoalRecord(
            id: "proj-theirs", title: "Their notebook", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now, status: "active", items: [],
            kind: LearningGoalRecord.companionKind, teamID: "team-ro"
        ))
        return "proj-theirs"
    }

    private func approved(_ notebookID: String, in knowledge: KnowledgeStore) throws -> [String] {
        try #require(try knowledge.loadLearningGoal(notebookID)).approvedSourceIDs
    }

    @Test("A read-only team's notebook refuses add_source, add_sources, import_paper_from_url and add_notebook_sources, adding nothing")
    func readOnlyTeamNotebookTakesNothing() async throws {
        let (store, knowledge, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebookID = try readOnlyNotebook(in: knowledge)
        try knowledge.saveSource(readySource(id: "own-1", url: "https://example.org/mine", title: "Mine"))
        let registry = MCPToolRegistry(store: store)

        let single = await registry.callToolDetailed(name: "add_source", arguments: [
            "url": "https://example.org/never-one", "title": "Never", "source_type": "article", "content": "a", "notebook_id": notebookID,
        ])
        let batch = await registry.callToolDetailed(name: "add_sources", arguments: [
            "notebook_id": notebookID,
            "sources": [["url": "https://example.org/never-two", "title": "Never", "source_type": "article", "content": "b"]],
        ])
        let paper = await registry.callToolDetailed(name: "import_paper_from_url", arguments: [
            "url": "https://example.invalid/papers/never-fetched", "notebook_id": notebookID,
        ])
        let pool = await registry.callToolDetailed(name: "add_notebook_sources", arguments: [
            "notebook_id": notebookID, "source_ids": ["own-1"],
        ])
        for outcome in [single, batch, paper, pool] {
            #expect(outcome.isError, "\(outcome.text)")
            #expect(outcome.text.contains("read-only"), "\(outcome.text)")
            #expect(outcome.text.contains("Nothing was added"), "\(outcome.text)")
        }
        for url in ["https://example.org/never-one", "https://example.org/never-two", "https://example.invalid/papers/never-fetched"] {
            #expect(knowledge.activeSourceID(matchingAddress: url, teamID: nil) == nil, "\(url)")
        }
        #expect(try approved(notebookID, in: knowledge).isEmpty)
        #expect(try knowledge.loadActiveSources(teamID: "team-ro").isEmpty)
    }

    @Test("A read-only team's notebook takes nothing from a review in its chat or from assign_sources_to_day, and the review still starts")
    func readOnlyTeamNotebookTakesNothingFromReviewsOrDayPlans() async throws {
        let (store, knowledge, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let notebookID = try readOnlyNotebook(in: knowledge)
        try knowledge.saveSource(readySource(id: "own-1", url: "https://example.org/mine", title: "Mine"))
        let registry = MCPToolRegistry(store: store)
        let chatID = "chat-their-notebook"
        try knowledge.createReviewSession(id: chatID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: notebookID)

        let review = await registry.callToolDetailed(
            name: "start_review_session",
            arguments: ["topic": "Mine", "source_ids": ["own-1"]],
            hostSessionID: chatID
        )
        #expect(!review.isError, "a read-only member may review; only the notebook's pool is not theirs to change: \(review.text)")
        #expect(try store.reviewSessionSourceIDs(sessionID: chatID) == ["own-1"])

        let day = await registry.callToolDetailed(name: "assign_sources_to_day", arguments: [
            "goal_id": notebookID, "source_ids": ["own-1"], "date": "today",
        ])
        #expect(day.isError, "\(day.text)")
        #expect(day.text.contains("read-only"), "\(day.text)")
        #expect(day.text.contains("Nothing was added"), "\(day.text)")

        #expect(try approved(notebookID, in: knowledge).isEmpty)
        #expect(try knowledge.loadActiveSources(teamID: "team-ro").isEmpty)
        #expect(try knowledge.loadScheduledSources(goalID: notebookID).isEmpty, "nothing was placed under or tagged to their notebook")
    }

    @Test("A read-only team notebook's chat imports to the library alone; a personal notebook's chat files in the notebook")
    func readOnlyNotebookChatImportsToTheLibrary() async throws {
        let (store, knowledge, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let theirs = try readOnlyNotebook(in: knowledge)
        let mine = try makeNotebook("Mine", in: knowledge)
        let registry = MCPToolRegistry(store: store)
        let url = "https://example.org/chat-import"
        let call: [String: Any] = ["url": url, "title": "From the chat", "source_type": "article", "content": "Cited in the chat."]

        let turn = await ReviewSessionManager.notebookChatImportTurnForTesting(
            storage: store.notebookFileStorage, notebookScopeID: theirs, toolName: "add_source", arguments: call
        )
        #expect(turn.filing == .libraryOnly(.readOnlyTeam(teamName: "Theirs")))
        #expect(turn.arguments["notebook_id"] == nil)
        #expect(turn.prompt.contains("lands in the library only"))
        let outcome = await registry.callToolDetailed(name: "add_source", arguments: turn.arguments)
        #expect(!outcome.isError, "\(outcome.text)")
        #expect(!outcome.text.contains("notebook_id_applied"))
        #expect(knowledge.activeSourceID(matchingAddress: url, teamID: nil) != nil, "the import itself lands")
        #expect(try approved(theirs, in: knowledge).isEmpty)

        let own = await ReviewSessionManager.notebookChatImportTurnForTesting(
            storage: store.notebookFileStorage, notebookScopeID: mine.id, toolName: "add_source", arguments: call
        )
        #expect(own.filing == .files)
        #expect(own.arguments["notebook_id"] as? String == mine.id)
        #expect(own.prompt.contains("is filed in this Notebook as well as the library"))

        try knowledge.setLearningGoalStatus(goalID: mine.id, status: .archived)
        let archived = await ReviewSessionManager.notebookChatImportTurnForTesting(
            storage: store.notebookFileStorage, notebookScopeID: mine.id, toolName: "import_paper_from_url", arguments: ["url": url]
        )
        #expect(archived.filing == .libraryOnly(.archived))
        #expect(archived.arguments["notebook_id"] == nil)
    }
}

// MARK: - Arrivals come in ticked, and course groups

@Suite("Notebook adds in the app")
@MainActor
struct NotebookAppAddTests {

    private func makeStore() throws -> (MCPDataStore, KnowledgeStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb_app_add_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        return (store, try store.knowledgeStore(), dir.path)
    }

    private func notebook(_ title: String, sources: [String], in knowledge: KnowledgeStore) throws -> LearningGoalRecord {
        try knowledge.createCompanionGoal(
            title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: sources
        )
    }

    @Test("Add All on a course links it to the notebook, as a drop does; Remove All unlinks it and takes its lectures out")
    func courseGroupLinksAndUnlinks() async throws {
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let (store, knowledge, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let courseID = "course-bioenergetics"
        let metadata = CourseMetadata(title: "Bioenergetics")
        try knowledge.saveCourseGroup(name: courseID, metadata: metadata)
        let lectures = ["lec-1", "lec-2"].map { (id: String) in
            StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .course, parentGroup: courseID, id: id)
        }
        for lecture in lectures { try knowledge.saveSource(lecture) }
        let energyNotebook = try notebook("Energy", sources: [], in: knowledge)

        let vm = StudioViewModel(storageService: store.notebookFileStorage)
        vm.notebookChatExclusions = [:]
        await vm.loadLearningGoals()
        vm.courseMetadata = [courseID: metadata]
        vm.articles = lectures
        #expect(vm.allCourseGroupNames.contains(courseID))

        await vm.addGroupToNotebook(courseID, notebookID: energyNotebook.id)
        #expect(try knowledge.linkedCourseIDsForNotebook(goalID: energyNotebook.id) == [courseID], "later lectures follow")
        #expect(Set(try knowledge.loadLearningGoal(energyNotebook.id)?.approvedSourceIDs ?? []) == ["lec-1", "lec-2"])

        await vm.removeGroupFromNotebook(courseID, rowIDs: ["lec-1", "lec-2"], notebookID: energyNotebook.id)
        #expect(try knowledge.linkedCourseIDsForNotebook(goalID: energyNotebook.id).isEmpty)
        #expect(try knowledge.loadLearningGoal(energyNotebook.id)?.approvedSourceIDs.isEmpty == true)
        #expect(try knowledge.unlinkCourseFromNotebook(goalID: energyNotebook.id, courseID: courseID) == false, "nothing left to unlink")
    }

    @Test("Add All on a group that is not a course adds what it holds, and links nothing")
    func nonCourseGroupAddsItsRows() async throws {
        let priorSelection = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = priorSelection }
        let (store, knowledge, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let series = ["mtg-1", "mtg-2"].map { (id: String) in
            StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .meeting, parentGroup: "Standup", id: id)
        }
        for meeting in series { try knowledge.saveSource(meeting) }
        let teamNotebook = try notebook("Team", sources: [], in: knowledge)

        let vm = StudioViewModel(storageService: store.notebookFileStorage)
        vm.notebookChatExclusions = [:]
        await vm.loadLearningGoals()
        vm.articles = series
        await vm.addGroupToNotebook("Standup", notebookID: teamNotebook.id)
        #expect(Set(try knowledge.loadLearningGoal(teamNotebook.id)?.approvedSourceIDs ?? []) == ["mtg-1", "mtg-2"])
        #expect(try knowledge.linkedCourseIDsForNotebook(goalID: teamNotebook.id).isEmpty)
    }
}
