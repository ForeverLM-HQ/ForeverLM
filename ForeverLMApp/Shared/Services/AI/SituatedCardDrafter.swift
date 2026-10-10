import CryptoKit
import Foundation

/// Drafts Memory cards from what the learner made sense of — an Idea, an arrow
/// between two cards, an Atlas concept, a term — into To Check
/// (docs/sensemaking-design.md, "Cards from what you made sense of"). Each
/// draft is anchored to a quote from one of its anchor's sources, as every card
/// is, and waits for the learner's Keep, Edit or Skip.
///
/// One model call per batch of up to `SituatedCardDrafting.anchorsPerCall` anchors, on the Card
/// Drafting route (`AITask.cardDrafting`: the learner's card-drafting model),
/// with its own instructions (`Prompts.situatedCards`): one or two cards an
/// anchor, each standing on a passage the app gave by its handle, its quote a
/// sentence or two copied from that passage. The app turns the handles back
/// into sources and saves the drafts through `saveCardDrafts`, as every
/// drafted card is saved: a quote the source's text does not print is reported
/// and never offered, a seed or a question its deck holds is not offered
/// twice, and nothing is kept without the learner. The drafts arrive ticked
/// (the learner asked for them), as Make Cards' do.
///
/// An anchor that comes with no passages has them searched in its sources
/// first (`StudioViewModel.situatedPassages`); one whose sources give none is
/// left out and said.
@MainActor
enum SituatedCardDrafter {
    struct Outcome: Equatable, Sendable {
        /// Drafts saved to To Check.
        var drafted: Int
        /// Drafts dropped because their quote is not in the source's text.
        var notGrounded: Int
        /// The sources whose decks gained drafts.
        var sourceIDs: [String]
    }

    /// What one drafting did, in full: the `Outcome`, and why anything else
    /// was not drafted.
    struct Report: Equatable, Sendable {
        var drafted = 0
        var notGrounded = 0
        var sourceIDs: [String] = []
        /// Drafts whose seed or question their deck holds already.
        var alreadyDrafted = 0
        /// Drafts refused for what they were (no answer, a link, a third card
        /// for one anchor), by question.
        var refused: [String] = []
        /// Anchors whose sources gave no passage to stand on.
        var anchorsWithoutPassages = 0
        /// Why a source's drafts could not be saved, one line each.
        var failures: [String] = []

        var outcome: Outcome { Outcome(drafted: drafted, notGrounded: notGrounded, sourceIDs: sourceIDs) }

        /// "5 cards to check · 1 not found in its source".
        var summary: String {
            var parts = [drafted == 1 ? "1 card to check" : "\(drafted) cards to check"]
            if notGrounded > 0 {
                parts.append(notGrounded == 1 ? "1 not found in its source" : "\(notGrounded) not found in their sources")
            }
            if !failures.isEmpty {
                parts.append(failures.count == 1 ? "1 source failed" : "\(failures.count) sources failed")
            }
            return parts.joined(separator: " \u{00B7} ")
        }

        /// Why nothing was drafted, the likeliest reason first.
        var nothingDraftedMessage: String {
            if let failure = failures.first { return "No new cards: \(failure)" }
            if notGrounded > 0 { return "No new cards: the drafts quoted passages their sources do not print." }
            if alreadyDrafted > 0 { return "No new cards: these are drafted already." }
            if anchorsWithoutPassages > 0 { return "No new cards: nothing in their sources bears on them. Link the sources that do, then try again." }
            // The drafter writes a card only where a passage says it plainly,
            // and declines the rest: what was asked went past what the linked
            // sources say.
            return "No new cards: their sources do not say it plainly enough to ask. Link the sources that do, then try again."
        }
    }

    static func draft(_ anchors: [SituatedAnchor], studio: StudioViewModel) async throws -> Outcome {
        try await draftReport(anchors, studio: studio).outcome
    }

    /// `draft`, with the whole report: the anchors' passages searched where
    /// they have none, drafted on the learner's Card Drafting model, saved,
    /// and the cards' counts read again.
    static func draftReport(_ anchors: [SituatedAnchor], studio: StudioViewModel) async throws -> Report {
        guard let config = KeychainService.resolveConfig(for: .cardDrafting) else { throw CardDraftingError.noModel }
        var prepared = anchors.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.sourceIDs.isEmpty }
        for index in prepared.indices where prepared[index].passages.isEmpty {
            try Task.checkCancellation()
            prepared[index].passages = await studio.situatedPassages(
                [KnowledgeMapPassageSearch(query: prepared[index].text, sourceIDs: prepared[index].sourceIDs)]
            )
        }
        var labels: [String: String] = [:]
        for anchor in prepared {
            for id in anchor.sourceIDs + anchor.passages.map(\.sourceID) where labels[id] == nil {
                if let article = studio.articlesById[studio.canonicalSourceID(id)] {
                    labels[id] = SituatedCardDrafting.label(title: article.title, byline: KnowledgeMapModel.subtitle(article))
                }
            }
        }
        let report = try await draft(
            prepared,
            labels: labels,
            storage: studio.storage,
            backend: LiveSituatedCardBackend(aiService: studio.aiService, config: config)
        )
        if report.drafted > 0 {
            studio.memoryCardRevision &+= 1
            await studio.refreshMemoryCardCounts()
        }
        return report
    }

    /// The drafting itself, on `backend`: batches of `SituatedCardDrafting.anchorsPerCall`, each
    /// draft saved on its source through `saveCardDrafts`. `labels` names
    /// each source as the prompt shows it ("Title" — authors · year).
    static func draft(
        _ anchors: [SituatedAnchor],
        labels: [String: String],
        storage: StorageService,
        backend: any SituatedCardBackend,
        now: Date = Date()
    ) async throws -> Report {
        var report = Report()
        let usable = anchors.filter { !$0.passages.isEmpty }
        report.anchorsWithoutPassages = anchors.count - usable.count
        var drafts: [Flashcard] = []
        var start = 0
        while start < usable.count {
            try Task.checkCancellation()
            let batch = Array(usable[start..<min(start + SituatedCardDrafting.anchorsPerCall, usable.count)])
            start += batch.count
            let turn = SituatedCardDrafting.Turn(anchors: batch, labels: labels)
            let response = try await backend.draft(
                system: Prompts.situatedCards,
                user: turn.userMessage,
                maxTokens: CardDraftingTurn.maxTokens(cardCount: batch.count * SituatedCardDrafting.cardsPerAnchor),
                title: turn.title
            )
            let parsed = try SituatedCardDrafting.drafts(from: response, turn: turn, labels: labels, at: now)
            drafts += parsed.drafts
            report.refused += parsed.refused
        }
        try Task.checkCancellation()
        // Saved a source at a time, in the order the sources first appear.
        var order: [String] = []
        var bySource: [String: [Flashcard]] = [:]
        for draft in drafts {
            guard let sourceID = draft.sourceID else { continue }
            if bySource[sourceID] == nil { order.append(sourceID) }
            bySource[sourceID, default: []].append(draft)
        }
        for sourceID in order {
            let cards = bySource[sourceID] ?? []
            do {
                let saved = try await storage.saveCardDrafts(
                    cards,
                    sourceID: sourceID,
                    sourceTitle: SituatedCardDrafting.title(of: labels[sourceID]) ?? cards.first?.sourceTitle ?? "Source"
                )
                report.drafted += saved.added.count
                report.notGrounded += saved.ungrounded.count
                report.alreadyDrafted += saved.alreadyDrafted.count
                report.refused += saved.unreadable.map(\.front)
                if !saved.added.isEmpty, !report.sourceIDs.contains(saved.sourceID) {
                    report.sourceIDs.append(saved.sourceID)
                }
            } catch {
                report.failures.append(error.localizedDescription)
            }
        }
        return report
    }
}

/// The drafting model behind a protocol, so the tests pin the drafter with a
/// canned answer.
protocol SituatedCardBackend: Sendable {
    /// One batch's answer: the model's JSON, as it came.
    func draft(system: String, user: String, maxTokens: Int, title: String) async throws -> String
}

/// The learner's Card Drafting model, sent the request whole or not at all.
struct LiveSituatedCardBackend: SituatedCardBackend {
    let aiService: AIService
    let config: AITaskConfig

    func draft(system: String, user: String, maxTokens: Int, title: String) async throws -> String {
        let routed = KeychainService.routedTextConfig(config)
        let budgeted = AIService.budgetedOneShotRequest(
            provider: routed.provider,
            model: routed.model,
            system: system,
            user: user,
            requestedMaxTokens: maxTokens
        )
        // A request the central trim would cut is refused, never sent cut.
        guard budgeted.system == system, budgeted.user == user else {
            throw CardDraftingError.wouldBeCut(model: routed.model, title: title)
        }
        return try await aiService.call(
            config: config,
            system: system,
            user: user,
            maxTokens: maxTokens,
            temperature: 0.3,
            // Asking again asks for new cards, never the ones drafted before.
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: title,
            subjectID: "situated-cards"
        )
    }
}

/// The situated drafter's turn and its answer, pure: what the model is shown,
/// and the drafts its JSON makes.
enum SituatedCardDrafting {
    /// Anchors in one model call.
    static let anchorsPerCall = 8
    /// At most this many cards an anchor; a term gets one.
    static let cardsPerAnchor = 2

    /// One batch as the model sees it: each anchor under a handle (A1…) with
    /// the passages its cards may quote under theirs (P1…).
    struct Turn: Equatable, Sendable {
        struct Passage: Equatable, Sendable {
            let handle: String
            let anchorIndex: Int
            let passage: SituatedPassage
        }

        let anchors: [SituatedAnchor]
        let passages: [Passage]
        let userMessage: String
        /// What the usage ledger names the call by: the first passage's source.
        let title: String

        init(anchors: [SituatedAnchor], labels: [String: String]) {
            self.anchors = anchors
            var passages: [Passage] = []
            var lines: [String] = []
            lines.append("Draft one or two cards for each anchor below (one for a term), each standing on one of that anchor's passages.")
            for (index, anchor) in anchors.enumerated() {
                lines.append("")
                lines.append("[A\(index + 1)] \(SituatedCardDrafting.kindLine(anchor.kind)): \(anchor.text)")
                if let context = anchor.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
                    lines.append(context)
                }
                lines.append("Passages:")
                for passage in anchor.passages {
                    let handle = "P\(passages.count + 1)"
                    passages.append(Passage(handle: handle, anchorIndex: index, passage: passage))
                    lines.append("[\(handle)] From \(labels[passage.sourceID] ?? "a source in the library"):")
                    lines.append(passage.text)
                }
            }
            self.passages = passages
            self.userMessage = lines.joined(separator: "\n")
            self.title = passages.first.flatMap { SituatedCardDrafting.title(of: labels[$0.passage.sourceID]) } ?? "Cards from the Canvas"
        }
    }

    /// One card as the model wrote it: its anchor and passage by handle, never
    /// an id.
    struct ModelCard: Decodable, Equatable, Sendable {
        let anchor: String?
        let passage: String?
        let front: String?
        let back: String?
        let why: String?
        let quote: String?
        let difficulty: String?
    }

    struct ModelAnswer: Decodable, Sendable {
        let cards: [ModelCard]
    }

    struct Parsed: Equatable, Sendable {
        var drafts: [Flashcard] = []
        /// The questions refused, each with why.
        var refused: [String] = []
    }

    enum ParseError: LocalizedError, Equatable {
        case unreadable

        var errorDescription: String? { "The drafting model's answer could not be read as cards." }
    }

    static func kindLine(_ kind: SituatedAnchor.Kind) -> String {
        switch kind {
        case .idea: return "Idea, in the learner's own words"
        case .relation: return "Arrow the learner drew between two cards"
        case .concept: return "Concept"
        case .term: return "Term and its definition"
        }
    }

    /// "“Title” — Authors · 2024", how a passage's source is named.
    static func label(title: String, byline: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = "\u{201C}\(title.isEmpty ? "Untitled" : title)\u{201D}"
        let byline = byline.trimmingCharacters(in: .whitespacesAndNewlines)
        return byline.isEmpty ? named : "\(named) \u{2014} \(byline)"
    }

    /// The title back out of a label.
    static func title(of label: String?) -> String? {
        guard let label, label.hasPrefix("\u{201C}"), let close = label.firstIndex(of: "\u{201D}") else { return nil }
        let title = String(label[label.index(after: label.startIndex)..<close])
        return title.isEmpty ? nil : title
    }

    /// The deck seed a situated card is drafted from: its anchor's kind and
    /// words, and its place among the anchor's cards. The same Idea drafted
    /// again offers nothing new (`FlashcardDeck.appending`); an Idea the
    /// learner rewrote is a new seed. Ideas and arrows are the learner's own
    /// thinking, so their seeds read as an idea's (`idea:`) to generation 2's
    /// card origin; concepts and terms as a guide's.
    static func seedKey(for anchor: SituatedAnchor, card: Int) -> String {
        let words = CardDraftingSeedKey.words(anchor.text)
        let digest = SHA256.hash(data: Data("\(anchor.kind.rawValue)|\(words)".utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let prefix: String
        switch anchor.kind {
        case .idea: prefix = "idea:canvas"
        case .relation: prefix = "idea:arrow"
        case .concept: prefix = "concept"
        case .term: prefix = "term"
        }
        return "\(prefix):\(digest)#\(card)"
    }

    /// The drafts the model's answer makes. A card names its anchor and its
    /// passage by handle; its source is the passage's — the one of the
    /// anchor's (else the batch's) passages that prints its quote, else the
    /// one it named, so a quote no passage prints is still saved and
    /// reported as not found by `saveCardDrafts`. A card with no question or
    /// answer, one that writes a link, one past an anchor's share, or one
    /// naming no anchor is refused.
    static func drafts(from response: String, turn: Turn, labels: [String: String], at now: Date) throws -> Parsed {
        let answer: ModelAnswer
        do {
            answer = try decode(response)
        } catch {
            throw ParseError.unreadable
        }
        var parsed = Parsed()
        var counts: [Int: Int] = [:]
        for card in answer.cards {
            let front = FlashcardDeck.singleLine(card.front ?? "")
            let back = (card.back ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else {
                parsed.refused.append("\(front.isEmpty ? "A card" : front): no question or no answer")
                continue
            }
            let why = card.why.map(FlashcardDeck.singleLine).flatMap { $0.isEmpty ? nil : $0 }
            guard ![front, back, why ?? ""].contains(where: writesALink) else {
                parsed.refused.append("\(front): it wrote a link, which ForeverLM writes itself")
                continue
            }
            guard let anchorIndex = index(of: card.anchor, prefix: "A", count: turn.anchors.count) else {
                parsed.refused.append("\(front): it names no anchor")
                continue
            }
            let anchor = turn.anchors[anchorIndex]
            let share = anchor.kind == .term ? 1 : cardsPerAnchor
            let made = counts[anchorIndex, default: 0]
            guard made < share else {
                parsed.refused.append("\(front): one card more than its anchor takes")
                continue
            }
            let quote = (card.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let named = index(of: card.passage, prefix: "P", count: turn.passages.count).map { turn.passages[$0] }
            let own = turn.passages.filter { $0.anchorIndex == anchorIndex }
            let printing = quote.isEmpty ? nil
                : (own + turn.passages).first { MemoryGroundingText($0.passage.text).contains(quote) }
            guard let passage = printing ?? named ?? own.first else {
                parsed.refused.append("\(front): it stands on no passage")
                continue
            }
            counts[anchorIndex] = made + 1
            let sourceID = passage.passage.sourceID
            parsed.drafts.append(Flashcard.mint(
                front: front,
                back: back,
                why: why,
                sourceID: sourceID,
                sourceTitle: title(of: labels[sourceID]) ?? "Source",
                quote: quote,
                difficulty: card.difficulty.flatMap { MemoryCardDifficulty(rawValue: $0.lowercased()) },
                seed: seedKey(for: anchor, card: made + 1),
                origin: .drafted,
                isRequested: true,
                at: now
            ))
        }
        return parsed
    }

    /// "A3" (or "[A3]", "a3", "3") as an index into `count`.
    private static func index(of handle: String?, prefix: String, count: Int) -> Int? {
        guard var text = handle?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]"))).uppercased(),
              !text.isEmpty else { return nil }
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        guard let number = Int(text), number >= 1, number <= count else { return nil }
        return number - 1
    }

    private static func writesALink(_ text: String) -> Bool {
        text.contains("://") || text.contains("](")
    }

    /// The JSON object in a reply, tolerating a fenced block around it.
    private static func decode(_ response: String) throws -> ModelAnswer {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        return try JSONDecoder().decode(ModelAnswer.self, from: Data(text.utf8))
    }
}
