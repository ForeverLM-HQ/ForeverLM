import Foundation
import Testing
@testable import ForeverLM

// A mnemonic reading's writer (docs/memory-design.md, "Mnemonic reading"):
// the turn and its rules, the parts a long source is read in, the price,
// what a model's answer becomes, and the run over a store of its own with a
// canned writer — each source saved as it finishes, a failure said and left
// pending, a retry writing only what is pending.

// MARK: - Fixtures

private let chapterOne = """
System 1 operates automatically and quickly, with little or no effort and no sense of voluntary control.

System 2 allocates attention to the effortful mental activities that demand it, including complex computations.
"""

private let chapterTwo = """
Self-control and deliberate thought apparently draw on the same limited budget of effort.

People who are cognitively busy are more likely to make selfish choices.
"""

/// A route with the window and price a test names. The model is in no
/// catalog, so nothing else trims or prices against it.
private func readingRoute(budget: Int? = nil, input: Double? = 100, output: Double? = 200) -> NotebookWritingRoute {
    NotebookWritingRoute(
        provider: .openRouter,
        model: "test/reading-writer",
        writerInputBudget: budget,
        condenserInputBudget: budget,
        inputUSDPerMillion: input,
        outputUSDPerMillion: output
    )
}

/// The writer's turns, and the questions a test hands back for them.
private final class CannedWriter: MnemonicReadingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTurns: [String] = []
    private let answer: @Sendable (String) throws -> [MnemonicReadingModelQuestion]

    init(_ answer: @escaping @Sendable (String) throws -> [MnemonicReadingModelQuestion]) {
        self.answer = answer
    }

    var turns: [String] {
        lock.withLock { storedTurns }
    }

    func writeQuestions(system: String, user: String, maxTokens: Int, source: AIUsageSource, route: NotebookWritingRoute) async throws -> [MnemonicReadingModelQuestion] {
        lock.withLock { storedTurns.append(user) }
        return try answer(user)
    }
}

/// Collects what the run's progress saw.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MnemonicReading] = []
    var readings: [MnemonicReading] { lock.withLock { stored } }
    func append(_ reading: MnemonicReading) { lock.withLock { stored.append(reading) } }
}

private func readingSource(_ id: String, title: String, text: String, book: String? = "Thinking, Fast and Slow") -> MnemonicReadingSource {
    MnemonicReadingSource(sourceID: id, title: title, sourceType: "book", kindLabel: NotebookSourceKind.label(.book), bookTitle: book, text: text)
}

private func materials(_ sources: [MnemonicReadingSource], density: MnemonicReadingDensity = .auto) -> MnemonicReadingMaterials {
    MnemonicReadingMaterials(
        request: MnemonicReadingRequest(notebookID: nil, sourceIDs: sources.map(\.sourceID), density: density),
        title: "Thinking, Fast and Slow with questions",
        sources: sources,
        skipped: [],
        existing: nil
    )
}

private func chapter(_ id: String, title: String, text: String, sortIndex: Int? = nil, group: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: "https://example.com/book/\(id)", title: title, sourceType: group == nil ? .article : .book, discoveryOrigin: .manual, id: id)
    article.normalizedURL = URLNormalizer.normalize(article.url)
    article.content = text
    article.wordCount = text.split(whereSeparator: \.isWhitespace).count
    article.state = .ready
    article.parentGroup = group
    article.courseSortIndex = sortIndex
    return article
}

/// Storage on a folder of its own holding two chapters with text.
private func makeStorage() async throws -> (StorageService, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MnemonicReading_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storage = StorageService(storeRoot: root)
    try await storage.saveSource(chapter("c1", title: "The Characters of the Story", text: chapterOne))
    try await storage.saveSource(chapter("c2", title: "The Lazy Controller", text: chapterTwo))
    return (storage, { try? FileManager.default.removeItem(at: root) })
}

/// A model answer for whichever chapter the turn is about: one question on a
/// passage it prints and one on words it never printed.
private let answerForChapter: @Sendable (String) throws -> [MnemonicReadingModelQuestion] = { user in
    if user.contains("Source: The Characters of the Story") {
        return [
            MnemonicReadingModelQuestion(
                quote: "System 1 operates automatically and quickly",
                question: "In Kahneman's account, which system operates automatically and quickly?",
                answer: "System 1.",
                why: "It runs with little or no effort.",
                difficulty: "easy"
            ),
            MnemonicReadingModelQuestion(quote: "a sentence this chapter never printed", question: "What is lost?", answer: "Nothing."),
        ]
    }
    return [
        MnemonicReadingModelQuestion(
            quote: "Self-control and deliberate thought apparently draw on the same limited budget of effort",
            question: "According to Kahneman, what do self-control and deliberate thought draw on?",
            answer: "The same limited budget of effort.",
            why: nil,
            difficulty: "medium"
        ),
    ]
}

// MARK: - Tests

@Suite("Mnemonic reading: writing the questions", .cardWordingPasses)
struct MnemonicReadingWriterTests {
    @Test("Mnemonic Reading Writing is an AI task of its own, on the Background text model, the learner's to start")
    func aiTask() {
        let task = AITask.mnemonicReadingWriting
        #expect(task.rawValue == "mnemonic_reading_writing")
        #expect(task.defaultPrompt == Prompts.mnemonicReadingWriter)
        #expect(task.sourceType == nil)
        #expect(task.usesBackgroundModelDefault)
        #expect(!task.followsChatRoute)
        #expect(!task.requiresVision)
        #expect(!task.isBackgroundWork)
        #expect(AITask.advancedTasks.contains(task))
        #expect(AITaskSettingsCatalog.version >= 31)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "mnemonic_reading_writing")?.displayName == "Mnemonic Reading Writing")
        #expect(AIUsageTaskLabel.text(for: "mnemonic_reading_writing") == "Write Mnemonic Reading")
    }

    @Test("The turn carries quantum.country's rules, the source's own text whole, the book it is a chapter of and the questions the density asks")
    func turn() {
        for rule in ["quantum.country", "One detail each", "never yes or no", "blanked out", "Standalone", "last sentence", "copied exactly", "Return JSON only", "\"quote\""] {
            #expect(Prompts.mnemonicReadingWriter.contains(rule), "the prompt says \(rule)")
        }
        let long = String(repeating: "word ", count: 3_500)
        let one = readingSource("c1", title: "The Characters of the Story", text: chapterOne)
        let two = readingSource("c2", title: "The Long Chapter", text: long)
        let plan = MnemonicReadingPlanner.plan(materials([one, two]), route: readingRoute(), system: Prompts.mnemonicReadingWriter)
        #expect(plan.sources.map(\.source.sourceID) == ["c1", "c2"])
        #expect(plan.sources.map(\.parts.count) == [1, 1])
        let turn = plan.sources[0].parts[0].user
        #expect(turn.contains("Source: The Characters of the Story"))
        #expect(turn.contains("Kind: book chapter"))
        #expect(turn.contains("Book: Thinking, Fast and Slow"))
        #expect(turn.contains("Questions to write: 1"))
        #expect(turn.hasSuffix("Text:\n" + chapterOne))
        #expect(plan.sources[1].questionCount == 10)
        #expect(plan.sources[1].parts[0].user.contains("Questions to write: 10"))
        #expect(MnemonicReadingPlanner.plan(materials([two]), density: .more, route: readingRoute()).questionCount == 18)
        #expect(MnemonicReadingPlanner.plan(materials([two]), density: .fewer, route: readingRoute()).questionCount == 5)
        #expect(plan.summary == "2 chapters · \((one.words + two.words).formatted()) words")
    }

    @Test("A source too long for the window is read in consecutive parts cut at paragraphs, each fitting; a window with no room leaves it out")
    func parts() {
        let paragraph = String(repeating: "A sentence of the chapter. ", count: 11).trimmingCharacters(in: .whitespaces)
        let text = Array(repeating: paragraph, count: 60).joined(separator: "\n\n")
        let source = readingSource("c1", title: "Long", text: text)
        let system = Prompts.mnemonicReadingWriter
        let budget = system.count + 6_000
        let plan = MnemonicReadingPlanner.plan(materials([source]), route: readingRoute(budget: budget), system: system)
        let parts = plan.sources[0].parts
        #expect(parts.count > 1)
        #expect(parts.map(\.text).joined() == text)
        for part in parts.dropLast() {
            #expect(part.text.hasSuffix("\n\n"), "part \(part.index) ends at a paragraph")
        }
        for part in parts {
            #expect(system.count + part.user.count + MnemonicReadingPlanner.requestOverheadCharacters <= budget)
            #expect(part.user.contains("Text [Part \(part.index) of \(parts.count)]"))
            #expect(part.questionCount >= 1)
        }
        #expect(plan.sources[0].questionCount == parts.reduce(0) { $0 + $1.questionCount })
        #expect(plan.splitTitles == ["Long"])

        let cramped = MnemonicReadingPlanner.plan(materials([source]), route: readingRoute(budget: system.count + 300), system: system)
        #expect(cramped.sources.isEmpty)
        #expect(cramped.skipped.map(\.sourceID) == ["c1"])
        #expect(cramped.skipped.first?.reason.contains("context window") == true)

        #expect(MnemonicReadingPlanner.split("one\n\ntwo\n\nthree", into: 1) == ["one\n\ntwo\n\nthree"])
        #expect(MnemonicReadingPlanner.shares(of: 10, lengths: [100, 300]) == [3, 7])
        #expect(MnemonicReadingPlanner.shares(of: 1, lengths: [100, 100, 100]) == [1, 1, 1])
    }

    @Test("The price covers every request — the questions at their usual length, at most every request's ceiling — free on a free route, unknown on an unpriced one")
    func price() {
        let sources = [readingSource("c1", title: "One", text: chapterOne), readingSource("c2", title: "Two", text: chapterTwo)]
        let plan = MnemonicReadingPlanner.plan(materials(sources), route: readingRoute())
        #expect(plan.cost.requestCount == plan.callCount)
        #expect(plan.callCount == 2)
        let expected = plan.cost.expectedUSD ?? 0
        #expect(expected > 0)
        #expect((plan.cost.maximumUSD ?? 0) >= expected)
        #expect(plan.priceLine == "2 questions · \(plan.cost.label)")
        let free = MnemonicReadingPlanner.plan(materials(sources), route: readingRoute(input: 0, output: 0))
        #expect(free.cost.isFree)
        #expect(free.priceLine == "2 questions · free")
        let unpriced = MnemonicReadingPlanner.plan(materials(sources), route: readingRoute(input: nil, output: nil))
        #expect(unpriced.cost.label == "price unknown")
        #expect(!unpriced.cost.isFree)
    }

    @Test("A canned answer becomes the reading's questions: ids minted from content, a link or a missing part refused, no more than a quarter past what was asked")
    func parsesAnswer() throws {
        let response = """
        Here are the questions.
        ```json
        {"questions": [
          {"quote": "System 1 operates automatically and quickly", "question": "Which system operates automatically?", "answer": "System 1.", "why": "null", "difficulty": "Easy"},
          {"quote": "", "question": "No quote?", "answer": "None."},
          {"quote": "System 2 allocates attention", "question": "See https://example.com", "answer": "System 2."},
          {"quote": "System 2 allocates attention", "question": "Which system allocates attention?", "answer": "System 2.", "why": "It does the effortful work.", "difficulty": "hard"},
          {"quote": "including complex computations", "question": "What does System 2 include?", "answer": "Complex computations."},
          {"quote": "with little or no effort", "question": "How much effort does System 1 take?", "answer": "Little or none."}
        ]}
        ```
        """
        let answer: MnemonicReadingModelAnswer = try MemoryReviewPlanning.decodeJSON(response)
        let drafts = MnemonicReadingDrafts.questions(answer.questions, sourceID: "c1", asked: 2)
        #expect(drafts.questions.count == 3)
        #expect(drafts.questions[0].why == nil)
        #expect(drafts.questions[0].difficulty == .easy)
        #expect(drafts.questions[0].id == MnemonicQuestion.id(sourceID: "c1", quote: "System 1 operates automatically and quickly", question: "Which system operates automatically?"))
        #expect(drafts.questions[1].difficulty == .hard)
        #expect(drafts.questions.allSatisfy { $0.sourceID == "c1" })
        #expect(drafts.refused.map(\.reason) == [
            "It had no question, no answer or no quote.",
            "It wrote a link, which ForeverLM writes itself.",
            "More questions than were asked for.",
        ])
    }

    @Test("Each source's questions are saved as it finishes: the reading appears with its first source, the others pending, then fills in; a quote its text does not print is dropped")
    func savesEachSource() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let request = MnemonicReadingRequest(notebookID: nil, sourceIDs: ["c1", "c2"], density: .auto)
        let materials = try await MnemonicReadingWriter.load(request, storage: storage)
        #expect(materials.sources.map(\.sourceID) == ["c1", "c2"])
        #expect(materials.title == "The Characters of the Story with questions")
        let plan = MnemonicReadingPlanner.plan(materials, route: readingRoute())
        let writer = CannedWriter(answerForChapter)
        let seen = Seen()
        let readingID = "reading-1"
        let result = try await MnemonicReadingWriter.run(plan, readingID: readingID, storage: storage, backend: writer) { _ in
            if let reading = try? await storage.mnemonicReading(readingID).reading { seen.append(reading) }
        }
        #expect(writer.turns.count == 2)
        #expect(result.readingExists)
        #expect(result.addedCount == 2)
        #expect(result.ungroundedCount == 1)
        #expect(result.failures.isEmpty)
        #expect(result.summary == "2 questions · 1 not found in its text")

        // After the first source: the reading, that source written, the other pending.
        let first = try #require(seen.readings.first)
        #expect(first.sections.map(\.sourceID) == ["c1", "c2"])
        #expect(first.pendingSourceIDs.count == 1)
        #expect(seen.readings.last?.pendingSourceIDs.isEmpty == true)

        let (record, reading) = try await storage.mnemonicReading(readingID)
        #expect(record.kind == .mnemonicReading)
        #expect(record.title == "The Characters of the Story with questions")
        #expect(record.sourceIDs == ["c1", "c2"])
        #expect(reading.title == record.title)
        #expect(reading.sections.map(\.title) == ["The Characters of the Story", "The Lazy Controller"])
        #expect(reading.questions.map(\.question) == [
            "In Kahneman's account, which system operates automatically and quickly?",
            "According to Kahneman, what do self-control and deliberate thought draw on?",
        ])
        #expect(!reading.questions.contains { $0.question == "What is lost?" })
    }

    @Test("A source whose request fails is said and stays pending, and a run written into the reading again writes only it")
    func failureAndRetry() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let request = MnemonicReadingRequest(notebookID: nil, sourceIDs: ["c1", "c2"], density: .auto)
        let plan = MnemonicReadingPlanner.plan(try await MnemonicReadingWriter.load(request, storage: storage), route: readingRoute())
        let failing = CannedWriter { user in
            if user.contains("Source: The Lazy Controller") { throw AIError.invalidResponse }
            return try answerForChapter(user)
        }
        let result = try await MnemonicReadingWriter.run(plan, readingID: "reading-2", storage: storage, backend: failing)
        #expect(result.failures.map(\.sourceID) == ["c2"])
        #expect(result.failures.first?.failure == AIError.invalidResponse.localizedDescription)
        #expect(result.summary.contains("1 source failed"))
        let afterFailure = try await storage.mnemonicReading("reading-2").reading
        #expect(afterFailure.pendingSourceIDs == ["c2"])
        let keptID = try #require(afterFailure.section(sourceID: "c1")?.questions.first?.id)

        let retry = MnemonicReadingRequest(notebookID: nil, sourceIDs: afterFailure.pendingSourceIDs, density: .auto, readingID: "reading-2")
        let retryMaterials = try await MnemonicReadingWriter.load(retry, storage: storage)
        #expect(retryMaterials.existing != nil)
        #expect(retryMaterials.title == "The Characters of the Story with questions")
        let writer = CannedWriter(answerForChapter)
        let retried = try await MnemonicReadingWriter.run(
            MnemonicReadingPlanner.plan(retryMaterials, route: readingRoute()),
            readingID: "reading-2",
            storage: storage,
            backend: writer
        )
        #expect(writer.turns.count == 1)
        #expect(retried.addedCount == 1)
        let reading = try await storage.mnemonicReading("reading-2").reading
        #expect(reading.pendingSourceIDs.isEmpty)
        #expect(reading.section(sourceID: "c1")?.questions.map(\.id) == [keptID])
        #expect(reading.sections.map(\.sourceID) == ["c1", "c2"])

        // Nothing to write into a reading that is gone.
        await #expect(throws: (any Error).self) {
            try await storage.saveMnemonicReadingSection(readingID: "gone", sourceID: "c1", sourceTitle: "One", questions: [], creatingWith: nil)
        }
    }

    @Test("The reading's title is the book's for a book's chapters, the source's for one source, else the notebook's it is made in")
    func titles() {
        let first = chapter("b1", title: "The Characters of the Story", text: chapterOne, sortIndex: 0, group: "book-1")
        let second = chapter("b2", title: "Attention and Effort", text: chapterTwo, sortIndex: 1, group: "book-1")
        let article = chapter("a1", title: "An Article", text: chapterOne)
        let books = ["book-1": "Thinking, Fast and Slow"]
        #expect(MnemonicReadingWriter.title(for: [first, second], bookTitles: books, notebookTitle: "Notebook") == "Thinking, Fast and Slow with questions")
        #expect(MnemonicReadingWriter.title(for: [first], bookTitles: books, notebookTitle: "Notebook") == "The Characters of the Story with questions")
        #expect(MnemonicReadingWriter.title(for: [first, article], bookTitles: books, notebookTitle: "Biases") == "Biases with questions")
        #expect(MnemonicReadingWriter.title(for: [first, article], bookTitles: books, notebookTitle: nil) == "The Characters of the Story with questions")
    }

    @Test("A book's chapters are found by its id or its title, in reading order")
    func bookChapters() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveSource(chapter("b2", title: "Attention and Effort", text: chapterTwo, sortIndex: 1, group: "book-1"))
        try store.saveSource(chapter("b1", title: "The Characters of the Story", text: chapterOne, sortIndex: 0, group: "book-1"))
        try store.saveSource(chapter("b3", title: "The Lazy Controller", text: chapterTwo, sortIndex: 2, group: "book-1"))
        try store.saveBookMetadata(groupName: "book-1", title: "Thinking, Fast and Slow", coverPath: nil)
        let byID = try #require(try store.bookChapters(named: "book-1"))
        #expect(byID.bookID == "book-1")
        #expect(byID.title == "Thinking, Fast and Slow")
        #expect(byID.sourceIDs == ["b1", "b2", "b3"])
        #expect(try store.bookChapters(named: "thinking, fast and slow")?.sourceIDs == ["b1", "b2", "b3"])
        #expect(try store.bookChapters(named: "No Such Book") == nil)
    }

    @Test("A team's copy of a reading names the team's copies of its sources and keeps its questions' ids")
    func teamCopyBody() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveSource(chapter("c1", title: "The Characters of the Story", text: chapterOne))
        let question = MnemonicQuestion.mint(sourceID: "c1", quote: "System 1 operates automatically", question: "Which system?", answer: "System 1.")
        let body = MnemonicReading(title: "R", sections: [
            .init(sourceID: "c1", title: "One", isWritten: true, questions: [question]),
            .init(sourceID: "not-in-library", title: "Gone", isWritten: false),
        ]).markdown
        let copy = MnemonicReading.parse(try store.mnemonicReadingTeamCopyBody(body, fallbackTitle: "R", teamID: "team-1"), fallbackTitle: "R")
        let teamSource = try store.teamSourceCopyID(teamID: "team-1", url: "https://example.com/book/c1")
        #expect(teamSource != "c1")
        #expect(copy.sections.map(\.sourceID) == [teamSource, "not-in-library"])
        #expect(copy.questions.map(\.sourceID) == [teamSource])
        #expect(copy.questions.map(\.id) == [question.id])
        #expect(copy.pendingSourceIDs == ["not-in-library"])
    }
}
