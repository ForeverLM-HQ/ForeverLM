import Foundation

// MARK: - Reading a notebook's sources for a writer
//
// What a notebook's writers share — the audio overview
// (docs/explainer-design.md, "Audio overviews") and the report
// (docs/notebooks-design.md, "Reports"): the ticked-sources seam, every
// selected source loaded whole with its stored ideas when those speak for the
// whole text, the fit to the writing model's window — a source that does not
// fit is read from its ideas or from a condensed account of its whole text,
// condensed in consecutive window-sized parts, and nothing is ever cut — and
// the price of the writing. Each writer keeps its own prompt, its own turn and
// its own condensing words; what is here is the reading, which must not differ
// between them.

/// How the writer read one source. A source the model's window cannot take
/// whole is read from the ideas stored for it, or from a condensed account
/// of its whole text — and the prompt, the price sheet and the result say so.
/// Nothing is ever cut. The raw values are stored in recipes and answered by
/// MCP (`read_as`).
enum NotebookSourceReadAs: String, Codable, Sendable, CaseIterable {
    case whole
    case ideas
    case condensed

    var label: String {
        switch self {
        case .whole: return "whole"
        case .ideas: return "from its ideas"
        case .condensed: return "condensed"
        }
    }
}

/// What a source is, in the words a writer is handed and a reader would use.
enum NotebookSourceKind {
    static func label(_ type: StudioSourceType) -> String {
        switch type {
        case .paper: return "research paper"
        case .article, .manual, .unclassified: return "article"
        case .book: return "book chapter"
        case .course: return "course document"
        case .podcast: return "podcast transcript"
        case .meeting: return "meeting transcript"
        case .video: return "video transcript"
        case .xPost: return "post on X"
        }
    }
}

/// The notebook as a writer will read it, loaded once per options sheet:
/// every selected source with text, its stored ideas when they were taken
/// from that same text, and the sources set aside with the reason.
struct NotebookSourceSet: Sendable {
    struct Candidate: Sendable, Equatable {
        /// The source's row, without its text.
        let source: StudioArticle
        /// Its stored text, whole.
        let text: String
        /// Its stored ideas written out for the writer, when they were
        /// extracted from exactly this text; nil when it has none.
        let ideas: String?
    }

    struct Skipped: Sendable, Equatable {
        let sourceID: String
        let title: String
        let reason: String
    }

    let notebookID: String
    let title: String
    let instructions: String?
    let candidates: [Candidate]
    let skipped: [Skipped]

    /// How many sources the selection named, set-aside ones included.
    var selectedCount: Int { candidates.count + skipped.count }
}

/// Why a notebook could not be read; each writer says it in its own words.
enum NotebookSourceLoadError: Error, Equatable {
    case notebookNotFound(String)
    case sourceNotInNotebook([String])
}

enum NotebookSourceLoader {

    // MARK: The ticked-sources seam

    /// The sources a writer reads when the caller names none — the one seam
    /// every path reads (the Studio sheets, their coordinators and the MCP
    /// tools): the notebook's ticked sources — its own, in study order, minus
    /// the boxes the learner unticked (`NotebookChatSelection`). A context
    /// notebook's sources reach the notebook's chats once the learner puts it
    /// in (`NotebookChatContext`), never what its Studio makes: a thing made
    /// in a notebook is made from the sources it holds itself.
    static func notebookSourceIDs(notebookID: String, storage: StorageService) async throws -> [String] {
        let pool = try await ownSourceIDs(notebookID: notebookID, storage: storage)
        return tickedSourceIDs(pool: pool, notebookID: notebookID)
    }

    /// The notebook's own sources, in study order — its Sources column's own
    /// rows, without its context notebooks' — or none for a missing notebook.
    static func ownSourceIDs(notebookID: String, storage: StorageService) async throws -> [String] {
        guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else { return [] }
        return notebook.approvedSourceIDs
    }

    static func tickedSourceIDs(pool: [String], notebookID: String) -> [String] {
        NotebookChatSelection.chatSourceIDs(pool: pool, excluded: NotebookChatSelection.excluded(notebookID: notebookID))
    }

    // MARK: Load

    /// Reads the notebook and every selected source's text and ideas. Sources
    /// with no text, spoken scripts, and sources kept from AI are set aside
    /// with the reason. `sourceIDs` must all be the notebook's own; a caller
    /// may name any source the notebook holds, ticked or not.
    static func load(
        notebookID rawNotebookID: String,
        sourceIDs: [String]? = nil,
        storage: StorageService
    ) async throws -> NotebookSourceSet {
        let notebookID = rawNotebookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let notebook = try await storage.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw NotebookSourceLoadError.notebookNotFound(notebookID)
        }
        let pool = notebook.approvedSourceIDs
        let selected: [String]
        if let sourceIDs {
            let wanted = orderedUnique(sourceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            let poolSet = Set(pool)
            let outside = wanted.filter { !poolSet.contains($0) }
            guard outside.isEmpty else { throw NotebookSourceLoadError.sourceNotInNotebook(outside) }
            selected = wanted
        } else {
            selected = tickedSourceIDs(pool: pool, notebookID: notebookID)
        }

        let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var candidates: [NotebookSourceSet.Candidate] = []
        var skipped: [NotebookSourceSet.Skipped] = []
        let ideasBySource = try await storage.loadSourceIdeas(sourceIDs: selected)
        for id in selected {
            try Task.checkCancellation()
            guard let source = try await storage.loadSourceWithoutContent(id) else {
                skipped.append(.init(sourceID: id, title: id, reason: "It is not in the library any more."))
                continue
            }
            if TextToSpeechPreparationPolicy.isSpokenScript(url: source.url) {
                skipped.append(.init(sourceID: id, title: source.title, reason: "It is a spoken script ForeverLM wrote."))
                continue
            }
            if excluded.contains(id) {
                skipped.append(.init(sourceID: id, title: source.title, reason: "It is kept from AI or archived."))
                continue
            }
            // The text as stored is what idea extraction hashed; only the
            // copy the writer reads is trimmed.
            let stored = await storage.loadSourceContent(id)
            guard let stored,
                  case let text = stored.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                let reason = source.isPaywalled ? "It is paywalled and has no text yet." : "It has no text yet."
                skipped.append(.init(sourceID: id, title: source.title, reason: reason))
                continue
            }
            candidates.append(.init(
                source: source,
                text: text,
                ideas: try await currentIdeas(ideasBySource[id], sourceID: id, storedText: stored, storage: storage)
            ))
        }
        let instructions = notebook.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotebookSourceSet(
            notebookID: notebookID,
            title: notebook.title,
            instructions: instructions?.isEmpty == false ? instructions : nil,
            candidates: candidates,
            skipped: skipped
        )
    }

    /// A source's stored ideas, written out for the writer, when they speak
    /// for its whole text: taken from exactly the text stored now (the hash
    /// extraction stamps is of the text as stored, untrimmed), and from all
    /// of it. Extraction reads only the first
    /// `SourceIdeaDrafting.singleReadCharacterLimit` of a longer text while
    /// hashing the whole, so a longer source's ideas may leave its tail out
    /// and are not used; it is condensed whole instead. Nil when none qualify.
    static func currentIdeas(
        _ ideas: [SourceIdea]?,
        sourceID: String,
        storedText: String,
        storage: StorageService
    ) async throws -> String? {
        guard let ideas, !ideas.isEmpty,
              storedText.count <= SourceIdeaDrafting.singleReadCharacterLimit,
              try await storage.sourceIdeaContentHash(sourceID: sourceID) == SourceIdeaDrafting.contentHash(storedText)
        else { return nil }
        return ideasText(ideas)
    }

    /// A source's ideas as the writer reads them: each statement, and what a
    /// good recall of it holds.
    static func ideasText(_ ideas: [SourceIdea]) -> String {
        ideas.sorted { $0.sortIndex < $1.sortIndex }.map { idea in
            let note = idea.recallNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? "- \(idea.statement)" : "- \(idea.statement)\n  A good recall holds: \(note)"
        }.joined(separator: "\n")
    }

    static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Fitting the window

/// Which sources the writer reads whole, from their ideas, or condensed, so
/// the request fits the window. Largest first: the source that frees the
/// most room is changed first, and the rest stay whole for as long as they
/// can. A condensed source is given whatever room is left, shared by length.
enum NotebookSourceBudget {
    struct Length: Equatable, Sendable {
        let id: String
        let whole: Int
        /// The source's ideas written out, when it has current ones.
        let ideas: Int?
    }

    struct Choice: Equatable, Sendable {
        let readAs: NotebookSourceReadAs
        /// For a condensed source: the characters its account may run to.
        let targetCharacters: Int?
    }

    /// Even every source read from its ideas or condensed to the least worth
    /// reading does not fit the window; each writer says so in its words.
    struct DoesNotFit: Error, Equatable {
        let model: String
        let sourceCount: Int
    }

    /// The least a condensed account is asked for: below this a source is
    /// hardly read at all.
    static let minimumCondensedCharacters = 2_400
    /// Condensed accounts are asked for less than the room left, since a
    /// model runs a little past a target length.
    static let condensedShareOfRoom = 0.8

    static func choose(
        sources: [Length],
        fixedCharacters: Int,
        budget: Int?,
        model: String
    ) throws -> [String: Choice] {
        var choices = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, Choice(readAs: .whole, targetCharacters: nil)) })
        guard let budget else { return choices }

        func size(_ length: Length) -> Int {
            switch choices[length.id]?.readAs ?? .whole {
            case .whole: return length.whole
            case .ideas: return length.ideas ?? length.whole
            case .condensed: return minimumCondensedCharacters
            }
        }
        func total() -> Int { fixedCharacters + sources.reduce(0) { $0 + size($1) } }

        guard total() > budget else { return choices }
        for length in sources.sorted(by: { ($0.whole, $1.id) > ($1.whole, $0.id) }) {
            guard total() > budget else { break }
            if let ideas = length.ideas, ideas < length.whole {
                choices[length.id] = Choice(readAs: .ideas, targetCharacters: nil)
            } else if length.whole > minimumCondensedCharacters {
                choices[length.id] = Choice(readAs: .condensed, targetCharacters: minimumCondensedCharacters)
            }
        }
        // Ideas did not make room: condense, largest first, what still reads
        // from its ideas.
        if total() > budget {
            for length in sources.sorted(by: { ($0.whole, $1.id) > ($1.whole, $0.id) })
            where choices[length.id]?.readAs == .ideas && (length.ideas ?? 0) > minimumCondensedCharacters {
                guard total() > budget else { break }
                choices[length.id] = Choice(readAs: .condensed, targetCharacters: minimumCondensedCharacters)
            }
        }
        guard total() <= budget else {
            throw DoesNotFit(model: model, sourceCount: sources.count)
        }

        // Share the room left among the condensed sources, by length.
        let condensed = sources.filter { choices[$0.id]?.readAs == .condensed }
        guard !condensed.isEmpty else { return choices }
        let settled = sources.reduce(0) { total, length in
            choices[length.id]?.readAs == .condensed ? total : total + size(length)
        }
        let room = Int(Double(budget - fixedCharacters - settled) * condensedShareOfRoom)
        let shares = TextbookReadingPlanning.lectureBudgets(
            lengths: Dictionary(uniqueKeysWithValues: condensed.map { ($0.id, $0.whole) }),
            total: max(room, minimumCondensedCharacters * condensed.count),
            minimum: minimumCondensedCharacters
        )
        for length in condensed {
            let target = shares[length.id] ?? minimumCondensedCharacters
            choices[length.id] = Choice(readAs: .condensed, targetCharacters: min(target, length.whole))
        }
        return choices
    }
}

// MARK: - The route and the price

/// The route a writing runs on, as its planner needs it: the window each
/// request must fit, the reasoning-aware output ceiling and the list price.
/// Read once per plan, from the routed configuration the call will use, and
/// carried to the calls themselves (`config`), so a change of the setting
/// between the quote and Make cannot send a turn sized for one model to
/// another.
struct NotebookWritingRoute: Sendable {
    let provider: AIProvider
    let model: String
    /// Characters the writer's request may carry; nil when no window is
    /// published for the model, and the request is sent as built.
    let writerInputBudget: Int?
    /// Characters one condensing request may carry; nil likewise.
    let condenserInputBudget: Int?
    /// USD per 1M tokens at list price; nil when the model is unpriced, which
    /// reads as "price unknown", never as free.
    let inputUSDPerMillion: Double?
    let outputUSDPerMillion: Double?
    /// Gemini Pro's long-prompt tier: past this many input tokens a request
    /// bills at the long-context rates.
    var longContextThreshold: Int? = nil
    var longContextInputUSDPerMillion: Double? = nil
    var longContextOutputUSDPerMillion: Double? = nil
    /// The configuration the plan was sized and priced for, which the live
    /// backend sends every call with; nil for a route a test builds, whose
    /// backend sends nothing.
    var config: AITaskConfig? = nil

    /// The model's name as the sheet and the answer show it.
    var modelLabel: String { model }

    /// The route a task's setting resolves to, after the account's text
    /// routing, as `AIService.call` will send it, sized for a writer asking
    /// for `writerMaxTokens` and a condensing call asking for
    /// `condenserMaxTokens`. Each writer passes its own; nothing is assumed.
    static func live(_ config: AITaskConfig, writerMaxTokens: Int, condenserMaxTokens: Int) -> NotebookWritingRoute {
        let routed = KeychainService.routedTextConfig(config)
        let rates = AIProviderPricing.textTokenRates(provider: routed.provider, model: routed.model)
        return NotebookWritingRoute(
            provider: routed.provider,
            model: routed.model,
            writerInputBudget: AIService.inputCharacterBudget(
                provider: routed.provider,
                model: routed.model,
                requestedMaxTokens: writerMaxTokens
            ),
            condenserInputBudget: AIService.inputCharacterBudget(
                provider: routed.provider,
                model: routed.model,
                requestedMaxTokens: condenserMaxTokens
            ),
            inputUSDPerMillion: rates?.input,
            outputUSDPerMillion: rates?.output,
            longContextThreshold: rates?.longContextThreshold,
            longContextInputUSDPerMillion: rates?.longContextInput,
            longContextOutputUSDPerMillion: rates?.longContextOutput,
            config: config
        )
    }

    /// The output tokens a request asking for `requested` may actually run
    /// to, once a reasoning model's thinking room is added
    /// (`AIService.effectiveReasoningAwareMaxTokens`).
    func outputCeiling(requested: Int) -> Int {
        let capped = AIService.cappedResponseTokens(provider: provider, model: model, requestedMaxTokens: requested)
        return AIService.effectiveReasoningAwareMaxTokens(capped, provider: provider, model: model)
    }

    /// USD for one request, or nil when the model is unpriced.
    func usd(inputTokens: Int, outputTokens: Int) -> Double? {
        guard var input = inputUSDPerMillion, var output = outputUSDPerMillion else { return nil }
        if let threshold = longContextThreshold, inputTokens > threshold {
            input = longContextInputUSDPerMillion ?? input
            output = longContextOutputUSDPerMillion ?? output
        }
        return Double(inputTokens) / 1_000_000 * input + Double(outputTokens) / 1_000_000 * output
    }
}

/// What a writing — the text and any condensing — will cost, before anything
/// is sent: the expected figure (the text at its target length) and the most
/// it can come to (every request's output ceiling, reasoning room included).
struct NotebookWritingCost: Sendable, Equatable {
    let requestCount: Int
    let inputTokens: Int
    let expectedOutputTokens: Int
    let maximumOutputTokens: Int
    let expectedUSD: Double?
    let maximumUSD: Double?

    /// "about $0.14, at most $0.62", "free", or "price unknown".
    var label: String {
        guard let expectedUSD, let maximumUSD else { return "price unknown" }
        if maximumUSD == 0 { return "free" }
        return "about \(Self.dollars(expectedUSD)), at most \(Self.dollars(maximumUSD))"
    }

    /// Whether the writing costs nothing at all: a free route, priced as free.
    /// An unpriced route is never free.
    var isFree: Bool { maximumUSD == 0 }

    static func dollars(_ usd: Double) -> String {
        if usd == 0 { return "free" }
        if usd < 0.005 { return "less than $0.01" }
        return String(format: "$%.2f", usd)
    }
}

// MARK: - Condensing

/// The condensing pass's arithmetic, shared by every writer: how many words
/// one call is asked for, how a source's whole text is cut into consecutive
/// window-sized parts — never a sample, every character in exactly one part —
/// and how the parts are condensed a few at a time.
enum NotebookSourceCondensing {
    /// The most words one condensing call is asked for. A source that needs
    /// more room is condensed in more parts.
    static let maximumTargetWords = 4_000
    /// The response budget of the longest call, for sizing the condenser's
    /// window before the parts are known.
    static let largestMaxTokens = maxTokens(forTargetWords: maximumTargetWords)
    /// The characters a condensing part's header takes beside its text: the
    /// source's title, its kind, the part line and the target, with room for
    /// a long title.
    static let partHeaderCharacters = 600
    /// The structural characters a provider adds around one turn, the same
    /// allowance `AIService.budgetedChatRequest` counts.
    static let requestOverheadCharacters = 16

    static func maxTokens(forTargetWords words: Int) -> Int {
        Int(Double(words) * 1.6) + 600
    }

    /// The window has no room for even one condensing request's
    /// instructions; there is nothing to size a part against.
    struct WindowTooSmall: Error, Equatable {}

    /// One consecutive part of a source's text and the words it is asked for.
    struct Slice: Equatable, Sendable {
        /// 1-based, of `count`.
        let index: Int
        let count: Int
        let text: String
        let targetWords: Int
    }

    /// A source's condensing calls: its whole text in consecutive parts, each
    /// small enough for one condensing request whose system prompt runs to
    /// `promptCharacters`, each asked for its share of the target. Throws
    /// when the window has no room for a part at all. No window published:
    /// the part is the whole text, sent as built.
    static func slices(
        of text: String,
        targetCharacters: Int,
        condenserInputBudget: Int?,
        promptCharacters: Int
    ) throws -> [Slice] {
        let charactersPerWord = Int(ArticleSpeechCostEstimate.fallbackCharactersPerWord)
        let targetWords = max(1, targetCharacters / charactersPerWord)
        // Room for one part: the condenser's window less its prompt and header,
        // and few enough words asked per call that one answer can hold them.
        let partRoom: Int
        if let budget = condenserInputBudget {
            partRoom = budget - promptCharacters - partHeaderCharacters - requestOverheadCharacters
            guard partRoom > 0 else { throw WindowTooSmall() }
        } else {
            partRoom = max(1, text.count)
        }
        // Parts are cut at a line break near their mark, so one may run a
        // tenth past it; sizing them at 85% of the room keeps every part
        // inside the window the condensing request is checked against.
        let byWindow = Int((Double(text.count) / (Double(partRoom) * 0.85)).rounded(.up))
        let byAnswer = Int((Double(targetWords) / Double(maximumTargetWords)).rounded(.up))
        let count = max(1, byWindow, byAnswer)
        let pieces = splitConsecutively(text, into: count)
        return pieces.enumerated().map { index, piece in
            let share = Double(piece.count) / Double(max(1, text.count))
            return Slice(
                index: index + 1,
                count: pieces.count,
                text: piece,
                targetWords: max(60, min(maximumTargetWords, Int(Double(targetWords) * share)))
            )
        }
    }

    /// `text` in exactly `count` consecutive pieces of about equal length,
    /// each cut at a line break within a tenth of a piece before its mark
    /// where there is one. The pieces joined give back the text.
    static func splitConsecutively(_ text: String, into count: Int) -> [String] {
        let characters = Array(text)
        guard count > 1, characters.count > count else { return [text] }
        let total = characters.count
        let size = total / count
        var boundaries: [Int] = []
        var previous = 0
        for index in 1..<count {
            let mark = index * total / count
            let floor = max(previous + 1, mark - size / 10)
            var cut = mark
            while cut > floor, characters[cut - 1] != "\n" { cut -= 1 }
            if characters[cut - 1] != "\n" { cut = mark }
            boundaries.append(cut)
            previous = cut
        }
        boundaries.append(total)
        var pieces: [String] = []
        var start = 0
        for end in boundaries {
            pieces.append(String(characters[start..<end]))
            start = end
        }
        return pieces
    }

    /// Condenses every part, `concurrency` at a time, and answers the
    /// accounts in the parts' own order. `onProgress` hears how many are done
    /// after each one lands. Stops at the first failure or cancellation.
    static func condenseAll<Part: Sendable>(
        _ parts: [Part],
        concurrency: Int,
        condense: @escaping @Sendable (Part) async throws -> String,
        onProgress: @escaping @Sendable (_ done: Int) async -> Void
    ) async throws -> [String] {
        guard !parts.isEmpty else { return [] }
        var results: [Int: String] = [:]
        let width = min(max(1, concurrency), parts.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            while next < width {
                let index = next
                let part = parts[index]
                group.addTask {
                    // Bound before the tuple is built: Swift 6.3.3 miscompiles
                    // a tuple around a `try await` in a task closure at -O, and
                    // the index came back as zero in Release (AGENTS.md).
                    let account = try await condense(part)
                    return (index, account)
                }
                next += 1
            }
            while let (index, account) = try await group.next() {
                results[index] = account
                await onProgress(results.count)
                try Task.checkCancellation()
                if next < parts.count {
                    let index = next
                    let part = parts[index]
                    group.addTask {
                        let account = try await condense(part)
                        return (index, account)
                    }
                    next += 1
                }
            }
        }
        return parts.indices.map { results[$0] ?? "" }
    }
}
