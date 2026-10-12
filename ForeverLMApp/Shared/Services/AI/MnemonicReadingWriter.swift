import Foundation
import OSLog

// MARK: - Writing a mnemonic reading
//
// docs/memory-design.md, "Mnemonic reading". The writer reads each source's
// whole stored text — a book's chapters in order, or any chapter, paper or
// article — and asks the learner's Mnemonic Reading Writing model for its
// questions, one request a source. A source too long for the model's window is
// asked in consecutive parts cut at paragraph boundaries: never sampled, never
// cut. Each source's questions are saved as soon as they are written, so the
// reading appears after its first source and fills in, and a question whose
// quote its source does not print is dropped at the save. A source that fails
// stays pending in the reading and can be written again. Nothing is spent
// before the learner has seen the price (the sheet, or `generate_mnemonic_reading`).

/// One Make: what to read, how densely, and where it is made.
struct MnemonicReadingRequest: Equatable, Sendable {
    /// The notebook the reading is made in — its home, where its row is
    /// listed — or nil for one made from the Reader outside a notebook.
    var notebookID: String?
    /// The sources, in reading order.
    var sourceIDs: [String]
    var density: MnemonicReadingDensity
    /// The reading whose pending sources are written again, or nil for a
    /// new reading.
    var readingID: String? = nil
}

/// A source as the writer reads it: its whole stored text.
struct MnemonicReadingSource: Equatable, Sendable {
    let sourceID: String
    let title: String
    /// Its source type's raw value, for the usage ledger.
    let sourceType: String
    /// What it is in the writer's words: "book chapter", "research paper".
    let kindLabel: String
    /// The book a chapter is of.
    let bookTitle: String?
    let text: String
    let words: Int

    init(sourceID: String, title: String, sourceType: String, kindLabel: String, bookTitle: String?, text: String) {
        self.sourceID = sourceID
        self.title = title
        self.sourceType = sourceType
        self.kindLabel = kindLabel
        self.bookTitle = bookTitle
        self.text = text
        self.words = text.split(whereSeparator: \.isWhitespace).count
    }
}

/// A source left out, and why, in words the sheet and the answer say.
struct MnemonicReadingSkip: Equatable, Sendable {
    let sourceID: String
    let title: String
    let reason: String
    /// Kept from AI or archived: the app's sheet names it, an assistant hears
    /// only its id (as `CardDraftingSkip`).
    var isKeptFromAI = false
}

/// Everything a request reads before anything is planned or spent.
struct MnemonicReadingMaterials: Sendable {
    let request: MnemonicReadingRequest
    /// The reading's title: "<book or source> with questions".
    let title: String
    let sources: [MnemonicReadingSource]
    let skipped: [MnemonicReadingSkip]
    /// The reading written into, as its body reads now; nil for a new one.
    let existing: MnemonicReading?
}

// MARK: - The turn

/// The writer's user message: what varies after the fixed instructions
/// (`Prompts.mnemonicReadingWriter`), so the head the prompt cache keeps is
/// the same for every source.
enum MnemonicReadingTurn {
    /// The response budget one request asks for: room for each question's
    /// quote, question, answer and why.
    static func maxTokens(questionCount: Int) -> Int {
        min(12_000, 600 + max(1, questionCount) * 200)
    }

    /// The most any one request asks for, which the route's window is sized by.
    static var largestMaxTokens: Int {
        maxTokens(questionCount: MnemonicReadingDensity.more.capPerSource)
    }

    static func userMessage(
        source: MnemonicReadingSource,
        questionCount: Int,
        part: (index: Int, count: Int)?,
        text: String
    ) -> String {
        var lines = [
            "Source: \(MnemonicReading.singleLine(source.title))",
            "Kind: \(source.kindLabel)",
        ]
        if let book = source.bookTitle.map(MnemonicReading.singleLine), !book.isEmpty {
            lines.append("Book: \(book)")
        }
        lines.append("Questions to write: \(questionCount)")
        lines.append("")
        if let part {
            lines.append("Text [Part \(part.index) of \(part.count)]: one consecutive part of the source; the other parts are asked about in other requests.")
        } else {
            lines.append("Text:")
        }
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}

// MARK: - The plan

/// One request: a source, or one consecutive part of it.
struct MnemonicReadingPart: Equatable, Sendable {
    /// 1-based, of `count`.
    let index: Int
    let count: Int
    let text: String
    let questionCount: Int
    /// The turn as it will go.
    let user: String
    let maxTokens: Int
}

/// How one source will be written.
struct MnemonicReadingSourcePlan: Equatable, Sendable {
    let source: MnemonicReadingSource
    /// The questions asked of it, over its parts.
    let questionCount: Int
    let parts: [MnemonicReadingPart]
}

/// What a request will write and what it will cost, before anything is sent.
/// Pure: built from the sources as read and a route, so the sheet prices every
/// change of density without reading the library again.
struct MnemonicReadingPlan: Sendable {
    let request: MnemonicReadingRequest
    let title: String
    let sources: [MnemonicReadingSourcePlan]
    let skipped: [MnemonicReadingSkip]
    let existing: MnemonicReading?
    let route: NotebookWritingRoute
    let system: String
    let cost: NotebookWritingCost

    var density: MnemonicReadingDensity { request.density }
    var questionCount: Int { sources.reduce(0) { $0 + $1.questionCount } }
    var callCount: Int { sources.reduce(0) { $0 + $1.parts.count } }
    var splitTitles: [String] { sources.filter { $0.parts.count > 1 }.map(\.source.title) }
    var words: Int { sources.reduce(0) { $0 + $1.source.words } }

    /// "12 chapters · 84,210 words", "3 sources · 1 left out".
    var summary: String {
        let isBook = sources.count > 1 && sources.allSatisfy { $0.source.kindLabel == NotebookSourceKind.label(.book) }
        let noun = isBook ? (sources.count == 1 ? "chapter" : "chapters") : (sources.count == 1 ? "source" : "sources")
        var parts = ["\(sources.count) \(noun)", "\(words.formatted()) words"]
        if !skipped.isEmpty { parts.append("\(skipped.count) left out") }
        return parts.joined(separator: " · ")
    }

    /// "≈ 240 questions · $0.12": the questions the price buys, as the sheet
    /// and `generate_mnemonic_reading` say it.
    var priceLine: String {
        let questions = questionCount == 1 ? "1 question" : "\(questionCount) questions"
        return "\(questions) · \(cost.isFree ? "free" : cost.label)"
    }
}

/// The route the reading is written on: the learner's Mnemonic Reading
/// Writing setting, sized for the longest answer a request asks for.
enum MnemonicReadingRoute {
    /// Nil when no model is configured (signed out, no key or plan, a broken
    /// setting).
    static func current() -> NotebookWritingRoute? {
        KeychainService.resolveConfig(for: .mnemonicReadingWriting).map {
            NotebookWritingRoute.live(
                $0,
                writerMaxTokens: MnemonicReadingTurn.largestMaxTokens,
                condenserMaxTokens: MnemonicReadingTurn.largestMaxTokens
            )
        }
    }
}

enum MnemonicReadingPlanner {
    static let requestOverheadCharacters = AIService.perMessageOverheadChars
    /// Below this much room for its text a request is no reading of it.
    static let minimumPartCharacters = 4_000
    /// Parts are cut at a paragraph near their mark, so one may run a tenth
    /// past it; sizing them at 85% of the room keeps every part in the window.
    static let partShareOfRoom = 0.85

    /// Each source's questions — about one per `density.wordsPerQuestion`
    /// words, at least one a part — its parts when one request cannot take
    /// it whole, and the price.
    static func plan(
        _ materials: MnemonicReadingMaterials,
        density: MnemonicReadingDensity? = nil,
        route: NotebookWritingRoute,
        system: String = AITask.mnemonicReadingWriting.effectivePrompt ?? Prompts.mnemonicReadingWriter
    ) -> MnemonicReadingPlan {
        var request = materials.request
        if let density { request.density = density }
        var planned: [MnemonicReadingSourcePlan] = []
        var skipped = materials.skipped
        for source in materials.sources {
            let asked = request.density.questionCount(words: source.words)
            guard let pieces = parts(of: source, questionCount: asked, route: route, system: system) else {
                skipped.append(MnemonicReadingSkip(
                    sourceID: source.sourceID,
                    title: source.title,
                    reason: "\(route.modelLabel)'s context window leaves no room for its text."
                ))
                continue
            }
            let shares = shares(of: max(asked, pieces.count), lengths: pieces.map(\.count))
            let parts = pieces.enumerated().map { offset, text in
                let count = shares[offset]
                return MnemonicReadingPart(
                    index: offset + 1,
                    count: pieces.count,
                    text: text,
                    questionCount: count,
                    user: MnemonicReadingTurn.userMessage(
                        source: source,
                        questionCount: count,
                        part: pieces.count > 1 ? (offset + 1, pieces.count) : nil,
                        text: text
                    ),
                    maxTokens: MnemonicReadingTurn.maxTokens(questionCount: count)
                )
            }
            planned.append(MnemonicReadingSourcePlan(
                source: source,
                questionCount: parts.reduce(0) { $0 + $1.questionCount },
                parts: parts
            ))
        }
        return MnemonicReadingPlan(
            request: request,
            title: materials.title,
            sources: planned,
            skipped: skipped,
            existing: materials.existing,
            route: route,
            system: system,
            cost: cost(of: planned, system: system, route: route)
        )
    }

    /// A source's text as the requests that read it: whole when one request
    /// takes it, else in consecutive parts, each cut at a paragraph and each
    /// fitting the window. Nil when the window has no room for a part at all.
    /// A model that publishes no window is sent the whole text.
    static func parts(
        of source: MnemonicReadingSource,
        questionCount: Int,
        route: NotebookWritingRoute,
        system: String
    ) -> [String]? {
        guard let budget = route.writerInputBudget else { return [source.text] }
        func fits(_ text: String, part: (Int, Int)?) -> Bool {
            let user = MnemonicReadingTurn.userMessage(source: source, questionCount: questionCount, part: part, text: text)
            return system.count + user.count + requestOverheadCharacters <= budget
        }
        if fits(source.text, part: nil) { return [source.text] }
        let fixed = system.count + requestOverheadCharacters
            + MnemonicReadingTurn.userMessage(source: source, questionCount: questionCount, part: (999, 999), text: "").count
        let room = budget - fixed
        guard room >= minimumPartCharacters else { return nil }
        var count = max(2, Int((Double(source.text.count) / (Double(room) * partShareOfRoom)).rounded(.up)))
        // A cut moved to a paragraph can still leave one part too long for
        // the window; then the text is cut into one part more.
        let most = count * 2 + 8
        while count <= most {
            let pieces = split(source.text, into: count)
            if pieces.enumerated().allSatisfy({ fits($1, part: ($0 + 1, pieces.count)) }) { return pieces }
            count += 1
        }
        return nil
    }

    /// `text` in `count` consecutive pieces of about equal length, each cut
    /// at the paragraph end nearest its mark — a blank line, else a line
    /// break — within a quarter of a piece either side, or at the mark when
    /// there is neither. The pieces joined give back the text. A piece the
    /// nearest cut makes too long for the window is caught by `parts`, which
    /// then cuts into one piece more.
    static func split(_ text: String, into count: Int) -> [String] {
        let characters = Array(text)
        guard count > 1, characters.count > count else { return [text] }
        let total = characters.count
        let reach = max(1, total / count / 4)
        var boundaries: [Int] = []
        var previous = 0
        for index in 1..<count {
            let mark = index * total / count
            let low = max(previous + 1, mark - reach)
            let high = min(total - 1, mark + reach)
            func nearest(where isCut: (Int) -> Bool) -> Int? {
                guard low <= high else { return nil }
                return (low...high).filter(isCut).min { abs($0 - mark) < abs($1 - mark) }
            }
            let paragraph = nearest { position in
                position >= 2 && characters[position - 1] == "\n" && characters[position - 2] == "\n"
            }
            let line = nearest { position in position >= 1 && characters[position - 1] == "\n" }
            let cut = max(previous + 1, paragraph ?? line ?? mark)
            boundaries.append(cut)
            previous = cut
        }
        boundaries.append(total)
        var pieces: [String] = []
        var start = 0
        for end in boundaries where end > start {
            pieces.append(String(characters[start..<end]))
            start = end
        }
        return pieces
    }

    /// `total` shared among parts by their lengths, the largest remainders
    /// first, at least one each.
    static func shares(of total: Int, lengths: [Int]) -> [Int] {
        guard !lengths.isEmpty else { return [] }
        let weights = lengths.reduce(0, +) > 0 ? lengths.map { max(0, $0) } : lengths.map { _ in 1 }
        let sum = max(1, weights.reduce(0, +))
        var shares = weights.map { total * $0 / sum }
        var left = total - shares.reduce(0, +)
        let byRemainder = weights.indices.sorted {
            let lhs = total * weights[$0] % sum
            let rhs = total * weights[$1] % sum
            return lhs != rhs ? lhs > rhs : $0 < $1
        }
        for index in byRemainder where left > 0 {
            shares[index] += 1
            left -= 1
        }
        return shares.map { max(1, $0) }
    }

    /// The price of every request: the turn as it will go, the questions at
    /// their usual length (expected), and every request's output ceiling,
    /// reasoning room included (at most).
    static func cost(of sources: [MnemonicReadingSourcePlan], system: String, route: NotebookWritingRoute) -> NotebookWritingCost {
        let perToken = AIService.approxCharsPerToken
        var inputTokens = 0
        var expected = 0
        var maximum = 0
        var expectedUSD: Double? = 0
        var maximumUSD: Double? = 0
        var requests = 0
        for part in sources.flatMap(\.parts) {
            let input = (system.count + part.user.count + requestOverheadCharacters) / perToken
            let questionsExpected = part.questionCount * 110 + 100
            let ceiling = route.outputCeiling(requested: part.maxTokens)
            requests += 1
            inputTokens += input
            expected += questionsExpected
            maximum += ceiling
            expectedUSD = expectedUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: questionsExpected).map { total + $0 } }
            maximumUSD = maximumUSD.flatMap { total in route.usd(inputTokens: input, outputTokens: ceiling).map { total + $0 } }
        }
        return NotebookWritingCost(
            requestCount: requests,
            inputTokens: inputTokens,
            expectedOutputTokens: expected,
            maximumOutputTokens: maximum,
            expectedUSD: expectedUSD,
            maximumUSD: maximumUSD
        )
    }
}

// MARK: - The model's answer

/// One question as the writer wrote it: never an id or a link.
struct MnemonicReadingModelQuestion: Decodable, Equatable, Sendable {
    let quote: String?
    let question: String?
    let answer: String?
    let why: String?
    let difficulty: String?

    init(quote: String?, question: String?, answer: String?, why: String? = nil, difficulty: String? = nil) {
        self.quote = quote
        self.question = question
        self.answer = answer
        self.why = why
        self.difficulty = difficulty
    }
}

struct MnemonicReadingModelAnswer: Decodable, Sendable {
    let questions: [MnemonicReadingModelQuestion]
}

enum MnemonicReadingDrafts {
    /// A written question the reading does not take, and why.
    struct Refused: Equatable, Sendable {
        let question: String
        let reason: String
    }

    /// The model's questions as the reading's, each under the id its content
    /// mints, no more than a quarter past the count asked for. A question
    /// with no quote, question or answer, or one that writes a link, is
    /// refused and said; quotes are checked against the source's text when
    /// the questions are saved (`saveMnemonicReadingSection`).
    static func questions(
        _ written: [MnemonicReadingModelQuestion],
        sourceID: String,
        asked: Int
    ) -> (questions: [MnemonicQuestion], refused: [Refused]) {
        let limit = asked + asked / 4 + 1
        var questions: [MnemonicQuestion] = []
        var refused: [Refused] = []
        for item in written {
            let text = MnemonicReading.singleLine(item.question ?? "")
            let answer = (item.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = MnemonicReading.singleLine(item.quote ?? "")
            guard !text.isEmpty, !answer.isEmpty, !quote.isEmpty else {
                refused.append(Refused(question: text, reason: "It had no question, no answer or no quote."))
                continue
            }
            let why = item.why.map(MnemonicReading.singleLine).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
            guard ![text, answer, why ?? ""].contains(where: writesALink) else {
                refused.append(Refused(question: text, reason: "It wrote a link, which ForeverLM writes itself."))
                continue
            }
            guard questions.count < limit else {
                refused.append(Refused(question: text, reason: "More questions than were asked for."))
                continue
            }
            questions.append(MnemonicQuestion.mint(
                sourceID: sourceID,
                quote: quote,
                question: text,
                answer: answer,
                why: why,
                difficulty: item.difficulty.flatMap { MemoryCardDifficulty(rawValue: $0.lowercased()) }
            ))
        }
        return (questions, refused)
    }

    private static func writesALink(_ text: String) -> Bool {
        text.contains("://") || text.contains("](")
    }
}

// MARK: - What a run reports

/// How far a run has come, for the pending row and `list_running_ai_work`.
struct MnemonicReadingRunProgress: Equatable, Sendable {
    let done: Int
    let total: Int

    /// "Writing questions (2 of 12 sources)"
    var label: String {
        total <= 1 ? "Writing questions" : "Writing questions (\(min(done + 1, total)) of \(total) sources)"
    }
}

/// What one source's run did.
struct MnemonicReadingSourceOutcome: Equatable, Sendable {
    let sourceID: String
    let title: String
    /// The questions added to the reading.
    var added: [MnemonicQuestion] = []
    /// Questions the reading already held.
    var alreadyWritten = 0
    /// Questions whose quote the source's text does not print: dropped.
    var ungrounded: [MnemonicQuestion] = []
    /// Questions refused for what they were.
    var refused: [MnemonicReadingDrafts.Refused] = []
    /// How many requests read it.
    var partCount = 1
    /// Why nothing was saved for it, when nothing was: it stays pending.
    var failure: String?
}

/// What one run did, source by source.
struct MnemonicReadingResult: Equatable, Sendable {
    let readingID: String
    let title: String
    var sources: [MnemonicReadingSourceOutcome] = []
    var skipped: [MnemonicReadingSkip] = []
    /// Whether the reading exists now: made by this run, or by an earlier one.
    var readingExists = false

    var addedCount: Int { sources.reduce(0) { $0 + $1.added.count } }
    var ungroundedCount: Int { sources.reduce(0) { $0 + $1.ungrounded.count } }
    var failures: [MnemonicReadingSourceOutcome] { sources.filter { $0.failure != nil } }

    /// "48 questions · 2 not found in their text · 1 source failed": what
    /// the toast says when a run ends.
    var summary: String {
        var parts = [addedCount == 1 ? "1 question" : "\(addedCount) questions"]
        let ungrounded = ungroundedCount
        if ungrounded > 0 {
            parts.append(ungrounded == 1 ? "1 not found in its text" : "\(ungrounded) not found in their text")
        }
        if !failures.isEmpty {
            parts.append(failures.count == 1 ? "1 source failed" : "\(failures.count) sources failed")
        }
        return parts.joined(separator: " · ")
    }
}

enum MnemonicReadingError: LocalizedError, Equatable {
    /// Signed out, no key or plan, or a broken route for the task.
    case noModelConfigured(String)
    /// None of the sources asked for has text to write questions about.
    case noSources
    /// The request would not fit the window as sent, so the central trim
    /// would cut the source; refused instead.
    case wouldBeCut(model: String, title: String)
    /// The reading being written into is gone.
    case readingGone(String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured(let message):
            return message
        case .noSources:
            return "None of these sources has text to write questions about yet."
        case .wouldBeCut(let model, let title):
            return "\u{201C}\(title)\u{201D} does not fit \(model)'s context window, and nothing is cut. Choose a model with a larger window for Mnemonic Reading Writing."
        case .readingGone(let id):
            return "The reading \(id) is no longer in the library."
        }
    }

    /// Why no Mnemonic Reading Writing model is configured, in the words
    /// that lead to the fix.
    static var noModel: MnemonicReadingError {
        .noModelConfigured(
            KeychainService.backgroundAIUnavailableMessage(for: .mnemonicReadingWriting)
                ?? "No model is configured for Mnemonic Reading Writing. Sign in and check Settings › AI Models."
        )
    }
}

// MARK: - The model, behind a protocol

/// The writing model, behind a protocol so the run is pinned in tests with
/// canned questions.
protocol MnemonicReadingBackend: Sendable {
    /// One request's questions, from the turn the plan built, on its route.
    func writeQuestions(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        route: NotebookWritingRoute
    ) async throws -> [MnemonicReadingModelQuestion]
}

/// Writes on the learner's Mnemonic Reading Writing route, as the plan
/// resolved it.
struct LiveMnemonicReadingBackend: MnemonicReadingBackend {
    let aiService: AIService

    func writeQuestions(
        system: String,
        user: String,
        maxTokens: Int,
        source: AIUsageSource,
        route: NotebookWritingRoute
    ) async throws -> [MnemonicReadingModelQuestion] {
        guard let config = route.config else { throw MnemonicReadingError.noModel }
        return try await aiService.writeMnemonicReadingQuestions(
            system: system,
            user: user,
            maxTokens: maxTokens,
            source: source,
            config: config
        )
    }
}

// MARK: - Reading, planning and running

enum MnemonicReadingWriter {
    /// How many sources are written at once.
    static let concurrency = 3
    private static let logger = Logger(subsystem: "com.foreverlm", category: "MnemonicReading")

    /// Reads every source the request names, in its order, with the reading
    /// it writes into when it names one. A source left out says why: not in
    /// the library, kept from AI or archived, a spoken script ForeverLM
    /// wrote, no text yet. Writes nothing.
    static func load(_ request: MnemonicReadingRequest, storage: StorageService) async throws -> MnemonicReadingMaterials {
        let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var existing: MnemonicReading?
        var existingTitle: String?
        if let readingID = request.readingID {
            let snapshot = try await storage.artifactMarkdown(readingID)
            guard snapshot.artifact.isMnemonicReading(markdown: snapshot.markdown) else {
                throw MnemonicReadingError.readingGone(readingID)
            }
            existing = MnemonicReading.parse(snapshot.markdown, fallbackTitle: snapshot.artifact.title)
            existingTitle = snapshot.artifact.title
        }
        var sources: [MnemonicReadingSource] = []
        var skipped: [MnemonicReadingSkip] = []
        var articles: [StudioArticle] = []
        var bookTitles: [String: String] = [:]
        var seen = Set<String>()
        for id in request.sourceIDs where seen.insert(id).inserted {
            try Task.checkCancellation()
            guard let article = try await storage.loadSourceWithoutContent(id) else {
                skipped.append(MnemonicReadingSkip(sourceID: id, title: id, reason: "It is not in the library any more."))
                continue
            }
            if excluded.contains(id) {
                // Its title never names the reading, which an assistant reads.
                skipped.append(MnemonicReadingSkip(sourceID: id, title: article.title, reason: "It is kept from AI or archived.", isKeptFromAI: true))
                continue
            }
            articles.append(article)
            if TextToSpeechPreparationPolicy.isSpokenScript(url: article.url) {
                skipped.append(MnemonicReadingSkip(sourceID: id, title: article.title, reason: "It is a spoken script ForeverLM wrote."))
                continue
            }
            let text = (await storage.loadSourceContent(id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                let reason = article.isPaywalled ? "It is paywalled and has no text yet." : "It has no text yet."
                skipped.append(MnemonicReadingSkip(sourceID: id, title: article.title, reason: reason))
                continue
            }
            var bookTitle: String?
            if article.sourceType == .book, let group = article.parentGroup, !group.isEmpty {
                if bookTitles[group] == nil, let title = await storage.bookTitle(forGroupID: group) {
                    bookTitles[group] = title
                }
                bookTitle = bookTitles[group]
            }
            sources.append(MnemonicReadingSource(
                sourceID: id,
                title: article.title,
                sourceType: article.sourceType.rawValue,
                kindLabel: NotebookSourceKind.label(article.sourceType),
                bookTitle: bookTitle,
                text: text
            ))
        }
        var notebookTitle: String?
        if let notebookID = request.notebookID {
            notebookTitle = try await storage.loadLearningGoal(notebookID)?.title
        }
        return MnemonicReadingMaterials(
            request: request,
            title: existingTitle ?? title(for: articles, bookTitles: bookTitles, notebookTitle: notebookTitle),
            sources: sources,
            skipped: skipped,
            existing: existing
        )
    }

    /// The reading's title: the book's for a book's chapters, the source's
    /// for one source, else the notebook's it is made in, each "… with
    /// questions".
    static func title(for articles: [StudioArticle], bookTitles: [String: String], notebookTitle: String?) -> String {
        let groups = Set(articles.map { $0.sourceType == .book ? ($0.parentGroup ?? "") : "" })
        if articles.count > 1, groups.count == 1, let group = groups.first, !group.isEmpty, let book = bookTitles[group] {
            return MnemonicReading.title(forSubject: book)
        }
        if articles.count == 1, let only = articles.first {
            return MnemonicReading.title(forSubject: only.title)
        }
        if let notebookTitle, !notebookTitle.isEmpty {
            return MnemonicReading.title(forSubject: notebookTitle)
        }
        return MnemonicReading.title(forSubject: articles.first?.title ?? "")
    }

    /// The plan for what was read, on the learner's route as it stands now.
    static func plan(_ materials: MnemonicReadingMaterials, density: MnemonicReadingDensity? = nil) throws -> MnemonicReadingPlan {
        guard let route = MnemonicReadingRoute.current() else { throw MnemonicReadingError.noModel }
        return MnemonicReadingPlanner.plan(materials, density: density, route: route)
    }

    /// Writes every source of `plan`, a few at a time, and saves each
    /// source's questions into the reading `readingID` as soon as all its
    /// parts are written — making the reading, every source pending but this
    /// one, at the first save — so a run stopped part way keeps what it
    /// finished. A source whose request fails is reported and stays pending.
    /// Throws only for cancellation, after the sources finished before it
    /// are saved.
    static func run(
        _ plan: MnemonicReadingPlan,
        readingID: String,
        storage: StorageService,
        backend: any MnemonicReadingBackend,
        wording: (any CardWordingBackend)? = nil,
        onProgress: @escaping @Sendable (MnemonicReadingRunProgress) async -> Void = { _ in }
    ) async throws -> MnemonicReadingResult {
        var result = MnemonicReadingResult(readingID: readingID, title: plan.title, skipped: plan.skipped)
        let wording = wording ?? CardWordingGate.backend()
        result.readingExists = plan.existing != nil
        guard !plan.sources.isEmpty else { return result }
        let skeleton = MnemonicReadingSkeleton(
            title: plan.title,
            notebookID: plan.request.notebookID,
            sections: plan.existing == nil
                ? plan.sources.map { ($0.source.sourceID, $0.source.title) }
                : []
        )
        let workflowID = UUID().uuidString
        let sources = plan.sources
        let total = sources.count
        let system = plan.system
        let route = plan.route
        let width = min(Self.concurrency, total)
        var outcomes: [Int: MnemonicReadingSourceOutcome] = [:]
        var readingExists = plan.existing != nil
        try await AIUsageAttribution.$activityID.withValue(workflowID) {
            try await withThrowingTaskGroup(of: (Int, WrittenSource).self) { group in
                var next = 0
                while next < width {
                    let index = next
                    let sourcePlan = sources[index]
                    group.addTask {
                        // Bound before the tuple is built: a tuple around a
                        // `try await` in a task closure miscompiles at -O
                        // (AGENTS.md).
                        let written = try await Self.write(sourcePlan, system: system, route: route, backend: backend, wording: wording)
                        return (index, written)
                    }
                    next += 1
                }
                while let (index, written) = try await group.next() {
                    let sourcePlan = sources[index]
                    var outcome = MnemonicReadingSourceOutcome(sourceID: sourcePlan.source.sourceID, title: sourcePlan.source.title)
                    outcome.partCount = sourcePlan.parts.count
                    outcome.refused = written.refused
                    outcome.failure = written.failure
                    if written.failure == nil {
                        do {
                            let saved = try await storage.saveMnemonicReadingSection(
                                readingID: readingID,
                                sourceID: sourcePlan.source.sourceID,
                                sourceTitle: sourcePlan.source.title,
                                questions: written.questions,
                                creatingWith: readingExists ? nil : skeleton
                            )
                            readingExists = true
                            outcome.added = saved.added
                            outcome.alreadyWritten = saved.alreadyWritten
                            outcome.ungrounded = saved.ungrounded
                            outcome.refused += saved.unreadable.map {
                                MnemonicReadingDrafts.Refused(question: $0.question, reason: "Its answer has a line that reads as a heading or as the question's own metadata.")
                            }
                        } catch {
                            outcome.failure = error.localizedDescription
                        }
                    }
                    outcomes[index] = outcome
                    await onProgress(MnemonicReadingRunProgress(done: outcomes.count, total: total))
                    try Task.checkCancellation()
                    if next < total {
                        let index = next
                        let sourcePlan = sources[index]
                        group.addTask {
                            let written = try await Self.write(sourcePlan, system: system, route: route, backend: backend, wording: wording)
                            return (index, written)
                        }
                        next += 1
                    }
                }
            }
        }
        result.sources = sources.indices.compactMap { outcomes[$0] }
        result.readingExists = readingExists
        logger.notice("Wrote \(result.addedCount) mnemonic question(s) from \(result.sources.count) source(s), \(result.ungroundedCount) not grounded, \(result.failures.count) failed")
        return result
    }

    /// One source's questions, part by part, then through the wording gate
    /// (`CardWordingGate`): every answered question becomes a card, so one
    /// that points at its source unnamed is reworded once or dropped. A
    /// request that fails, the gate's included, fails the source — nothing of
    /// it is saved, so it stays pending whole — and a cancelled one throws.
    private struct WrittenSource: Sendable {
        var questions: [MnemonicQuestion] = []
        var refused: [MnemonicReadingDrafts.Refused] = []
        var failure: String?
    }

    private static func write(
        _ plan: MnemonicReadingSourcePlan,
        system: String,
        route: NotebookWritingRoute,
        backend: any MnemonicReadingBackend,
        wording: any CardWordingBackend
    ) async throws -> WrittenSource {
        var written = WrittenSource()
        for part in plan.parts {
            do {
                let questions = try await backend.writeQuestions(
                    system: system,
                    user: part.user,
                    maxTokens: part.maxTokens,
                    source: AIUsageSource(id: plan.source.sourceID, type: plan.source.sourceType, title: plan.source.title),
                    route: route
                )
                // A provider that answered after a stop must not land
                // questions the learner gave up on.
                try Task.checkCancellation()
                let drafts = MnemonicReadingDrafts.questions(questions, sourceID: plan.source.sourceID, asked: part.questionCount)
                written.questions += drafts.questions
                written.refused += drafts.refused
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                written.failure = error.localizedDescription
                return written
            }
        }
        do {
            let screened = try await CardWordingGate.screen(
                questions: written.questions,
                sourceTitle: plan.source.title,
                usage: AIUsageSource(id: plan.source.sourceID, type: plan.source.sourceType, title: plan.source.title),
                backend: wording
            )
            written.questions = screened.passed
            written.refused += screened.refused
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            written.questions = []
            written.failure = "The questions' wording could not be checked, so none was saved. \(error.localizedDescription)"
        }
        return written
    }
}

/// What a reading is made with at its first save: its title, its notebook,
/// and every source's section in reading order, pending until written.
struct MnemonicReadingSkeleton: Sendable {
    let title: String
    let notebookID: String?
    let sections: [(sourceID: String, title: String)]
}
