import Foundation
import Testing
@testable import ForeverLM

// A new notebook needs no name (docs/notebooks-design.md, "A notebook names
// itself"): the placeholder, the row that lets ForeverLM rename a notebook
// (`NotebookNaming.Mark`), when it does, and the model's turn.

@Suite("Notebook naming: the rules")
struct NotebookNamingRuleTests {
    @Test("The placeholder is New notebook, numbered while that name is taken")
    func placeholderNumbers() {
        #expect(NotebookNaming.placeholder(existingTitles: []) == "New notebook")
        #expect(NotebookNaming.placeholder(existingTitles: ["Mitochondrial proteome"]) == "New notebook")
        #expect(NotebookNaming.placeholder(existingTitles: [" new notebook "]) == "New notebook 2")
        #expect(NotebookNaming.placeholder(existingTitles: ["New notebook", "New notebook 2", "New notebook 4"]) == "New notebook 3")
    }

    @Test("Only New notebook and its numbered forms are placeholders")
    func placeholderRecognised() {
        #expect(NotebookNaming.isPlaceholder("New notebook"))
        #expect(NotebookNaming.isPlaceholder(" new Notebook "))
        #expect(NotebookNaming.isPlaceholder("New notebook 12"))
        #expect(!NotebookNaming.isPlaceholder("New notebook on aging"))
        #expect(!NotebookNaming.isPlaceholder("New notebook 2b"))
        #expect(!NotebookNaming.isPlaceholder("New notebooks"))
        #expect(!NotebookNaming.isPlaceholder("Bioelectricity"))
    }

    @Test("A mark round-trips as a JSON string; anything else is no row")
    func markCodec() {
        let mark = NotebookNaming.Mark(title: "Complex I assembly", summary: "How complex I is put together", sources: 1, exchanges: 0)
        #expect(NotebookNaming.Mark.decoded(mark.encoded) == mark)
        #expect(NotebookNaming.Mark.decoded(NotebookNaming.Mark.unnamed(title: "New notebook").encoded)?.isNamed == false)
        #expect(NotebookNaming.Mark.decoded(nil) == nil)
        #expect(NotebookNaming.Mark.decoded(7) == nil)
        #expect(NotebookNaming.Mark.decoded("not json") == nil)
        #expect(NotebookNaming.Mark.decoded(#"{"title":"  "}"#) == nil)
        #expect(NotebookNaming.preferenceKey(notebookID: "p1") == "notebook.naming.p1")
    }

    @Test("No row, or a name the row does not carry, is never renamed")
    func learnerNamesAreKept() {
        // Every notebook made before this, or made with a name: no row.
        #expect(NotebookNaming.decision(mark: nil, title: "New notebook", summary: nil, sources: 5, exchanges: 3) == .keep)
        // The learner (or a device that never heard of the row) renamed it.
        let unnamed = NotebookNaming.Mark.unnamed(title: "New notebook")
        #expect(NotebookNaming.decision(mark: unnamed, title: "Mitochondrial disease", summary: nil, sources: 1, exchanges: 0) == .keep)
        // …or gave it a description.
        #expect(NotebookNaming.decision(mark: unnamed, title: "New notebook", summary: "Mine", sources: 1, exchanges: 0) == .keep)
        let named = NotebookNaming.Mark(title: "Complex I", summary: "Assembly", sources: 1, exchanges: 0)
        #expect(NotebookNaming.decision(mark: named, title: "Complex I assembly", summary: "Assembly", sources: 9, exchanges: 0) == .keep)
    }

    @Test("An unnamed notebook is named once it holds a source or a chat exchange")
    func firstName() {
        let unnamed = NotebookNaming.Mark.unnamed(title: "New notebook 2")
        #expect(NotebookNaming.decision(mark: unnamed, title: "New notebook 2", summary: nil, sources: 0, exchanges: 0) == .keep)
        #expect(NotebookNaming.decision(mark: unnamed, title: " New notebook 2", summary: "", sources: 1, exchanges: 0) == .name)
        #expect(NotebookNaming.decision(mark: unnamed, title: "New notebook 2", summary: nil, sources: 0, exchanges: 1) == .name)
    }

    @Test("A named notebook is named once more after two more sources or its first exchange, then never")
    func sharpenOnce() {
        let fromOnePaper = NotebookNaming.Mark(title: "Complex I", summary: "Assembly", sources: 1, exchanges: 0)
        #expect(NotebookNaming.decision(mark: fromOnePaper, title: "Complex I", summary: "Assembly", sources: 2, exchanges: 0) == .keep)
        #expect(NotebookNaming.decision(mark: fromOnePaper, title: "Complex I", summary: "Assembly", sources: 3, exchanges: 0) == .sharpen)
        #expect(NotebookNaming.decision(mark: fromOnePaper, title: "Complex I", summary: "Assembly", sources: 1, exchanges: 1) == .sharpen)
        // Named from a chat already: a second chat alone does not rename it.
        let fromChat = NotebookNaming.Mark(title: "Complex I", summary: nil, sources: 0, exchanges: 1)
        #expect(NotebookNaming.decision(mark: fromChat, title: "Complex I", summary: nil, sources: 0, exchanges: 4) == .keep)
        #expect(NotebookNaming.decision(mark: fromChat, title: "Complex I", summary: nil, sources: 2, exchanges: 4) == .sharpen)
    }
}

@Suite("Notebook naming: the model's turn")
struct NotebookNamingPromptTests {
    private let request = NotebookNaming.Request(
        notebookID: "p1",
        currentTitle: "New notebook",
        instructions: "Why complex I fails in Leigh syndrome",
        sources: [
            .init(title: "Complex I assembly factors", kind: "paper", opening: "Mitochondrial complex I is   the largest\nenzyme of the respiratory chain."),
            .init(title: "Leigh syndrome review", kind: "article", opening: ""),
        ],
        exchanges: [
            .init(chatTitle: "Assembly", learner: "What does NDUFAF1 do?", reply: "It is an assembly factor of complex I."),
        ]
    )

    @Test("The turn names what the learner is learning, each source with its opening, and how the chats began")
    func userMessage() {
        let message = NotebookNaming.userMessage(request, totalSources: 14)
        #expect(message.contains("What the learner said they are trying to learn: Why complex I fails in Leigh syndrome"))
        #expect(message.contains("Sources in the notebook (14):"))
        #expect(message.contains("1. Complex I assembly factors [paper]\nMitochondrial complex I is the largest enzyme of the respiratory chain."))
        #expect(message.contains("2. Leigh syndrome review [article]"))
        #expect(message.contains("… and 12 more."))
        #expect(message.contains("Learner: What does NDUFAF1 do?\nForeverLM: It is an assembly factor of complex I."))
    }

    @Test("A source's opening is clipped to its budget")
    func clipsOpenings() {
        var long = request
        long.sources = [.init(title: "Long", kind: "book", opening: String(repeating: "a", count: 2_000))]
        long.exchanges = []
        let message = NotebookNaming.userMessage(long, totalSources: 1)
        #expect(message.contains(String(repeating: "a", count: NotebookNaming.sourceOpeningCharacters) + "…"))
        #expect(!message.contains(String(repeating: "a", count: NotebookNaming.sourceOpeningCharacters + 1)))
        #expect(!message.contains("How the learner's chats"))
    }

    @Test("A canned answer reads, fenced or not; the title is one line and the description a card line")
    func parsesAnswer() throws {
        let fenced = """
        ```json
        {"title": "“Complex I assembly in Leigh syndrome”\\n", "description": "How complex I is built,\\n and how its assembly factors fail."}
        ```
        """
        let answer = try NotebookNaming.answer(from: fenced)
        #expect(answer.title == "Complex I assembly in Leigh syndrome")
        #expect(answer.summary == "How complex I is built, and how its assembly factors fail.")
        #expect(try NotebookNaming.answer(from: #"{"title":"Cristae remodelling"}"#).summary == nil)
        let longTitle = try NotebookNaming.answer(from: "{\"title\":\"\(String(repeating: "b", count: 200))\"}")
        #expect(longTitle.title.count == NotebookNaming.maximumTitleLength)
    }

    @Test("An answer without a title, or not JSON, is refused rather than guessed at")
    func refusesBadAnswers() {
        #expect(throws: NotebookNaming.AnswerError.noTitle) { try NotebookNaming.answer(from: #"{"title":"  ","description":"x"}"#) }
        #expect(throws: NotebookNaming.AnswerError.unreadable) { try NotebookNaming.answer(from: "Complex I assembly") }
    }
}

@Suite("Notebook naming: its AI task")
struct NotebookNamingTaskTests {
    @Test("Notebook Naming is a task of its own: in Settings' list, on the Background model, counted as background work")
    func taskIsConfigurable() {
        #expect(AITaskSettingsCatalog.version >= 32)
        let task = AITask.notebookNaming
        #expect(task.rawValue == "notebook_naming")
        #expect(task.displayName == "Notebook Naming")
        #expect(AITask.advancedTasks.contains(task))
        #expect(task.usesBackgroundModelDefault)
        #expect(task.isBackgroundWork)
        #expect(task.defaultPrompt == Prompts.notebookNaming)
        #expect(Prompts.notebookNaming.contains("not a whole field"))
        #expect(AIUsageTaskLabel.text(for: "notebook_naming") == "Name Notebook")
    }
}

// MARK: - The Mac's flow

/// The requests a canned namer was asked, in order.
private actor NamerLog {
    private(set) var requests: [NotebookNaming.Request] = []
    func record(_ request: NotebookNaming.Request) { requests.append(request) }
}

@Suite("Notebook naming: making and naming a notebook on the Mac")
@MainActor
struct NotebookNamingFlowTests {
    private func withRows(_ body: () async throws -> Void) async throws {
        let suiteName = "NotebookNamingFlowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Adding a source notes the notebook as worked in, and making one
        // selects it for MCP: both are the unit host's real defaults.
        let recency = UserDefaults.standard.object(forKey: NotebookRecency.preferenceKey)
        let activeNotebookID = ActiveNotebookPreference.notebookID
        defer {
            UserDefaults.standard.set(recency, forKey: NotebookRecency.preferenceKey)
            ActiveNotebookPreference.notebookID = activeNotebookID
        }
        try await NotebookNamingRows.$overrideDefaults.withValue(NotebookNamingRows.DefaultsOverride(defaults: defaults)) {
            try await body()
        }
    }

    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookNamingFlowTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func papers(_ vm: StudioViewModel, _ titles: [String]) async throws -> [StudioArticle] {
        let made = titles.enumerated().map { index, title in
            StudioArticle(url: "https://doi.org/10.1000/naming-\(UUID().uuidString)-\(index)", title: title, sourceType: .paper)
        }
        for paper in made { try await vm.storage.saveSource(paper) }
        vm.articles += made
        return made
    }

    /// A namer answering `titles` in turn, logging what it was asked.
    private func cannedNamer(_ log: NamerLog, titles: [String]) -> NotebookNamingService.Namer {
        let answers = titles
        return { request, _ in
            await log.record(request)
            let index = min(await log.requests.count, answers.count) - 1
            return NotebookNaming.Answer(title: answers[index], summary: "About \(answers[index])")
        }
    }

    /// The naming runs in a task the reload starts: waits for it to land.
    private func settle(_ vm: StudioViewModel, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // And for a task in flight to finish.
        for _ in 0..<400 where !vm.notebookNamingIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("A new notebook needs no name: it is made at once under the placeholder, flagged unnamed")
    func createsWithoutAName() async throws {
        try await withRows {
            let vm = makeViewModel()
            let first = try #require(await vm.createNotebook())
            let second = try #require(await vm.createNotebook())
            #expect(first.title == "New notebook")
            #expect(second.title == "New notebook 2")
            #expect(first.summary == nil)
            #expect(NotebookNamingRows.mark(notebookID: first.id) == .unnamed(title: "New notebook"))
            #expect(vm.notebookNamingMarks[second.id] == .unnamed(title: "New notebook 2"))
            // Nothing in it yet: nothing to name it from.
            #expect(vm.notebookNamingDecision(first.id) == .keep)
        }
    }

    @Test("Its first source names it; two more sharpen it once; then it is never renamed")
    func namesThenSharpensOnce() async throws {
        try await withRows {
            let vm = makeViewModel()
            let log = NamerLog()
            vm.notebookNamerOverride = cannedNamer(log, titles: ["Complex I assembly", "Complex I assembly in Leigh syndrome"])
            let sources = try await papers(vm, ["NDUFAF1 and complex I", "Leigh syndrome genetics", "Assembly intermediates", "Cristae"])
            let notebook = try #require(await vm.createNotebook(sourceIDs: [sources[0].id]))
            await settle(vm) { vm.notebook(id: notebook.id)?.title == "Complex I assembly" }

            #expect(vm.notebook(id: notebook.id)?.title == "Complex I assembly")
            #expect(vm.notebook(id: notebook.id)?.summary == "About Complex I assembly")
            #expect(vm.notebookNamingMarks[notebook.id] == NotebookNaming.Mark(title: "Complex I assembly", summary: "About Complex I assembly", sources: 1, exchanges: 0))
            #expect(await log.requests.first?.sources.map(\.title) == ["NDUFAF1 and complex I"])
            #expect(await log.requests.first?.currentTitle == "New notebook")

            await vm.addSourcesToNotebookContext([sources[1].id], notebookID: notebook.id, announce: false)
            await settle(vm) { false }
            #expect(await log.requests.count == 1, "one more source is not enough to rename it")

            await vm.addSourcesToNotebookContext([sources[2].id], notebookID: notebook.id, announce: false)
            await settle(vm) { vm.notebook(id: notebook.id)?.title == "Complex I assembly in Leigh syndrome" }
            #expect(vm.notebook(id: notebook.id)?.title == "Complex I assembly in Leigh syndrome")
            #expect(vm.notebookNamingMarks[notebook.id] == nil, "named twice: never again")
            #expect(NotebookNamingRows.mark(notebookID: notebook.id) == nil)

            await vm.addSourcesToNotebookContext([sources[3].id], notebookID: notebook.id, announce: false)
            await settle(vm) { false }
            #expect(await log.requests.count == 2)
        }
    }

    @Test("A name or description the learner typed is never renamed")
    func learnerNameWins() async throws {
        try await withRows {
            let vm = makeViewModel()
            let log = NamerLog()
            vm.notebookNamerOverride = cannedNamer(log, titles: ["Should not appear"])
            let sources = try await papers(vm, ["A paper"])
            let renamed = try #require(await vm.createNotebook())
            await vm.renameNotebook(renamed.id, to: "My own name")
            #expect(vm.notebookNamingMarks[renamed.id] == nil)
            let described = try #require(await vm.createNotebook())
            await vm.setNotebookSummary("My own line", notebookID: described.id)
            #expect(vm.notebookNamingMarks[described.id] == nil)

            await vm.addSourcesToNotebookContext(sources.map(\.id), notebookID: renamed.id, announce: false)
            await vm.addSourcesToNotebookContext(sources.map(\.id), notebookID: described.id, announce: false)
            await settle(vm) { false }
            #expect(await log.requests.isEmpty)
            #expect(vm.notebook(id: renamed.id)?.title == "My own name")
            #expect(vm.notebook(id: described.id)?.title == "New notebook", "the first is no longer called that")
        }
    }

    @Test("A name typed while the model answers is kept over the model's")
    func learnerNameDuringTheCallWins() async throws {
        try await withRows {
            let vm = makeViewModel()
            let sources = try await papers(vm, ["A paper"])
            let notebook = try #require(await vm.createNotebook())
            vm.notebookNamerOverride = { _, _ in
                await vm.renameNotebook(notebook.id, to: "Typed meanwhile")
                return NotebookNaming.Answer(title: "Model's name", summary: nil)
            }
            await vm.addSourcesToNotebookContext(sources.map(\.id), notebookID: notebook.id, announce: false)
            await settle(vm) { vm.notebook(id: notebook.id)?.title == "Typed meanwhile" }
            #expect(vm.notebook(id: notebook.id)?.title == "Typed meanwhile")
            #expect(vm.notebookNamingMarks[notebook.id] == nil)
        }
    }

    @Test("Without AI set up the placeholder stays and the notebook says why")
    func noAIKeepsThePlaceholder() async throws {
        try await withRows {
            let vm = makeViewModel()
            // The unit host is signed out: Notebook Naming has no route. A
            // host that has one stops here rather than ask a real model.
            try #require(KeychainService.resolveConfig(for: .notebookNaming) == nil)
            let sources = try await papers(vm, ["A paper"])
            let notebook = try #require(await vm.createNotebook(sourceIDs: sources.map(\.id)))
            await settle(vm) { vm.notebookNamingErrors[notebook.id] != nil }
            #expect(vm.notebook(id: notebook.id)?.title == "New notebook")
            #expect(vm.notebookNamingErrors[notebook.id]?.isEmpty == false)
            #expect(vm.notebookNamingMarks[notebook.id] == .unnamed(title: "New notebook"), "named as soon as AI is set up")
        }
    }

    @Test("A lost connection leaves the placeholder with nothing in the header; the next change names it")
    func transientFailureShowsNothing() async throws {
        try await withRows {
            let vm = makeViewModel()
            let sources = try await papers(vm, ["A paper", "Another paper"])
            let notebook = try #require(await vm.createNotebook())
            let log = NamerLog()
            vm.notebookNamerOverride = { request, _ in
                await log.record(request)
                throw URLError(.networkConnectionLost)
            }
            await vm.addSourcesToNotebookContext([sources[0].id], notebookID: notebook.id, announce: false)
            await settle(vm) { false }
            #expect(await !log.requests.isEmpty)
            #expect(vm.notebookNamingErrors[notebook.id] == nil)
            #expect(vm.notebook(id: notebook.id)?.title == "New notebook")
            #expect(vm.notebookNamingMarks[notebook.id] == .unnamed(title: "New notebook"))

            vm.notebookNamerOverride = cannedNamer(log, titles: ["Two papers"])
            await vm.addSourcesToNotebookContext([sources[1].id], notebookID: notebook.id, announce: false)
            await settle(vm) { vm.notebook(id: notebook.id)?.title == "Two papers" }
            #expect(vm.notebook(id: notebook.id)?.title == "Two papers")
        }
    }

    @Test("A failure that will not pass by itself shows in the header")
    func permanentFailureShows() async throws {
        try await withRows {
            let vm = makeViewModel()
            let sources = try await papers(vm, ["A paper"])
            let notebook = try #require(await vm.createNotebook())
            vm.notebookNamerOverride = { _, _ in throw AIError.invalidResponse }
            await vm.addSourcesToNotebookContext(sources.map(\.id), notebookID: notebook.id, announce: false)
            await settle(vm) { vm.notebookNamingErrors[notebook.id] != nil }
            #expect(vm.notebookNamingErrors[notebook.id]?.isEmpty == false)
        }
    }

    @Test("Every New notebook on the Mac goes through the one creation path, with no form")
    func oneCreationPath() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .appendingPathComponent("App")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var sources: [String: String] = [:]
        for file in files { sources[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8) }
        #expect(!sources.values.contains { $0.contains("NewNotebookSheet") }, "the New notebook sheet is gone")
        // The entry points: the Space's New ▸ Notebook and its sidebar's ⋯ ›
        // New Notebook, the sidebar's and Library's New Notebook with
        // sources, From This Chat.
        #expect(sources["SpaceBrowseView.swift"]?.contains("vm.makeAndOpenNotebook(in:") == true)
        #expect(sources["SpaceSidebar.swift"]?.contains("vm.makeAndOpenNotebook(in:") == true)
        #expect(sources["StudioSidebar.swift"]?.contains("vm.createNotebook(sourceIDs:") == true)
        #expect(sources["NotebookFilingMenus.swift"]?.contains("vm.createNotebook(\n                    fromChat:") == true)
        // A notebook the learner makes is never named by a view itself.
        let namedCreates = sources.filter { $0.value.contains("createNotebookContext(") }.keys.sorted()
        #expect(namedCreates == ["InternalReviewPanel.swift"], "only a chat's synthesis makes a notebook named from its own content")
    }
}
