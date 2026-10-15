#if os(macOS)
import Foundation
import Testing
@testable import ForeverLM

// A mnemonic reading over MCP (docs/memory-design.md, "Mnemonic reading"):
// the four tools' registration, generate_mnemonic_reading's price first and
// its run in the background, an assistant's own questions saved and grounded,
// the reading read with each question's Memory state, an answer kept as a
// card, and the Docs write tools refusing a reading.

private let chapterOne = """
System 1 operates automatically and quickly, with little or no effort and no sense of voluntary control.

System 2 allocates attention to the effortful mental activities that demand it, including complex computations.
"""

private let chapterTwo = """
Self-control and deliberate thought apparently draw on the same limited budget of effort.

People who are cognitively busy are more likely to make selfish choices.
"""

/// A route with the price a test names; the model is in no catalog.
private func readingRoute(input: Double? = 100, output: Double? = 200) -> NotebookWritingRoute {
    NotebookWritingRoute(
        provider: .openRouter,
        model: "test/reading-writer",
        writerInputBudget: nil,
        condenserInputBudget: nil,
        inputUSDPerMillion: input,
        outputUSDPerMillion: output
    )
}

/// One question on a passage each chapter prints, and one on words the first
/// never printed.
private struct CannedQuestions: MnemonicReadingBackend {
    func writeQuestions(system: String, user: String, maxTokens: Int, source: AIUsageSource, route: NotebookWritingRoute) async throws -> [MnemonicReadingModelQuestion] {
        if user.contains("Source: The Characters of the Story") {
            return [
                MnemonicReadingModelQuestion(
                    quote: "System 1 operates automatically and quickly",
                    question: "In Kahneman's account, which system operates automatically and quickly?",
                    answer: "System 1.",
                    why: "It runs with little or no effort."
                ),
                MnemonicReadingModelQuestion(quote: "a sentence this chapter never printed", question: "What is lost?", answer: "Nothing."),
            ]
        }
        return [
            MnemonicReadingModelQuestion(
                quote: "Self-control and deliberate thought apparently draw on the same limited budget of effort",
                question: "According to Kahneman, what do self-control and deliberate thought draw on?",
                answer: "The same limited budget of effort."
            ),
        ]
    }
}

private func chapter(_ id: String, title: String, text: String, sortIndex: Int) -> StudioArticle {
    var article = StudioArticle(url: "https://example.com/thinking/\(id)", title: title, sourceType: .book, discoveryOrigin: .manual, id: id)
    article.normalizedURL = URLNormalizer.normalize(article.url)
    article.content = text
    article.wordCount = text.split(whereSeparator: \.isWhitespace).count
    article.state = .ready
    article.parentGroup = "thinking-fast-and-slow"
    article.courseSortIndex = sortIndex
    return article
}

/// An MCP store over a library of its own: a book of two chapters, saved
/// second chapter first, and a notebook that ticks them both.
private func makeStore() async throws -> (store: MCPDataStore, notebook: LearningGoalRecord, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MnemonicReadingMCP_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
    let storage = store.notebookFileStorage
    try await storage.saveSource(chapter("c2", title: "The Lazy Controller", text: chapterTwo, sortIndex: 1))
    try await storage.saveSource(chapter("c1", title: "The Characters of the Story", text: chapterOne, sortIndex: 0))
    try await storage.saveBookMetadata(groupName: "thinking-fast-and-slow", title: "Thinking, Fast and Slow", coverPath: nil)
    let notebook = try await storage.createCompanionGoal(
        title: "Judgment",
        topic: "Judgment",
        startAt: Date(),
        endAt: LearningGoalRecord.openEndedEndAt,
        dailyTarget: 3,
        discoveryEnabled: false,
        seedSourceIDs: ["c1", "c2"]
    )
    return (store, notebook, { try? FileManager.default.removeItem(at: root) })
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// Waits for an MCP call's background work to end.
private func waitForWork(_ workID: String) async throws {
    for _ in 0..<400 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// An assistant's own reading of the book: one grounded question a chapter,
/// and one the first chapter never printed.
private let ownQuestions: [[String: Any]] = [
    [
        "source_id": "c1",
        "questions": [
            [
                "quote": "System 2 allocates attention to the effortful mental activities that demand it",
                "question": "Which system allocates attention to effortful mental activities?",
                "answer": "System 2.",
            ],
            ["quote": "words the chapter never prints", "question": "What is missing?", "answer": "Nothing."],
        ],
    ],
    [
        "source_id": "c2",
        "questions": [
            [
                "quote": "People who are cognitively busy are more likely to make selfish choices",
                "question": "What choices do cognitively busy people tend to make?",
                "answer": "Selfish ones.",
                "why": "Self-control draws on the same budget the busy task uses.",
            ],
        ],
    ],
]

@Suite("Mnemonic reading over MCP", .cardWordingPasses)
struct MnemonicReadingMCPTests {
    @Test("The four tools are registered: generate paid, self-gated and open-world with a popup, get read-only, and the makers in the study chats")
    @MainActor
    func registration() throws {
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.shared.tools.map { ($0.name, $0) })
        for name in MCPToolRegistry.mnemonicReadingToolNames {
            let tool = try #require(byName[name], "\(name)")
            #expect(tool.inputSchema["anyOf"] == nil)
            #expect(tool.inputSchema["type"] as? String == "object")
        }
        let generate = try #require(byName["generate_mnemonic_reading"])
        let properties = try #require(generate.inputSchema["properties"] as? [String: Any])
        for name in ["source_ids", "book", "notebook_id", "density", "reading_id", "confirm_cost", "approved_spend_usd"] {
            #expect(properties[name] != nil, "\(name)")
        }
        #expect((properties["density"] as? [String: Any])?["enum"] as? [String] == ["fewer", "auto", "more"])
        #expect(generate.description.contains("confirm_cost"))
        #expect(generate.description.contains("cancel_ai_work"))
        #expect(MCPToolRegistry.paidWorkToolNames.contains("generate_mnemonic_reading"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("generate_mnemonic_reading"))
        #expect(MCPToolRegistry.annotations(for: "generate_mnemonic_reading")["openWorldHint"] as? Bool == true)
        let title = try #require(MCPToolActivityTitle.forTool("generate_mnemonic_reading", arguments: [:]))
        #expect(title.subject == .reading)
        #expect(title.text(subjectName: "Thinking, Fast and Slow") == "Writing questions for Thinking, Fast and Slow")
        #expect(MCPToolActivityTitle.shownToolNames.contains("generate_mnemonic_reading"))

        #expect(MCPToolRegistry.annotations(for: "get_mnemonic_reading")["readOnlyHint"] as? Bool == true)
        for name in ["save_mnemonic_reading", "answer_mnemonic_question"] {
            let annotations = MCPToolRegistry.annotations(for: name)
            #expect(annotations["readOnlyHint"] as? Bool == false, "\(name)")
            #expect(annotations["destructiveHint"] as? Bool == false, "\(name)")
            #expect(!MCPToolRegistry.paidWorkToolNames.contains(name), "\(name) costs nothing")
        }
        #expect(byName["answer_mnemonic_question"]?.inputSchema["required"] as? [String] == ["reading_id", "question_id", "remembered"])
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["generate_mnemonic_reading", "save_mnemonic_reading"]))
        #expect(ReviewSessionManager.studySurfaceToolNames.isDisjoint(with: ["get_mnemonic_reading", "answer_mnemonic_question"]))
    }

    @Test("The gateway's catalogue carries the four tools exactly as the registry writes them")
    func catalogue() throws {
        let committed = try Data(contentsOf: MCPToolContractTests.catalogueURL)
        let entries = try #require(try JSONSerialization.jsonObject(with: committed) as? [[String: Any]])
        let tools = MCPToolRegistry.shared.tools.filter { MCPToolRegistry.mnemonicReadingToolNames.contains($0.name) }
        #expect(tools.count == 4)
        let expected = try #require(
            try JSONSerialization.jsonObject(with: Data(MCPToolContractTests.canonicalJSON(for: tools).utf8)) as? [[String: Any]]
        )
        for entry in expected {
            let name = entry["name"] as? String
            let found = entries.first { $0["name"] as? String == name }
            #expect(found.map { NSDictionary(dictionary: $0) } == NSDictionary(dictionary: entry), "\(name ?? "")")
        }
    }

    @Test("generate_mnemonic_reading refuses what it cannot make, and prices the writing before spending anything")
    func refusalsAndThePrice() async throws {
        let (store, notebook, cleanup) = try await makeStore()
        defer { cleanup() }
        let storage = store.notebookFileStorage
        let route = readingRoute()
        let backend = CannedQuestions()
        for arguments: [String: Any] in [
            [:],
            ["source_ids": ["c1"], "book": "Thinking, Fast and Slow"],
            ["reading_id": "r", "notebook_id": notebook.id],
            ["source_ids": ["c1", "not-in-library"]],
            ["book": "No Such Book"],
            ["source_ids": ["c1"], "density": "lots"],
            ["notebook_id": "missing"],
            ["reading_id": "missing"],
        ] {
            await #expect(throws: MCPError.self, "\(arguments)") {
                _ = try await store.generateMnemonicReading(arguments: arguments, backend: backend, route: route)
            }
        }

        // A book by its title: its chapters in reading order, priced, and
        // nothing written without confirm_cost.
        let quoted = try object(try await store.generateMnemonicReading(
            arguments: ["book": "thinking, fast and slow", "density": "more"],
            backend: backend,
            route: route
        ))
        #expect(quoted["status"] as? String == "awaiting_confirmation")
        #expect(quoted["reading_id"] == nil)
        #expect(quoted["work_id"] == nil)
        #expect(quoted["title"] as? String == "Thinking, Fast and Slow with questions")
        #expect(quoted["density"] as? String == "more")
        #expect((quoted["sources"] as? [[String: Any]])?.map { $0["source_id"] as? String } == ["c1", "c2"])
        let estimate = try #require((quoted["estimate"] as? [String: Any])?["writing"] as? [String: Any])
        #expect(estimate["estimated_cost_usd"] is Double)
        #expect(estimate["requests"] as? Int == 2)
        #expect((quoted["question_count"] as? Int ?? 0) >= 2)
        #expect(try await storage.loadArtifacts().isEmpty)

        // Agreed, but above the approved ceiling: still nothing started.
        let tooLow = try object(try await store.generateMnemonicReading(
            arguments: ["notebook_id": notebook.id, "confirm_cost": true, "approved_spend_usd": 0.000001],
            backend: backend,
            route: route
        ))
        #expect(tooLow["status"] as? String == "approval_too_low")
        #expect(try await storage.loadArtifacts().isEmpty)
    }

    @Test("Once agreed, the questions are written in the background into a reading filed in the Notebook, and get_mnemonic_reading reads it")
    func writesInTheBackground() async throws {
        let (store, notebook, cleanup) = try await makeStore()
        defer { cleanup() }
        let storage = store.notebookFileStorage
        let started = try object(try await store.generateMnemonicReading(
            arguments: ["notebook_id": notebook.id, "confirm_cost": true],
            backend: CannedQuestions(),
            route: readingRoute()
        ))
        #expect(started["status"] as? String == "started")
        #expect(started["cost_confirmed_by"] == nil)
        let readingID = try #require(started["reading_id"] as? String)
        // The Notebook's ticked sources, in its order, which the reading keeps.
        let planned = try #require((started["sources"] as? [[String: Any]])?.compactMap { $0["source_id"] as? String })
        #expect(Set(planned) == ["c1", "c2"])
        try await waitForWork(try #require(started["work_id"] as? String))

        let saved = try #require(try await storage.loadArtifacts().first { $0.id == readingID })
        #expect(saved.kind == .mnemonicReading)
        #expect(saved.homeNotebookID == notebook.id)
        #expect(saved.sourceIDs == planned)

        let read = try object(try await store.getMnemonicReading(arguments: ["reading_id": readingID]))
        #expect(read["kind"] as? String == "mnemonic_reading")
        #expect(read["notebook_id"] as? String == notebook.id)
        #expect((read["sources"] as? [[String: Any]])?.map { $0["status"] as? String } == ["written", "written"])
        let questions = try #require(read["questions"] as? [[String: Any]])
        // The question on words the chapter never printed was dropped.
        #expect(questions.compactMap { $0["source_id"] as? String } == planned)
        let first = try #require(questions.first { $0["source_id"] as? String == "c1" })
        #expect(first["quote"] as? String == "System 1 operates automatically and quickly")
        #expect(first["why"] as? String == "It runs with little or no effort.")
        #expect(first["difficulty"] == nil)
        #expect(questions.allSatisfy { ($0["memory"] as? [String: Any])?["state"] as? String == "unanswered" })
        #expect(read["counts"] as? [String: Int] == ["questions": 2, "answered": 0, "due": 0])
        let lastRun = try #require(read["last_run"] as? [String: Any])
        #expect((lastRun["summary"] as? String)?.contains("1 not found in its text") == true)

        // Every source written: nothing more to write.
        let again = try object(try await store.generateMnemonicReading(
            arguments: ["reading_id": readingID],
            backend: CannedQuestions(),
            route: readingRoute()
        ))
        #expect(again["status"] as? String == "nothing_to_write")
    }

    @Test("A free model starts at once")
    func freeModelStarts() async throws {
        let (store, _, cleanup) = try await makeStore()
        defer { cleanup() }
        let started = try object(try await store.generateMnemonicReading(
            arguments: ["source_ids": ["c2"]],
            backend: CannedQuestions(),
            route: readingRoute(input: 0, output: 0)
        ))
        #expect(started["status"] as? String == "started")
        #expect(started["cost_confirmed_by"] as? String == "free_model")
        #expect(started["title"] as? String == "The Lazy Controller with questions")
        try await waitForWork(try #require(started["work_id"] as? String))
    }

    @Test("save_mnemonic_reading saves an assistant's own questions grounded, lists the rest, and adds to a reading without saving a question twice")
    func savesOwnQuestions() async throws {
        let (store, notebook, cleanup) = try await makeStore()
        defer { cleanup() }
        let storage = store.notebookFileStorage

        await #expect(throws: MCPError.self) {
            _ = try await store.saveMnemonicReading(arguments: ["title": "R", "sources": [["source_id": "not-in-library", "questions": []]]])
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.saveMnemonicReading(arguments: ["sources": ownQuestions])
        }
        #expect(try await storage.loadArtifacts().isEmpty)

        let saved = try object(try await store.saveMnemonicReading(arguments: [
            "title": "Thinking, Fast and Slow with questions",
            "notebook_id": notebook.id,
            "sources": ownQuestions,
        ]))
        #expect(saved["saved_count"] as? Int == 2)
        let readingID = try #require(saved["reading_id"] as? String)
        let rows = try #require(saved["sources"] as? [[String: Any]])
        #expect(rows.map { $0["source_id"] as? String } == ["c1", "c2"])
        #expect((rows[0]["not_grounded"] as? [[String: Any]])?.map { $0["question"] as? String } == ["What is missing?"])
        #expect((rows[0]["saved_question_ids"] as? [String])?.count == 1)
        let record = try #require(try await storage.loadArtifacts().first { $0.id == readingID })
        #expect(record.kind == .mnemonicReading)
        #expect(record.homeNotebookID == notebook.id)

        // The same questions again add nothing.
        let repeated = try object(try await store.saveMnemonicReading(arguments: ["reading_id": readingID, "sources": ownQuestions]))
        #expect(repeated["saved_count"] as? Int == 0)
        #expect((repeated["sources"] as? [[String: Any]])?.first?["already_written"] as? Int == 1)
        let read = try object(try await store.getMnemonicReading(arguments: ["reading_id": readingID]))
        #expect((read["questions"] as? [[String: Any]])?.count == 2)
    }

    @Test("answer_mnemonic_question keeps the card on the first answer, once a sitting, and the reading reads it back from Memory")
    func answers() async throws {
        let (store, _, cleanup) = try await makeStore()
        defer { cleanup() }
        let saved = try object(try await store.saveMnemonicReading(arguments: ["title": "R", "sources": ownQuestions]))
        let readingID = try #require(saved["reading_id"] as? String)
        let questionID = try #require(((saved["sources"] as? [[String: Any]])?.first?["saved_question_ids"] as? [String])?.first)

        for arguments: [String: Any] in [
            ["reading_id": readingID, "question_id": questionID],
            ["reading_id": readingID, "question_id": questionID, "remembered": 1],
            ["reading_id": readingID, "question_id": "mq-none", "remembered": true],
            ["reading_id": "missing", "question_id": questionID, "remembered": true],
        ] {
            await #expect(throws: MCPError.self, "\(arguments)") {
                _ = try await store.answerMnemonicQuestion(arguments: arguments)
            }
        }

        let kept = try object(try await store.answerMnemonicQuestion(arguments: [
            "reading_id": readingID, "question_id": questionID, "remembered": false,
        ]))
        #expect(kept["outcome"] as? String == "kept")
        let itemID = try #require(kept["item_id"] as? String)
        #expect(itemID == MemoryTutorIdentity.cardItemID(cardID: questionID))
        let memory = try #require(kept["memory"] as? [String: Any])
        #expect(memory["state"] as? String == "kept")
        #expect(memory["last_grade"] as? String == "forgot")
        #expect(memory["next_due_at"] is String)

        let again = try object(try await store.answerMnemonicQuestion(arguments: [
            "reading_id": readingID, "question_id": questionID, "remembered": true,
        ]))
        #expect(again["outcome"] as? String == "already_recorded")
        let elsewhere = try object(try await store.answerMnemonicQuestion(arguments: [
            "reading_id": readingID, "question_id": questionID, "remembered": true, "sitting_id": "another-sitting",
        ]))
        #expect(elsewhere["outcome"] as? String == "not_counted")

        let read = try object(try await store.getMnemonicReading(arguments: ["reading_id": readingID]))
        #expect(read["counts"] as? [String: Int] == ["questions": 2, "answered": 1, "due": 0])
        let answered = (read["questions"] as? [[String: Any]])?.first { $0["question_id"] as? String == questionID }
        #expect((answered?["memory"] as? [String: Any])?["item_id"] as? String == itemID)
    }

    @Test("The Docs write tools refuse a reading, read_doc points at get_mnemonic_reading, and get_mnemonic_reading refuses a Doc")
    func docsToolsRefuseAReading() async throws {
        let (store, _, cleanup) = try await makeStore()
        defer { cleanup() }
        let saved = try object(try await store.saveMnemonicReading(arguments: ["title": "R", "sources": ownQuestions]))
        let readingID = try #require(saved["reading_id"] as? String)
        let read = try object(try await store.readArtifact(artifactID: readingID))
        let revision = try #require(read["revision"] as? String)
        #expect((read["guidance"] as? String)?.contains("get_mnemonic_reading") == true)
        #expect((read["doc"] as? [String: Any])?["kind"] as? String == "mnemonic_reading")

        await #expect(throws: MCPError.self) {
            _ = try await store.writeArtifact(artifactID: readingID, markdown: "# Mine now", expectedRevision: revision)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.editArtifact(
                artifactID: readingID,
                edits: [.init(find: "System 2.", replace: "System 1.")],
                append: nil,
                expectedRevision: revision
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.publishArtifact(artifactID: readingID, readers: nil)
        }
        let unchanged = try object(try await store.readArtifact(artifactID: readingID))
        #expect(unchanged["revision"] as? String == revision)

        let doc = try await store.notebookFileStorage.createArtifact(title: "Notes", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "# Notes")
        await #expect(throws: MCPError.self) {
            _ = try await store.getMnemonicReading(arguments: ["reading_id": doc.artifact.id])
        }
    }
}
#endif
