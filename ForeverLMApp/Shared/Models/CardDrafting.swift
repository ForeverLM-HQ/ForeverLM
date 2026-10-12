import CryptoKit
import Foundation

// MARK: - Memory as cards: drafting on request
//
// docs/memory-design.md, "Drafting". Make Cards — the Reader's, a notebook's
// Studio, a chat's or an assistant's (`draft_cards`) — drafts cards from each
// source's whole text for the learner to go through in Memory's To Check,
// marked as asked for (`Flashcard.isRequested`).
// Everything in this file is pure: what a request asks of each source, the
// seeds its cards come from first (a walkthrough's questions free, then the
// review guide's questions, the learner's highlights and notes, the source's
// ideas), the turn the model reads, what its answer becomes, and what the
// run reports. `CardDraftingService` reads storage and calls the model;
// `StorageService.saveCardDrafts` checks every quote and appends.

/// How many cards one request asks for (decisions 2026-09-30, "Drafting"):
/// Auto, about four a source and at most forty a request, or a number.
enum MemoryCardRequestCount: Hashable, Sendable, Identifiable {
    case auto
    case cards(Int)

    static let autoPerSource = 4
    static let maximumPerRequest = 40
    /// What the Make Cards sheet offers.
    static let choices: [MemoryCardRequestCount] = [.auto, .cards(10), .cards(20), .cards(40)]

    var id: String { label }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .cards(let count): return "\(count)"
        }
    }

    /// The cards asked of `sourceCount` sources, never more than forty.
    func total(sourceCount: Int) -> Int {
        guard sourceCount > 0 else { return 0 }
        switch self {
        case .auto: return min(sourceCount * Self.autoPerSource, Self.maximumPerRequest)
        case .cards(let count): return min(max(1, count), Self.maximumPerRequest)
        }
    }

    /// The MCP spelling: `"auto"`, or a number of cards from 1 to 40 (as a
    /// number or a numeral). Nil for anything else; an absent value is Auto.
    init?(argument: Any?) {
        guard let argument, !(argument is NSNull) else {
            self = .auto
            return
        }
        if let text = argument as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "auto" {
                self = .auto
                return
            }
            guard let count = Int(trimmed) else { return nil }
            self.init(validCount: count)
            return
        }
        // JSON's true and false bridge to NSNumber as 1 and 0, and `is Bool`
        // answers yes for those numbers too; the boolean's type is the tell.
        guard let number = argument as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else { return nil }
        self.init(validCount: number.intValue)
    }

    private init?(validCount count: Int) {
        guard (1...Self.maximumPerRequest).contains(count) else { return nil }
        self = .cards(count)
    }

    /// What MCP answers for it.
    var argument: Any {
        switch self {
        case .auto: return "auto"
        case .cards(let count): return count
        }
    }

    /// Each source's share of `total(sourceCount:)`, as even as it goes. The
    /// remainder goes to the sources the learner has opened first, then to
    /// the longest texts; a share is zero when there are fewer cards than
    /// sources, and that source is not drafted.
    func quotas(for sources: [CardDraftingQuotaInput]) -> [String: Int] {
        let total = total(sourceCount: sources.count)
        guard total > 0 else { return [:] }
        let base = total / sources.count
        var remainder = total % sources.count
        var quotas = Dictionary(sources.map { ($0.sourceID, base) }, uniquingKeysWith: { first, _ in first })
        let favoured = sources.enumerated().sorted { lhs, rhs in
            if lhs.element.isOpened != rhs.element.isOpened { return lhs.element.isOpened }
            if lhs.element.length != rhs.element.length { return lhs.element.length > rhs.element.length }
            return lhs.offset < rhs.offset
        }
        for entry in favoured where remainder > 0 {
            quotas[entry.element.sourceID, default: 0] += 1
            remainder -= 1
        }
        return quotas
    }
}

/// What a source's share of a request is decided by.
struct CardDraftingQuotaInput: Equatable, Sendable {
    let sourceID: String
    /// The learner has opened it in ForeverLM (read it, or left a place in it).
    let isOpened: Bool
    /// The length of its text, in characters.
    let length: Int
}

// MARK: - Seeds

/// The deck's seed keys (`Flashcard.seed`): what a draft was made from, so a
/// seed drafted once — kept or skipped since — is never offered again
/// (`FlashcardDeck.appending`, `MemoryCardTriage.toCheck`). Deterministic
/// code, never the model's: the model names a seed by the handle it was
/// shown, and the app turns the handle into its key.
enum CardDraftingSeedKey {
    static func walkStep(_ stepID: String) -> String { "walk-step:" + stepID }
    static func guideQuestion(_ question: String) -> String { "guide:" + digest(words(question)) }
    static func highlight(_ highlightID: String) -> String { "highlight:" + highlightID }
    static func idea(_ statement: String) -> String { "idea:" + digest(words(statement)) }
    /// A card drafted from the text alone stands on its passage: a second
    /// card on the same passage is not drafted, and one skipped stays away.
    static func passage(_ quote: String) -> String { "passage:" + digest(letters(quote)) }

    /// Lower case, its spacing collapsed: how two wordings of one question
    /// compare.
    static func words(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Letters and digits only, lower case: a passage the way the grounding
    /// check reads it (`MemoryGroundingText`), so a quote copied with other
    /// punctuation names the same passage.
    static func letters(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// One thing a source's cards may be drafted from, before the model writes
/// them: a walkthrough's question, a review guide's question with its strong
/// answer, a passage the learner highlighted (with their note), or one of the
/// source's ideas — offered in that order (decisions 2026-09-30, "Drafting").
struct CardDraftingSeed: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case walkStep
        case guideQuestion
        case highlight
        case idea

        /// The letter of the seed's handle in the model's turn: W1, G1, H1, I1.
        var handleLetter: String {
            switch self {
            case .walkStep: return "W"
            case .guideQuestion: return "G"
            case .highlight: return "H"
            case .idea: return "I"
            }
        }
    }

    /// A walkthrough's question with its answer and a passage the source
    /// prints: a card that needs no model to write it.
    struct Card: Equatable, Sendable {
        let front: String
        let back: String
        let why: String?
        let quote: String
        /// The figure the walkthrough asked it beside ("Figure 2b"), shown
        /// with the card's question when the source lists it.
        var figureLabel: String?
    }

    let kind: Kind
    /// The seed key the draft records (`CardDraftingSeedKey`).
    let key: String
    /// The seed as the model reads it after its handle.
    let text: String
    /// The question a walkthrough or review-guide seed asks, which a card
    /// of the source may already ask; nil for a highlight or an idea.
    let question: String?
    /// Set for a walkthrough question one of whose passages the source
    /// prints: drafted as it stands, free.
    let card: Card?
    /// The source idea the seed is, which a kept card records.
    let ideaID: String?

    init(kind: Kind, key: String, text: String, question: String? = nil, card: Card? = nil, ideaID: String? = nil) {
        self.kind = kind
        self.key = key
        self.text = text
        self.question = question
        self.card = card
        self.ideaID = ideaID
    }

    /// A walkthrough's questions as seeds, in the walk's order: each kind
    /// but Find it (answered by picking a panel, which a card cannot show).
    /// `printed` is the first of a question's passages its source prints
    /// (`SourceMemoryQuestion`'s order: the authors' sentence the step is
    /// about, its anchor passage, then the steps it follows in its chapter);
    /// a question with one is a card as it stands, one without is a seed the
    /// model writes a card from.
    static func walkSteps(of walkthrough: PaperWalkthrough, printed: ([String]) -> String?) -> [CardDraftingSeed] {
        walkthrough.steps.compactMap { step in
            guard let quiz = step.quiz, quiz.kind != .find else { return nil }
            let question = FlashcardDeck.singleLine(quiz.question)
            let points = quiz.keyPoints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let answer = quiz.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = answer.isEmpty ? points.joined(separator: "\n") : answer
            guard !question.isEmpty, !back.isEmpty else { return nil }
            let memoryQuestion = SourceMemoryQuestion(
                sourceID: walkthrough.sourceID,
                step: step,
                quiz: quiz,
                testing: walkthrough.stepsBefore(question: step.id)
            )
            let why = answer.isEmpty || points.isEmpty ? nil : points.joined(separator: "; ")
            let figure = (step.anchor?.figureLabel ?? step.picture?.figureLabel)
                .map(FlashcardDeck.singleLine)
                .flatMap { $0.isEmpty ? nil : $0 }
            var text = "Question: \(question)\nAnswer: \(FlashcardDeck.singleLine(back))"
            if let why { text += "\nKey points: \(why)" }
            if let figure { text += "\nAsked beside: \(figure)" }
            return CardDraftingSeed(
                kind: .walkStep,
                key: CardDraftingSeedKey.walkStep(step.id),
                text: text,
                question: question,
                card: printed(memoryQuestion.excerpts).map {
                    Card(front: question, back: back, why: why, quote: $0, figureLabel: figure)
                }
            )
        }
    }

    /// A review guide's questions with their strong answers.
    static func guideQuestions(in guide: String) -> [CardDraftingSeed] {
        CardDraftingGuide.questions(in: guide).map { pair in
            CardDraftingSeed(
                kind: .guideQuestion,
                key: CardDraftingSeedKey.guideQuestion(pair.question),
                text: "Question: \(pair.question)\nStrong answer: \(pair.strongAnswer)",
                question: pair.question
            )
        }
    }

    /// The learner's highlights, those with a note first.
    static func highlights(_ highlights: [SourceHighlight]) -> [CardDraftingSeed] {
        highlights
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.hasNote != rhs.element.hasNote { return lhs.element.hasNote }
                return lhs.offset < rhs.offset
            }
            .compactMap { _, highlight in
                let quote = FlashcardDeck.singleLine(highlight.quote)
                let note = FlashcardDeck.singleLine(highlight.note)
                guard !quote.isEmpty || !note.isEmpty else { return nil }
                var text = quote.isEmpty ? "" : "Highlighted: \u{201C}\(quote)\u{201D}"
                if !note.isEmpty { text += (text.isEmpty ? "" : "\n") + "Their note: \(note)" }
                return CardDraftingSeed(kind: .highlight, key: CardDraftingSeedKey.highlight(highlight.id), text: text)
            }
    }

    /// The source's active ideas, the learner's wanted ones first.
    static func ideas(_ ideas: [SourceIdea]) -> [CardDraftingSeed] {
        ideas
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                if lhs.wanted != rhs.wanted { return lhs.wanted }
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.id < rhs.id
            }
            .compactMap { idea in
                let statement = FlashcardDeck.singleLine(idea.statement)
                guard !statement.isEmpty else { return nil }
                let note = FlashcardDeck.singleLine(idea.recallNote)
                return CardDraftingSeed(
                    kind: .idea,
                    key: CardDraftingSeedKey.idea(statement),
                    text: note.isEmpty ? "Idea: \(statement)" : "Idea: \(statement)\nA good recall holds: \(note)",
                    ideaID: idea.id
                )
            }
    }

    /// The seeds a source's deck and kept cards do not cover yet, in the
    /// order they are offered: a seed the deck drafted once — kept, skipped
    /// or still to check — is never offered again, nor a walkthrough or
    /// review-guide question a card of the source already asks (a
    /// walkthrough question missed is kept as a card at once). `coveredFronts`
    /// are normalized (`Flashcard.normalizedFront`).
    static func uncovered(
        _ seeds: [CardDraftingSeed],
        coveredKeys: Set<String>,
        coveredFronts: Set<String>
    ) -> [CardDraftingSeed] {
        var seen = Set<String>()
        return seeds.filter { seed in
            guard !coveredKeys.contains(seed.key), seen.insert(seed.key).inserted else { return false }
            if let question = seed.question, coveredFronts.contains(Flashcard.normalizedFront(question)) { return false }
            return true
        }
    }
}

/// A review guide's questions and strong answers, read from the guide's own
/// structure: the plain-text shape `TutorContract.reviewPreparationInstructions`
/// asks for, its "Question:", "Strong answer:" and "Probe:" lines under each
/// key idea. Only a question with a strong answer is kept.
enum CardDraftingGuide {
    struct Question: Equatable, Sendable {
        let question: String
        let strongAnswer: String
    }

    static func questions(in guide: String) -> [Question] {
        enum Field { case none, question, answer }
        var found: [Question] = []
        var question = ""
        var answer = ""
        var field = Field.none
        func flush() {
            let q = FlashcardDeck.singleLine(question)
            let a = FlashcardDeck.singleLine(answer)
            if !q.isEmpty, !a.isEmpty { found.append(Question(question: q, strongAnswer: a)) }
            question = ""
            answer = ""
            field = .none
        }
        for raw in guide.components(separatedBy: .newlines) {
            let line = stripped(raw)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("question:") {
                flush()
                question = String(line.dropFirst("question:".count))
                field = .question
            } else if lower.hasPrefix("strong answer:") {
                answer = String(line.dropFirst("strong answer:".count))
                field = question.isEmpty ? .none : .answer
            } else if lower.hasPrefix("probe:") {
                field = .none
            } else if isHeading(line) {
                flush()
            } else {
                switch field {
                case .question: question += " " + line
                case .answer: answer += " " + line
                case .none: break
                }
            }
        }
        flush()
        return found
    }

    /// The line without its list marker, numbering and bold.
    private static func stripped(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        while let first = line.first, "-*•–".contains(first) {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// A section heading of the guide's shape: a line in capitals.
    private static func isHeading(_ line: String) -> Bool {
        let letters = line.filter(\.isLetter)
        return letters.count >= 4 && letters == letters.uppercased()
    }
}

// MARK: - The learner's own decisions as exemplars

/// A card the learner went through before, shown to the drafter after its
/// fixed instructions so its taste carries over (decisions 2026-09-30,
/// "Drafting"): cards they edited — before and after, the strongest sign —
/// then cards kept as drafted, and cards skipped, which say only "not
/// wanted". The same source's first, then the same notebook's.
struct CardDraftingExemplar: Equatable, Sendable {
    enum Kind: String, Sendable {
        case edited
        case kept
        case skipped
    }

    let kind: Kind
    let sourceID: String
    /// The card as the learner left it.
    let front: String
    let back: String
    /// What was drafted, for a card the learner edited.
    let draftedFront: String?
    let draftedBack: String?
    /// When the learner decided.
    let decidedAt: Date
}

enum CardDraftingExemplars {
    static let editedLimit = 3
    static let keptLimit = 3
    static let skippedLimit = 4

    /// One deck's decided cards as exemplars. `keptFace` is the face a kept
    /// card's Memory item holds (the learner's words, when they edited it at
    /// Keep); a kept card it gives no face for — its item not read, or not in
    /// the library — is left out.
    static func from(
        deck: MemoryCardDraftDeck,
        state: MemoryCardDeckState,
        keptFace: (_ cardID: String, _ itemID: String) -> MemoryCard?
    ) -> [CardDraftingExemplar] {
        deck.deck.cards.compactMap { card in
            guard let row = state.cards[card.id] else { return nil }
            switch row.status {
            case .draft:
                return nil
            case .skipped:
                return CardDraftingExemplar(
                    kind: .skipped, sourceID: deck.sourceID, front: card.front, back: card.back,
                    draftedFront: nil, draftedBack: nil, decidedAt: row.updatedAt
                )
            case .kept:
                guard let itemID = row.memoryItemID, let kept = keptFace(card.id, itemID) else { return nil }
                let front = row.editedFront?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? kept.front
                let back = kept.back
                let edited = Flashcard.normalizedFront(front) != Flashcard.normalizedFront(card.front)
                    || CardDraftingSeedKey.words(back) != CardDraftingSeedKey.words(card.back)
                return CardDraftingExemplar(
                    kind: edited ? .edited : .kept, sourceID: deck.sourceID, front: front, back: back,
                    draftedFront: edited ? card.front : nil, draftedBack: edited ? card.back : nil,
                    decidedAt: row.updatedAt
                )
            }
        }
    }

    /// The exemplars a source's turn shows: of each kind, the same source's
    /// newest first, then the notebook's.
    static func chosen(sameSource: [CardDraftingExemplar], notebook: [CardDraftingExemplar]) -> [CardDraftingExemplar] {
        func take(_ kind: CardDraftingExemplar.Kind, _ limit: Int) -> [CardDraftingExemplar] {
            let newest: ([CardDraftingExemplar]) -> [CardDraftingExemplar] = { list in
                list.filter { $0.kind == kind }.sorted { $0.decidedAt > $1.decidedAt }
            }
            return Array((newest(sameSource) + newest(notebook)).prefix(limit))
        }
        return take(.edited, editedLimit) + take(.kept, keptLimit) + take(.skipped, skippedLimit)
    }
}

// MARK: - A request, and a source as it is read

/// One Make Cards: which sources, how many cards, and what for.
struct CardDraftingRequest: Equatable, Sendable {
    enum Trigger: String, Sendable {
        /// The learner asked — the Reader's or the Studio's Make Cards, or an
        /// assistant on their word: the drafts arrive kept by default, and
        /// the background cap never pauses the run.
        case requested
        /// ForeverLM drafted on its own (stage C6): opt-in drafts, paused at
        /// the background cap.
        case automatic
    }

    /// The notebook the cards were asked for in, whose other sources' decided
    /// cards are exemplars too; nil from a Reader outside a notebook.
    let notebookID: String?
    let sourceIDs: [String]
    let count: MemoryCardRequestCount
    /// What the cards should serve, in the learner's words; nil for none.
    let focus: String?
    let trigger: Trigger
    /// What of each source drafting may use, by the id it is asked by; a
    /// source not named is drafted whole. Background drafting narrows a
    /// source the learner has not finished to what they met
    /// (`CardDraftingReach`); a request the learner made never does.
    let reach: [String: CardDraftingReach]

    init(
        notebookID: String?,
        sourceIDs: [String],
        count: MemoryCardRequestCount,
        focus: String?,
        trigger: Trigger,
        reach: [String: CardDraftingReach] = [:]
    ) {
        self.notebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var seen = Set<String>()
        self.sourceIDs = sourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.count = count
        self.focus = focus.map(FlashcardDeck.singleLine)?.nonEmpty
        self.trigger = trigger
        self.reach = reach.filter { !$0.value.isWhole }
    }

    var isRequested: Bool { trigger == .requested }

    /// What of `sourceID` drafting may use.
    func reach(of sourceID: String) -> CardDraftingReach {
        reach[sourceID] ?? .whole
    }
}

/// What of a source background drafting may draft from (decisions
/// 2026-09-30, "Automatic"; docs/memory-design.md, "Drafting in the
/// background"). A source the learner finished is drafted whole, as Make
/// Cards drafts it. Otherwise only what they met: for a source a chat is the
/// only reason they met, the ideas their chats engaged
/// (`CohortSourceBrief.gradableIdeas`, as the review grades it); for a
/// source read part way, the ideas anchored in the part read; and in either,
/// their own highlights and notes. A narrowed source is drafted from those
/// seeds alone: no walkthrough or review-guide question (they span the whole
/// source), and no card from the text alone, which the app refuses
/// (`CardDraftingAnswer.drafts`).
struct CardDraftingReach: Equatable, Sendable {
    /// The ideas drafting may use; nil for every one.
    let ideaIDs: Set<String>?
    /// How far through the source the learner read, 0...1; nil for no limit.
    let readThrough: Double?

    init(ideaIDs: Set<String>? = nil, readThrough: Double? = nil) {
        self.ideaIDs = ideaIDs
        self.readThrough = readThrough.map { min(max($0, 0), 1) }
    }

    static let whole = CardDraftingReach()

    var isWhole: Bool { ideaIDs == nil && readThrough == nil }

    /// The source's ideas within reach. `position` is where an idea's
    /// passage begins, as a fraction of the text (`MemoryGroundingText`
    /// offsets), nil when none of its anchors is found in it: such an idea is
    /// out of reach of a part read, since nothing says the learner met it.
    func ideas(_ ideas: [SourceIdea], position: (SourceIdea) -> Double?) -> [SourceIdea] {
        ideas.filter { idea in
            if let ideaIDs, !ideaIDs.contains(idea.id) { return false }
            guard let readThrough else { return true }
            guard let at = position(idea) else { return false }
            return at <= readThrough
        }
    }

    /// What background drafting may use of a source, from how the learner met
    /// it: whole when they finished it; a chat-only source's engaged ideas
    /// (`CohortSourceBrief.isChatOnly`: discussed, never read far enough on
    /// its own); a part read's ideas up to where they stopped.
    static func of(
        isFinished: Bool,
        engagement: CohortEngagement,
        confidence: SourceConsumptionConfidence,
        ideas: [SourceIdea],
        discussedIdeaIDs: [String]
    ) -> CardDraftingReach {
        if CohortSourceBrief.isChatOnly(engagement: engagement, confidence: confidence) {
            let gradable = CohortSourceBrief.gradableIdeas(
                ideas, discussedIdeaIDs: discussedIdeaIDs, engagement: engagement, confidence: confidence
            ).gradable
            return CardDraftingReach(ideaIDs: Set(gradable.map(\.id)))
        }
        guard !isFinished else { return .whole }
        return CardDraftingReach(readThrough: engagement.depth)
    }

    /// What background drafting may use of a source a wide chat discussed
    /// and the learner neither finished nor annotated
    /// (`AutomaticCardDrafting.wideChatSourceIDs`): exactly the active ideas
    /// the learner's chats engaged, and none when the day close recorded
    /// none — unlike the review's `gradableIdeas`, which falls back to every
    /// idea, a draft from a source the learner never opened must stand on
    /// what was talked about.
    static func discussed(ideas: [SourceIdea], discussedIdeaIDs: [String]) -> CardDraftingReach {
        let discussed = Set(discussedIdeaIDs)
        return CardDraftingReach(ideaIDs: Set(ideas.lazy.map(\.id).filter { discussed.contains($0) }))
    }
}

/// One source as drafting reads it: its whole text, the seeds its deck and
/// kept cards leave uncovered, what its cards already ask, and the learner's
/// decisions on its cards (`StorageService.cardDraftingSource`).
struct CardDraftingSource: Equatable, Sendable {
    /// The source the deck is for: the learner's own source at a team copy's
    /// address, as `saveCardDrafts` drafts it.
    let sourceID: String
    /// The id it was asked by (a team copy's, when it was one).
    let requestedID: String
    let title: String
    /// Its type's raw value, for the usage ledger.
    let sourceType: String
    /// What it is, as a reader would say it ("research paper").
    let kindLabel: String
    /// Its stored text, whole.
    let text: String
    /// Its uncovered seeds, in the order they are offered.
    let seeds: [CardDraftingSeed]
    /// The questions its cards already ask: its deck's, and its kept cards'.
    let coveredFronts: [String]
    /// The learner's decisions on its own cards.
    let exemplars: [CardDraftingExemplar]
    /// Opened in ForeverLM: read, or a place left in it.
    let isOpened: Bool
    /// What of it drafting may use: whole, or — background drafting of a
    /// source the learner has not finished — the seeds within reach, which
    /// `seeds` then holds alone.
    var reach: CardDraftingReach = .whole
    /// Its captioned figures, each cropped from its page, read off the file
    /// on this Mac (`CourseQuizGeneratorService.readingFigures`): what a card
    /// may show. Empty for a source with no figure or no file here.
    var figures: [CourseQuizFigure] = []
}

/// A source a request leaves out, and why.
struct CardDraftingSkip: Equatable, Sendable {
    let sourceID: String
    let title: String
    let reason: String
    /// Kept from AI (a muted tab, a hidden collection, outside Screen record
    /// mode's take): the app's sheet names it, an assistant hears only its id.
    var isKeptFromAI = false
}

// MARK: - Fitting the window

/// A source too long for the drafting model's window in one request is read
/// as evenly spaced excerpts, marked `[Sampled]` in the turn and named in the
/// result. Only then: a source the window takes is read whole, and a model
/// that publishes no window is sent the whole text (decisions 2026-09-30).
enum CardDraftingSampling {
    static let marker = "[Sampled]"
    static let gap = "\n[…]\n"
    /// The length each excerpt aims at.
    static let excerptCharacters = 6_000
    static let minimumExcerpts = 4
    static let maximumExcerpts = 24
    /// Below this much room for its text a source is not drafted at all:
    /// a handful of words is no reading of it.
    static let minimumTextCharacters = 4_000

    /// `text` as evenly spaced excerpts, in order, the first at its start and
    /// the last at its end (a paper's conclusions are read too), that
    /// together with the gaps between them run to at most `budget`
    /// characters, each cut at a line break near its ends where there is
    /// one. The text itself when it fits.
    static func excerpts(of text: String, budget: Int) -> String {
        let characters = Array(text)
        guard characters.count > budget, budget > 0 else { return text }
        let count = min(maximumExcerpts, max(minimumExcerpts, budget / excerptCharacters))
        let room = max(1, (budget - (count - 1) * gap.count) / count)
        // Where each excerpt starts: spread so the last one ends with the text.
        let span = max(0, characters.count - room)
        var pieces: [String] = []
        for index in 0..<count {
            var start = count > 1 ? index * span / (count - 1) : 0
            var end = min(characters.count, start + room)
            let slack = max(1, room / 10)
            if index > 0, start > 0, let lineStart = (start..<min(end, start + slack)).first(where: { characters[$0 - 1] == "\n" }) {
                start = lineStart
            }
            if end < characters.count,
               let lineEnd = stride(from: end, to: max(start + 1, end - slack), by: -1).first(where: { characters[$0 - 1] == "\n" }) {
                end = lineEnd
            }
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.joined(separator: gap)
    }
}

// MARK: - The turn

/// The drafter's user message: what varies after the fixed instructions
/// (`Prompts.cardDrafter`), the learner's exemplars first, so the head the
/// prompt cache keeps is the same for every source and every request.
enum CardDraftingTurn {
    /// The handles the turn shows its seeds under, in order: W1 W2 … G1 … H1 … I1 ….
    static func handles(for seeds: [CardDraftingSeed]) -> [(handle: String, seed: CardDraftingSeed)] {
        var counts: [CardDraftingSeed.Kind: Int] = [:]
        return seeds.map { seed in
            let number = (counts[seed.kind] ?? 0) + 1
            counts[seed.kind] = number
            return ("\(seed.kind.handleLetter)\(number)", seed)
        }
    }

    /// Said in the turn of a source drafted within reach
    /// (`CardDraftingReach`): the learner met only what the seeds hold.
    static let onlySeedsLine = "Draft from the seeds only: the learner has met only those parts of the source, so every card names the seed it was drafted from."

    /// The response budget one source's drafting asks for: room for each
    /// card's front, back, why, quote and keys.
    static func maxTokens(cardCount: Int) -> Int {
        min(16_000, 800 + max(1, cardCount) * 320)
    }

    /// `coveredFronts` are the questions the source's cards already ask, and
    /// those its free cards ask in this run.
    static func userMessage(
        source: CardDraftingSource,
        cardCount: Int,
        focus: String?,
        exemplars: [CardDraftingExemplar],
        seeds: [(handle: String, seed: CardDraftingSeed)],
        coveredFronts: [String],
        text: String,
        isSampled: Bool
    ) -> String {
        var lines = [
            "Source: \(FlashcardDeck.singleLine(source.title))",
            "Kind: \(source.kindLabel)",
            "Cards to write: \(cardCount)",
        ]
        if let focus {
            lines.append("Focus: \(focus)")
        }
        if !source.reach.isWhole {
            lines.append(onlySeedsLine)
        }
        let edited = exemplars.filter { $0.kind == .edited }
        let kept = exemplars.filter { $0.kind == .kept }
        let skipped = exemplars.filter { $0.kind == .skipped }
        if !exemplars.isEmpty {
            lines.append("")
            lines.append("The learner's decisions on cards drafted before:")
            if !edited.isEmpty {
                lines.append("Edited by the learner (before, then after):")
                for exemplar in edited {
                    lines.append("- Before: Q: \(FlashcardDeck.singleLine(exemplar.draftedFront ?? exemplar.front)) A: \(FlashcardDeck.singleLine(exemplar.draftedBack ?? exemplar.back))")
                    lines.append("  After: Q: \(FlashcardDeck.singleLine(exemplar.front)) A: \(FlashcardDeck.singleLine(exemplar.back))")
                }
            }
            if !kept.isEmpty {
                lines.append("Kept as drafted:")
                for exemplar in kept {
                    lines.append("- Q: \(FlashcardDeck.singleLine(exemplar.front)) A: \(FlashcardDeck.singleLine(exemplar.back))")
                }
            }
            if !skipped.isEmpty {
                lines.append("Not wanted:")
                for exemplar in skipped {
                    lines.append("- Q: \(FlashcardDeck.singleLine(exemplar.front))")
                }
            }
        }
        if !seeds.isEmpty {
            lines.append("")
            lines.append("Seeds:")
            for (handle, seed) in seeds {
                let body = seed.text.components(separatedBy: "\n")
                lines.append("[\(handle)] " + (body.first ?? ""))
                for continuation in body.dropFirst() {
                    lines.append("     " + continuation)
                }
            }
        }
        if !coveredFronts.isEmpty {
            lines.append("")
            lines.append("The source's cards already ask:")
            for front in coveredFronts {
                lines.append("- \(FlashcardDeck.singleLine(front))")
            }
        }
        if let figures = CourseQuizPictures.figureBlock(source.figures, heading: "Figures:") {
            lines.append("")
            lines.append(CardDraftingPictures.instruction)
            lines.append("")
            lines.append(figures)
        }
        lines.append("")
        lines.append(isSampled
            ? "Text \(CardDraftingSampling.marker): too long for one request, so evenly spaced excerpts follow, in order, with […] where text was left out."
            : "Text:")
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}

// MARK: - The route and the plan

/// The drafting model's route: its price and output ceiling
/// (`NotebookWritingRoute`), and the characters a request asking for a given
/// response budget may carry — from the model directory, nil when the model
/// publishes no window, never a figure made up here.
struct CardDraftingRoute: Sendable {
    let writing: NotebookWritingRoute
    let inputBudget: @Sendable (_ maxTokens: Int) -> Int?

    /// The learner's Card Drafting route, as `AIService.call` will send it.
    static func live(_ config: AITaskConfig) -> CardDraftingRoute {
        let writing = NotebookWritingRoute.live(
            config,
            writerMaxTokens: CardDraftingTurn.maxTokens(cardCount: MemoryCardRequestCount.maximumPerRequest),
            condenserMaxTokens: CardDraftingTurn.maxTokens(cardCount: MemoryCardRequestCount.maximumPerRequest)
        )
        let provider = writing.provider
        let model = writing.model
        return CardDraftingRoute(writing: writing) { maxTokens in
            AIService.inputCharacterBudget(provider: provider, model: model, requestedMaxTokens: maxTokens)
        }
    }

    /// The route the plans are priced and sized against now; nil when no
    /// model is configured (signed out, no key or plan, a broken setting).
    static func current() -> CardDraftingRoute? {
        KeychainService.resolveConfig(for: .cardDrafting).map(live)
    }
}

/// How one source will be drafted.
struct CardDraftingSourcePlan: Sendable {
    let source: CardDraftingSource
    /// The cards asked of it.
    let quota: Int
    /// Walkthrough questions drafted as they stand, with no model call.
    let free: [CardDraftingSeed]
    /// The cards the model is asked for: the quota less the free ones.
    let modelCards: Int
    /// The seeds the model's turn shows, by handle.
    let handles: [String: CardDraftingSeed]
    /// The text was too long for the window and is read as excerpts.
    let isSampled: Bool
    /// The turn as it will go; empty when no call is made.
    let user: String
    let maxTokens: Int

    var callsModel: Bool { modelCards > 0 }
}

/// What a request will draft and what it will cost, before anything is
/// sent. Pure: built from the sources as read and a route, so the Make Cards
/// sheet prices every change of count or focus without reading again.
struct CardDraftingPlan: Sendable {
    let request: CardDraftingRequest
    let sources: [CardDraftingSourcePlan]
    let skipped: [CardDraftingSkip]
    let route: CardDraftingRoute
    let system: String
    let cost: NotebookWritingCost

    /// The cards asked for, over every source drafted.
    var cardCount: Int { sources.reduce(0) { $0 + $1.quota } }
    var callCount: Int { sources.filter(\.callsModel).count }
    var sampledTitles: [String] { sources.filter(\.isSampled).map(\.source.title) }

    /// "15 sources · 2 left out · 1 sampled"
    var summary: String {
        var parts = [sources.count == 1 ? "1 source" : "\(sources.count) sources"]
        if !skipped.isEmpty { parts.append("\(skipped.count) left out") }
        if !sampledTitles.isEmpty { parts.append("\(sampledTitles.count) sampled") }
        return parts.joined(separator: " · ")
    }
}

enum CardDraftingPlanner {
    static let requestOverheadCharacters = AIService.perMessageOverheadChars

    /// Each source's share, its free cards, its turn — whole, or sampled
    /// when one source alone does not fit the window — and the price.
    /// `notebookExemplars` are the decided cards of the request's notebook,
    /// shown after a source's own.
    static func plan(
        request: CardDraftingRequest,
        sources: [CardDraftingSource],
        skipped: [CardDraftingSkip],
        notebookExemplars: [CardDraftingExemplar],
        route: CardDraftingRoute,
        system: String = AITask.cardDrafting.effectivePrompt ?? Prompts.cardDrafter
    ) -> CardDraftingPlan {
        // Two ids can name one source (a team copy and the learner's own):
        // it is drafted once.
        var seenSources = Set<String>()
        let unique = sources.filter { seenSources.insert($0.sourceID).inserted }
        let quotas = request.count.quotas(for: unique.map {
            CardDraftingQuotaInput(sourceID: $0.sourceID, isOpened: $0.isOpened, length: $0.text.count)
        })
        var planned: [CardDraftingSourcePlan] = []
        var left = skipped
        for source in unique {
            // Drafted within reach, a source has a card for a seed at most:
            // a card that names no seed is not offered.
            let narrowed = !source.reach.isWhole
            let quota = narrowed
                ? min(quotas[source.sourceID] ?? 0, source.seeds.count)
                : quotas[source.sourceID] ?? 0
            guard quota > 0 else { continue }
            let free = narrowed ? [] : Array(source.seeds.filter { $0.card != nil }.prefix(quota))
            let freeKeys = Set(free.map(\.key))
            let modelCards = quota - free.count
            guard modelCards > 0 else {
                planned.append(CardDraftingSourcePlan(
                    source: source, quota: quota, free: free, modelCards: 0,
                    handles: [:], isSampled: false, user: "", maxTokens: 0
                ))
                continue
            }
            let seeds = handlesFor(source.seeds.filter { !freeKeys.contains($0.key) })
            let exemplars = CardDraftingExemplars.chosen(
                sameSource: source.exemplars,
                notebook: notebookExemplars.filter { $0.sourceID != source.sourceID }
            )
            let maxTokens = CardDraftingTurn.maxTokens(cardCount: modelCards)
            // The free cards are asked in this run too: the model must not
            // draft them again.
            let covered = source.coveredFronts + free.compactMap { $0.card?.front }
            func turn(_ text: String, sampled: Bool) -> String {
                CardDraftingTurn.userMessage(
                    source: source, cardCount: modelCards, focus: request.focus,
                    exemplars: exemplars, seeds: seeds, coveredFronts: covered, text: text, isSampled: sampled
                )
            }
            var user = turn(source.text, sampled: false)
            var isSampled = false
            if let budget = route.inputBudget(maxTokens),
               system.count + user.count + requestOverheadCharacters > budget {
                let fixed = system.count + turn("", sampled: true).count + requestOverheadCharacters
                let room = budget - fixed
                guard room >= CardDraftingSampling.minimumTextCharacters else {
                    left.append(CardDraftingSkip(
                        sourceID: source.sourceID,
                        title: source.title,
                        reason: "Its seeds and the cards it has leave no room for its text in \(route.writing.modelLabel)'s context window."
                    ))
                    continue
                }
                user = turn(CardDraftingSampling.excerpts(of: source.text, budget: room), sampled: true)
                isSampled = true
            }
            planned.append(CardDraftingSourcePlan(
                source: source,
                quota: quota,
                free: free,
                modelCards: modelCards,
                handles: Dictionary(uniqueKeysWithValues: seeds.map { ($0.handle, $0.seed) }),
                isSampled: isSampled,
                user: user,
                maxTokens: maxTokens
            ))
        }
        return CardDraftingPlan(
            request: request,
            sources: planned,
            skipped: left,
            route: route,
            system: system,
            cost: cost(of: planned, system: system, route: route)
        )
    }

    private static func handlesFor(_ seeds: [CardDraftingSeed]) -> [(handle: String, seed: CardDraftingSeed)] {
        CardDraftingTurn.handles(for: seeds)
    }

    /// The price of every call the plan makes: the turn as it will go, the
    /// cards at their usual length (expected), and every call's output
    /// ceiling, reasoning room included (at most).
    static func cost(of sources: [CardDraftingSourcePlan], system: String, route: CardDraftingRoute) -> NotebookWritingCost {
        let perToken = AIService.approxCharsPerToken
        var inputTokens = 0
        var expected = 0
        var maximum = 0
        var expectedUSD: Double? = 0
        var maximumUSD: Double? = 0
        var requests = 0
        for source in sources where source.callsModel {
            let input = (system.count + source.user.count + requestOverheadCharacters) / perToken
            let cardsExpected = source.modelCards * 180 + 150
            let ceiling = route.writing.outputCeiling(requested: source.maxTokens)
            requests += 1
            inputTokens += input
            expected += cardsExpected
            maximum += ceiling
            expectedUSD = expectedUSD.flatMap { total in route.writing.usd(inputTokens: input, outputTokens: cardsExpected).map { total + $0 } }
            maximumUSD = maximumUSD.flatMap { total in route.writing.usd(inputTokens: input, outputTokens: ceiling).map { total + $0 } }
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

/// One card as the drafter wrote it: never an id or a link, and its seed
/// only as the handle it was shown.
struct CardDraftingModelCard: Decodable, Equatable, Sendable {
    let front: String?
    let back: String?
    let why: String?
    let quote: String?
    let difficulty: String?
    let seed: String?
    /// The handle of a listed figure the card shows ("F2"), which side it
    /// shows on ("front" or "back"), and what it shows, for its alt text.
    let figure: String?
    let figureWith: String?
    let figureShows: String?

    init(
        front: String?,
        back: String?,
        why: String? = nil,
        quote: String?,
        difficulty: String? = nil,
        seed: String? = nil,
        figure: String? = nil,
        figureWith: String? = nil,
        figureShows: String? = nil
    ) {
        self.front = front
        self.back = back
        self.why = why
        self.quote = quote
        self.difficulty = difficulty
        self.seed = seed
        self.figure = figure
        self.figureWith = figureWith
        self.figureShows = figureShows
    }

    private enum CodingKeys: String, CodingKey {
        case front, back, why, quote, difficulty, seed, figure
        case figureWith = "figure_with"
        case figureShows = "figure_shows"
    }

    /// A model may write a handle as a number (2 for F2): either is read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            return nil
        }
        front = text(.front)
        back = text(.back)
        why = text(.why)
        quote = text(.quote)
        difficulty = text(.difficulty)
        seed = text(.seed)
        figure = text(.figure)
        figureWith = text(.figureWith)
        figureShows = text(.figureShows)
    }
}

/// The figures a drafted card shows (product owner, 2026-10-11: "flashcards
/// should also have images a lot of the time; esp for a paper where basically
/// the key point is in a figure"). The source's captioned figures are listed
/// in the turn under handles F1, F2 …, as a course quiz lists a reading's;
/// the drafter pins one to a card's front or back, and a walkthrough question
/// drafted as it stands keeps the figure it was asked beside. Like the quiz
/// writer's, the instruction rides in the turn, not the task's editable
/// prompt, so an edited prompt still pins figures.
enum CardDraftingPictures {
    static let instruction = """
        The source's figures are listed below: [F2 · p.5] and the figure's printed caption. In a paper the key result is often a figure, so aim for a figure on every card whose point a listed figure shows: a result, a graph, a comparison, a mechanism, a structure, a pathway, a table. A seed asked beside a figure is about it. For such a card add to its JSON object:
        "figure": the figure's handle, "F2";
        "figure_with": "front" when the learner needs to see it to answer and it does not show the answer, and the front may then point at it ("the trace in this figure") while still naming the study; "back" when the figure shows or states the answer, so it is shown only once they have answered; when in doubt, "back";
        "figure_shows": what the figure shows, in a few words that never give the answer away.
        Leave the three out when no listed figure shows the card's point.
        """

    /// The listed figure a handle names ("F2", "[F2]", "2"); nil for one
    /// the source does not list.
    static func figure(handle: String?, in figures: [CourseQuizFigure]) -> CourseQuizFigure? {
        guard let handle else { return nil }
        let trimmed = handle
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]")))
            .uppercased()
        let digits = trimmed.hasPrefix("F") ? String(trimmed.dropFirst()) : trimmed
        guard let number = Int(digits) else { return nil }
        return figures.first { $0.number == number }
    }

    /// The listed figure a walkthrough step names, by its printed label:
    /// blind to "Fig." versus "Figure", and a panel ("Figure 2b") finds its
    /// figure when no figure is labelled that way.
    static func figure(labelled label: String, in figures: [CourseQuizFigure]) -> CourseQuizFigure? {
        func key(_ figure: CourseQuizFigure) -> String? {
            figure.label.map(PaperWalkthroughValidation.canonicalLabel)
        }
        let needle = PaperWalkthroughValidation.canonicalLabel(label)
        if let exact = figures.first(where: { key($0) == needle }) { return exact }
        let stripped = needle.replacingOccurrences(of: #"(\d)[a-z]+$"#, with: "$1", options: .regularExpression)
        guard stripped != needle else { return nil }
        return figures.first { key($0) == stripped }
    }

    /// A model card's figure on the side it named: the front's and the
    /// back's pictures, both empty when it named none the source lists.
    static func images(for card: CardDraftingModelCard, in figures: [CourseQuizFigure]) -> (front: [MemoryCardImage], back: [MemoryCardImage]) {
        guard let figure = figure(handle: card.figure, in: figures) else { return ([], []) }
        let shows = card.figureShows.map(FlashcardDeck.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        guard let image = MemoryCardImage(
            target: figure.reference.urlString,
            alt: shows ?? figure.label ?? "Figure \(figure.number)"
        ) else { return ([], []) }
        let side = card.figureWith?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "question" is the course quizzes' word for the front.
        return side == "front" || side == "question" ? ([image], []) : ([], [image])
    }
}

struct CardDraftingModelAnswer: Decodable, Sendable {
    let cards: [CardDraftingModelCard]
}

enum CardDraftingAnswer {
    /// A drafted card the app does not offer, and why.
    struct Refused: Equatable, Sendable {
        let front: String
        let reason: String
    }

    struct Drafts: Equatable, Sendable {
        var drafts: [Flashcard] = []
        var refused: [Refused] = []
    }

    /// The source's free cards as drafts: its walkthrough questions, as
    /// they stand, on the passage their source prints.
    static func freeDrafts(_ plan: CardDraftingSourcePlan, isRequested: Bool, at now: Date) -> [Flashcard] {
        plan.free.compactMap { seed in
            guard let card = seed.card else { return nil }
            let figure = card.figureLabel.flatMap { CardDraftingPictures.figure(labelled: $0, in: plan.source.figures) }
            let frontImages = figure.flatMap { MemoryCardImage(target: $0.reference.urlString, alt: $0.label ?? "Figure \($0.number)") }
                .map { [$0] } ?? []
            return Flashcard.mint(
                front: card.front,
                back: card.back,
                why: card.why,
                sourceID: plan.source.sourceID,
                sourceTitle: plan.source.title,
                quote: card.quote,
                seed: seed.key,
                ideaID: seed.ideaID,
                origin: .drafted,
                isRequested: isRequested,
                frontImages: frontImages,
                at: now
            )
        }
    }

    /// The model's cards as drafts, no more than were asked for: each one's
    /// seed is the key of the handle it named, or — a card drafted from the
    /// text — the passage it quotes. A card with no front or back, or one
    /// that writes a link, is refused and said; quotes are checked when the
    /// drafts are saved (`saveCardDrafts`), which reports those the source
    /// does not print.
    static func drafts(
        _ cards: [CardDraftingModelCard],
        plan: CardDraftingSourcePlan,
        isRequested: Bool,
        at now: Date
    ) -> Drafts {
        var result = Drafts()
        var usedHandles = Set<String>()
        for card in cards {
            guard result.drafts.count < plan.modelCards else { break }
            let front = FlashcardDeck.singleLine(card.front ?? "")
            let back = (card.back ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else {
                result.refused.append(Refused(front: front, reason: "It had no question or no answer."))
                continue
            }
            let why = card.why.map(FlashcardDeck.singleLine)?.nonEmpty
            guard ![front, back, why ?? ""].contains(where: writesALink) else {
                result.refused.append(Refused(front: front, reason: "It wrote a link, which ForeverLM writes itself."))
                continue
            }
            let quote = (card.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = card.seed?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]")))
                .uppercased()
            let seed = handle.flatMap { plan.handles[$0] }
            if let handle, seed != nil, !usedHandles.insert(handle).inserted {
                result.refused.append(Refused(front: front, reason: "Its seed already has a card."))
                continue
            }
            if seed == nil, !plan.source.reach.isWhole {
                result.refused.append(Refused(front: front, reason: "It names no seed, and the learner has met only the seeds' parts of the source."))
                continue
            }
            let images = CardDraftingPictures.images(for: card, in: plan.source.figures)
            result.drafts.append(Flashcard.mint(
                front: front,
                back: back,
                why: why,
                sourceID: plan.source.sourceID,
                sourceTitle: plan.source.title,
                quote: quote,
                difficulty: card.difficulty.flatMap { MemoryCardDifficulty(rawValue: $0.lowercased()) },
                seed: seed?.key ?? (quote.isEmpty ? nil : CardDraftingSeedKey.passage(quote)),
                ideaID: seed?.ideaID,
                origin: .drafted,
                isRequested: isRequested,
                frontImages: images.front,
                backImages: images.back,
                at: now
            ))
        }
        return result
    }

    private static func writesALink(_ text: String) -> Bool {
        text.contains("://") || text.contains("](")
    }
}

// MARK: - What a run reports

/// What drafting did with one source.
struct CardDraftingSourceOutcome: Equatable, Sendable {
    let sourceID: String
    let title: String
    /// The drafts added to its deck, waiting in To Check.
    var added: [Flashcard] = []
    /// Drafts whose seed or question its deck already holds: not offered again.
    var alreadyDrafted = 0
    /// Drafts whose quote its text does not print: reported, never offered.
    var ungrounded: [Flashcard] = []
    /// Drafts refused for what they were (no answer, a link, a line its
    /// deck's format cannot carry), by question.
    var notSaved: [CardDraftingAnswer.Refused] = []
    /// Its text was too long for the window and was read as excerpts.
    var isSampled = false
    /// How many of the added drafts needed no model call.
    var freeCount = 0
    /// Why nothing was drafted for it, when nothing was.
    var failure: String?
    /// A background run's gate said no before its model call: the daily
    /// background AI limit, not a failure of the source.
    var waitsForSpend = false
}

/// What one request did, source by source.
struct CardDraftingResult: Equatable, Sendable {
    var sources: [CardDraftingSourceOutcome] = []
    var skipped: [CardDraftingSkip] = []

    var addedCount: Int { sources.reduce(0) { $0 + $1.added.count } }
    var ungroundedCount: Int { sources.reduce(0) { $0 + $1.ungrounded.count } }
    var sampledTitles: [String] { sources.filter(\.isSampled).map(\.title) }
    var failures: [CardDraftingSourceOutcome] { sources.filter { $0.failure != nil } }
    /// The sources at least one card was added to.
    var draftedSourceIDs: [String] { sources.filter { !$0.added.isEmpty }.map(\.sourceID) }

    /// "12 cards to check from 3 sources · 1 sampled · 2 not found in their
    /// source"; what the toast says when a run ends.
    var summary: String {
        let added = addedCount
        let sourceCount = Set(sources.filter { !$0.added.isEmpty }.map(\.sourceID)).count
        var parts: [String] = []
        if added == 0 {
            parts.append("No new cards")
        } else {
            let cards = added == 1 ? "1 card" : "\(added) cards"
            parts.append(sourceCount == 1 ? "\(cards) to check" : "\(cards) to check from \(sourceCount) sources")
        }
        if !sampledTitles.isEmpty { parts.append("\(sampledTitles.count) sampled") }
        let ungrounded = ungroundedCount
        if ungrounded > 0 {
            parts.append(ungrounded == 1 ? "1 not found in its source" : "\(ungrounded) not found in their source")
        }
        if !failures.isEmpty { parts.append(failures.count == 1 ? "1 source failed" : "\(failures.count) sources failed") }
        return parts.joined(separator: " · ")
    }
}

/// Whether drafting may spend now. The learner's own Make Cards is never
/// paused by the background cap; background drafting asks before every paid
/// call and stops at the first no (`StudioViewModel.backgroundAISpendAllowed`).
enum CardDraftingSpendGate: Sendable {
    case learnerStarted
    case background(@Sendable () async -> Bool)

    func allowsSpend() async -> Bool {
        switch self {
        case .learnerStarted: return true
        case .background(let allowed): return await allowed()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
