import Foundation
import os

/// Ask the Canvas (docs/sensemaking-design.md, "Ask the Canvas"): one model
/// call answers one question asked of a selection of cards, as proposals the
/// learner keeps or dismisses.
///
/// - **Bridge**: sources in the library that connect the cards, found by a
///   search built from the learner's own words (their Ideas' sentences and
///   region names first, then titles).
/// - **Connect**: typed arrows between the cards on the plane.
/// - **Gaps**: research questions the cards leave open.
/// - **Summarize**: one Idea (a title and a note of a few sentences) that sums
///   the cards up.
/// - **Break Down**: one source taken apart into 5 to 12 concept Ideas with a
///   sentence each, and the arrows among them, laid out in a region named for
///   the source.
/// - **Mind Map**: what the cards say as a tree of topics, a root, 3 to 7
///   branches and leaves of at most 8 words each, hung from the one card
///   asked about when it is an Idea on the canvas.
/// - **Question Map**: the same tree with a question at every node, each
///   narrower than its parent and its leaves answerable by a literature
///   search or an experiment.
///
/// The model reads each card with its best passage, the regions holding the
/// cards, the arrows among them and what the learner set aside before. Every
/// card, candidate and passage carries a short id (`c1`, `s1`, `p1`) the model
/// answers with; the app maps them back and keeps only ids it gave. The model
/// never writes a quote: a passage is the app's own excerpt of stored text.
enum CanvasAskService {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CanvasAsk")

    /// Most cards one Ask reads.
    static let maximumCards = 24
    /// Most library sources a Bridge chooses from.
    static let maximumCandidates = 30
    /// How much of a card's best passage the model reads, and of a candidate's.
    static let passageCharacters = 900
    static let candidatePassageCharacters = 500
    /// How long the search built from the cards may be.
    static let queryCharacters = 600

    static let maximumBridges = 5
    static let maximumArrows = 6
    static let maximumGaps = 4
    static let bridgeWhyWords = 14
    static let arrowWhyWords = 16
    static let gapWhyWords = 16
    static let questionWords = 25
    static let labelWords = 4
    /// A Summarize's title, in characters, and its note, in sentences and characters.
    static let summaryTitleCharacters = 120
    static let summarySentences = 5
    static let summaryNoteCharacters = 1100
    /// A Break Down: how many concepts and arrows at most, and how long each
    /// concept's title and note are, in words.
    static let maximumConcepts = 12
    static let minimumConcepts = 2
    static let maximumBreakDownArrows = 14
    static let conceptTitleWords = 12
    static let conceptNoteWords = 28
    /// A Mind Map or Question Map: how many nodes at most (besides a root the
    /// model wrote), how few make a tree, how many levels deep under the root,
    /// and how long a node's title and note are, in words. A question is kept
    /// whole or not at all (cut, it would not be one), so its limit is the
    /// largest the page can show, not the 14 words the model is asked for.
    static let maximumTreeNodes = 30
    static let minimumTreeNodes = 3
    static let maximumTreeDepth = 3
    static let treeTitleWords = 8
    static let treeQuestionWords = 20
    static let treeNoteWords = 28
    /// A Break Down reads the source as this many passages spread from its
    /// start to its end, each at most this many characters.
    static let breakDownPassageCount = 14
    static let breakDownPassageCharacters = 1200
    /// What an arrow can say about two cards.
    static let relations: Set<String> = ["supports", "contradicts", "explains", "causes", "measures", "extends", "example", "same_question"]

    /// Whether the one source asked is read whole, as passages spread from its
    /// start to its end, rather than by the one passage that best answers the
    /// cards' words: a Break Down always, and a Mind Map or Question Map of a
    /// single source.
    static func readsWholeSource(_ tool: CanvasAskTool, kinds: [KnowledgeMap.ItemKind]) -> Bool {
        tool == .breakDown || (tool.drawsTree && kinds == [.source])
    }

    // MARK: What the main actor gathers

    /// The asked cards as the Canvas holds them, gathered on the main actor in
    /// one cheap pass; everything slow is read from it off the main actor.
    struct Snapshot: Sendable {
        struct Item: Equatable, Sendable {
            var ref: String
            var kind: KnowledgeMap.ItemKind
            /// A source's or Doc's title; an Idea's sentence.
            var title: String
            /// Who, when and where: a source's or Doc's subtitle.
            var byline: String
            /// paper, podcast, doc, idea…
            var type: String
            var placed: Bool
            /// The region holding it, by name.
            var region: String?
            /// An Idea's note.
            var note: String?
            /// An Idea's evidence, by ref.
            var evidence: [String] = []
        }

        var tool: CanvasAskTool
        var items: [Item]
        /// The arrows among the asked cards, by ref.
        var arrows: [Arrow]
        /// What the learner set aside from earlier answers of this tool.
        var setAside: [String]
        /// The sources set aside from a Bridge this session.
        var setAsideSourceIDs: Set<String>
        /// Every card the Canvas can draw, by ref: a Bridge proposes only these.
        var nodes: [String: KnowledgeMapNode]
        var placedRefs: Set<String>

        var readsWholeSource: Bool { CanvasAskService.readsWholeSource(tool, kinds: items.map(\.kind)) }
    }

    /// An arrow between two cards: by ref in a snapshot, by card id in a context.
    struct Arrow: Equatable, Sendable {
        var from: String
        var to: String
        var label: String
    }

    // MARK: What the model reads

    struct Card: Equatable, Sendable {
        /// `c1`, `c2`…
        var id: String
        var item: Snapshot.Item
        /// The learner's first highlight in a source.
        var highlight: String?
        var passageID: String?
        /// An Idea's evidence, by title.
        var evidenceTitles: [String] = []
    }

    struct Passage: Equatable, Sendable {
        /// `p1`, `p2`…
        var id: String
        /// The card or candidate it comes from.
        var ref: String
        var text: String
    }

    /// A library source a Bridge may propose.
    struct Candidate: Equatable, Sendable {
        /// `s1`, `s2`…
        var id: String
        var sourceID: String
        var title: String
        var byline: String
        var type: String
        /// Placed on the Canvas somewhere already.
        var onCanvas: Bool
        var passageID: String?
    }

    struct Context: Equatable, Sendable {
        var tool: CanvasAskTool
        var cards: [Card]
        var passages: [Passage]
        var candidates: [Candidate] = []
        /// Between asked cards, by card id.
        var arrows: [Arrow] = []
        var regions: [String] = []
        var setAside: [String] = []

        /// The card a Mind Map or Question Map hangs from: the one card asked
        /// about, when it is an Idea on the canvas. The model then writes no
        /// root, and the tree's first branches start at this card.
        var rootCard: Card? {
            guard tool.drawsTree, cards.count == 1, let card = cards.first,
                  card.item.kind == .idea, card.item.placed else { return nil }
            return card
        }

        var readsWholeSource: Bool { CanvasAskService.readsWholeSource(tool, kinds: cards.map(\.item.kind)) }

        func card(_ id: String) -> Card? { cards.first { $0.id == id } }
        func candidate(_ id: String) -> Candidate? { candidates.first { $0.id == id } }
        func passage(_ id: String) -> Passage? { passages.first { $0.id == id } }

        /// The asked sources, by source id.
        var askedSourceIDs: Set<String> {
            Set(cards.compactMap { card in
                guard card.item.kind == .source else { return nil }
                return KnowledgeMap.ItemRef(card.item.ref)?.id
            })
        }
    }

    /// One proposal and the passages it rests on, by id.
    struct Answer: Equatable, Sendable {
        var proposal: KnowledgeMapProposal
        var cites: [String] = []
    }

    /// One Ask's outcome: the set shown, each proposal's grounds, and what the
    /// model read.
    struct Result: Sendable {
        var set: KnowledgeMapProposalSet
        var answers: [Answer]
        var context: Context
    }

    // MARK: Building the context (off the main actor)

    /// Reads what the model needs about the asked cards, and for a Bridge the
    /// library sources it may propose: each card's best passage for the cards'
    /// combined words (else the start of its text), a source's first
    /// highlight, a Doc's opening, an Idea's note and evidence.
    static func context(for snapshot: Snapshot, storage: StorageService, ai: AIService) async throws -> Context {
        let items = Array(snapshot.items.prefix(maximumCards))
        // One source read whole (a Break Down, a Mind Map of it) needs no search.
        let wholeSource = snapshot.readsWholeSource
        let query = wholeSource ? "" : searchQuery(for: items)
        let terms = query.isEmpty ? [] : SourceSearchEngine.searchTerms(for: query)
        var vector: [Float]?
        if !query.isEmpty {
            do {
                vector = try await ai.embedText(query)
            } catch {
                // The lexical branch still finds the learner's terms.
                logger.error("Ask the Canvas searches without the semantic branch: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()

        let sourceIDs = items.compactMap { $0.kind == .source ? KnowledgeMap.ItemRef($0.ref)?.id : nil }
        var highlights: [String: String] = [:]
        if !sourceIDs.isEmpty {
            do {
                for (id, list) in try await storage.sourceHighlights(sourceIDs: sourceIDs) {
                    let quote = list.lazy
                        .map { $0.quote.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                    if let quote { highlights[id] = String(quote.prefix(300)) }
                }
            } catch {
                logger.error("Ask the Canvas reads the cards without their highlights: \(error.localizedDescription)")
            }
        }
        let contents = sourceIDs.isEmpty ? [:] : await storage.loadStoredSourceContents(for: sourceIDs)
        let hits = sourceIDs.isEmpty || query.isEmpty
            ? []
            : await storage.searchSources(queryText: query, queryVector: vector, limit: sourceIDs.count, restrictedTo: Set(sourceIDs))
        var bestChunks: [String: String] = [:]
        for hit in hits { if let chunk = hit.bestChunkId, bestChunks[hit.sourceId] == nil { bestChunks[hit.sourceId] = chunk } }
        try Task.checkCancellation()

        var passages: [Passage] = []
        func addPassage(_ ref: String, _ text: String) -> String? {
            guard !text.isEmpty else { return nil }
            let id = "p\(passages.count + 1)"
            passages.append(Passage(id: id, ref: ref, text: text))
            return id
        }

        var cards: [Card] = []
        for (index, item) in items.enumerated() {
            var card = Card(id: "c\(index + 1)", item: item)
            let id = KnowledgeMap.ItemRef(item.ref)?.id ?? ""
            switch item.kind {
            case .clip, .page, .canvas, .chat, .picture:
                // A clip reads as its name (the figure it holds) and the
                // learner's note on it, which ride on the card; a page as
                // its number and the paper it is a page of; a shortcut to a
                // canvas, a chat or a picture by its name alone.
                break
            case .source:
                card.highlight = highlights[id]
                if wholeSource {
                    // The whole source as passages from its start to its end,
                    // listed beside the card rather than on it.
                    for text in spreadPassages(from: contents[id] ?? "") { _ = addPassage(item.ref, text) }
                    if passages.isEmpty { throw ContextError.noText(item.title) }
                } else {
                    let passage = bestPassage(content: contents[id] ?? "", chunkID: bestChunks[id], terms: terms, length: passageCharacters)
                    card.passageID = addPassage(item.ref, passage)
                }
            case .doc:
                // A Doc or report reads as its opening; a site, animation or
                // audio overview by its title.
                if item.type == "doc" {
                    do {
                        let markdown = try await storage.artifactMarkdown(id).markdown
                        card.passageID = addPassage(item.ref, excerpt(markdown, terms: [], length: passageCharacters))
                    } catch {
                        logger.error("Ask the Canvas reads Doc \(id) by its title: \(error.localizedDescription)")
                    }
                }
            case .idea:
                card.evidenceTitles = Array(item.evidence.compactMap { snapshot.nodes[$0]?.title }.prefix(12))
            }
            cards.append(card)
        }

        let cardIDs = Dictionary(cards.map { ($0.item.ref, $0.id) }, uniquingKeysWith: { first, _ in first })
        let arrows = snapshot.arrows.compactMap { arrow -> Arrow? in
            guard let from = cardIDs[arrow.from], let to = cardIDs[arrow.to] else { return nil }
            return Arrow(from: from, to: to, label: arrow.label)
        }
        var regions: [String] = []
        for region in items.compactMap(\.region) where !regions.contains(region) { regions.append(region) }

        var context = Context(
            tool: snapshot.tool,
            cards: cards,
            passages: passages,
            arrows: arrows,
            regions: regions,
            setAside: snapshot.setAside
        )
        if snapshot.tool == .bridge, !query.isEmpty {
            try await addCandidates(to: &context, snapshot: snapshot, query: query, vector: vector, terms: terms, storage: storage)
        }
        return context
    }

    /// A Bridge's candidates: the library's best matches for the cards' words,
    /// leaving out the asked sources, their Ideas' evidence, what the learner
    /// set aside, what is kept from AI, and anything the Canvas cannot draw.
    private static func addCandidates(
        to context: inout Context,
        snapshot: Snapshot,
        query: String,
        vector: [Float]?,
        terms: [String],
        storage: StorageService
    ) async throws {
        let asked = context.askedSourceIDs
        let evidence = Set(snapshot.items.flatMap(\.evidence).compactMap { ref -> String? in
            guard let item = KnowledgeMap.ItemRef(ref), item.kind == .source else { return nil }
            return item.id
        })
        let keptFromAI = try await storage.knowledgeBoundaryExcludedSourceIDs()
        let hits = await storage.searchSources(
            queryText: query,
            queryVector: vector,
            limit: maximumCandidates + asked.count + evidence.count + snapshot.setAsideSourceIDs.count + 20
        )
        var picked: [(id: String, chunk: String?)] = []
        var seen: Set<String> = []
        for hit in hits where picked.count < maximumCandidates {
            let id = hit.sourceId
            guard !asked.contains(id), !evidence.contains(id), !snapshot.setAsideSourceIDs.contains(id),
                  !keptFromAI.contains(id), snapshot.nodes[KnowledgeMap.ItemRef(kind: .source, id: id).description] != nil,
                  seen.insert(id).inserted else { continue }
            picked.append((id, hit.bestChunkId))
        }
        guard !picked.isEmpty else { return }
        let contents = await storage.loadStoredSourceContents(for: picked.map(\.id))
        try Task.checkCancellation()
        for (index, pick) in picked.enumerated() {
            let ref = KnowledgeMap.ItemRef(kind: .source, id: pick.id).description
            guard let node = snapshot.nodes[ref] else { continue }
            // Matched by its words rather than a chunk's meaning: the passage
            // around them says why it came up.
            let passage = bestPassage(
                content: contents[pick.id] ?? "",
                chunkID: pick.chunk,
                terms: terms,
                length: candidatePassageCharacters,
                elseAroundTerms: true
            )
            var passageID: String?
            if !passage.isEmpty {
                passageID = "p\(context.passages.count + 1)"
                context.passages.append(Passage(id: passageID!, ref: ref, text: passage))
            }
            context.candidates.append(Candidate(
                id: "s\(index + 1)",
                sourceID: pick.id,
                title: node.title,
                byline: node.sub,
                type: node.type,
                onCanvas: snapshot.placedRefs.contains(ref),
                passageID: passageID
            ))
        }
    }

    /// The search a Bridge runs and every card's best passage is found by:
    /// the learner's own words first (Ideas' sentences, region names), then
    /// the cards' titles, as long as fits.
    static func searchQuery(for items: [Snapshot.Item]) -> String {
        var parts: [String] = []
        var seen: Set<String> = []
        func add(_ text: String?) {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            parts.append(trimmed)
        }
        for item in items where item.kind == .idea { add(item.title) }
        for item in items { add(item.region) }
        for item in items where item.kind != .idea { add(item.title) }
        var query = ""
        for part in parts {
            let next = query.isEmpty ? part : query + ". " + part
            if next.count > queryCharacters {
                if query.isEmpty { query = String(part.prefix(queryCharacters)) }
                break
            }
            query = next
        }
        return query
    }

    /// A source's passage for the asked words: the chunk the search ranked
    /// best, else the start of its text, or with `elseAroundTerms` the text
    /// around the first of the words it holds.
    static func bestPassage(content: String, chunkID: String?, terms: [String], length: Int, elseAroundTerms: Bool = false) -> String {
        guard !content.isEmpty else { return "" }
        if let chunkID, let index = StorageService.sourceChunkIndex(fromSourceChunkEmbeddingId: chunkID) {
            let chunks = SourceEmbeddingText.textChunks(from: content)
            if index < chunks.count { return excerpt(chunks[index], terms: terms, length: length) }
        }
        return excerpt(content, terms: elseAroundTerms ? terms : [], length: length)
    }

    /// At most `length` characters of `text`, around the first of `terms` it
    /// holds (the longest term first), else from its start; cut ends marked.
    static func excerpt(_ text: String, terms: [String], length: Int) -> String {
        let longestFirst = terms.sorted { $0.count > $1.count }
        // Only a window of a long text is read: around the first of the
        // terms it holds, else its start.
        let raw = text as NSString
        var window = NSRange(location: 0, length: min(raw.length, length * 3))
        for term in longestFirst {
            let found = raw.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            guard found.location != NSNotFound else { continue }
            let start = max(0, found.location - length)
            window = NSRange(location: start, length: min(raw.length - start, length * 3))
            break
        }
        window = raw.rangeOfComposedCharacterSequences(for: window)
        let textBefore = window.location > 0
        let textAfter = window.location + window.length < raw.length
        let flat = normalized(raw.substring(with: window)) as NSString
        guard flat.length > length else {
            guard flat.length > 0 else { return "" }
            return (textBefore ? "…" : "") + (flat as String) + (textAfter ? "…" : "")
        }
        var location = 0
        for term in longestFirst {
            let found = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            if found.location != NSNotFound {
                location = found.location
                break
            }
        }
        let start = min(max(0, location - length / 4), flat.length - length)
        let range = flat.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length))
        var cut = flat.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let cutBefore = range.location > 0 || textBefore
        let cutAfter = range.location + range.length < flat.length || textAfter
        // Whole words at a cut end.
        if cutBefore, let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        if cutAfter, let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return (cutBefore ? "…" : "") + cut + (cutAfter ? "…" : "")
    }

    // MARK: The message

    /// What the model is asked: the tool's instructions, then the Canvas as
    /// JSON (sorted keys, so the same Canvas asks the same way).
    static func message(_ context: Context) -> String {
        func passage(_ id: String?) -> [String: Any]? {
            guard let id, let passage = context.passage(id) else { return nil }
            return ["id": passage.id, "text": passage.text]
        }
        let cards: [[String: Any]] = context.cards.map { card in
            let item = card.item
            var entry: [String: Any] = ["id": card.id, "kind": item.kind.rawValue, "on_canvas": item.placed]
            switch item.kind {
            case .idea:
                entry["sentence"] = item.title
                if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { entry["note"] = note }
                if !card.evidenceTitles.isEmpty { entry["evidence"] = card.evidenceTitles }
            case .source, .doc, .clip, .page, .canvas, .chat, .picture:
                entry["title"] = item.title
                entry["type"] = item.type
                if !item.byline.isEmpty { entry["byline"] = item.byline }
                if let highlight = card.highlight { entry["learner_highlight"] = highlight }
                if let passage = passage(card.passageID) { entry["passage"] = passage }
            }
            if let region = item.region { entry["region"] = region }
            return entry
        }
        var canvas: [String: Any] = ["asked_cards": cards]
        // A source read whole is given as these passages, in order.
        if context.readsWholeSource {
            canvas["source_passages"] = context.passages.map { ["id": $0.id, "text": $0.text] }
        }
        if !context.regions.isEmpty { canvas["regions"] = context.regions }
        if !context.arrows.isEmpty {
            canvas["arrows"] = context.arrows.map { arrow -> [String: Any] in
                var entry: [String: Any] = ["from": arrow.from, "to": arrow.to]
                if !arrow.label.isEmpty { entry["label"] = arrow.label }
                return entry
            }
        }
        if !context.candidates.isEmpty {
            canvas["candidates"] = context.candidates.map { candidate -> [String: Any] in
                var entry: [String: Any] = [
                    "id": candidate.id, "title": candidate.title, "type": candidate.type, "on_canvas": candidate.onCanvas,
                ]
                if !candidate.byline.isEmpty { entry["byline"] = candidate.byline }
                if let passage = passage(candidate.passageID) { entry["passage"] = passage }
                return entry
            }
        }
        if !context.setAside.isEmpty { canvas["set_aside"] = context.setAside }
        let data = (try? JSONSerialization.data(withJSONObject: canvas, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var text = instructions(for: context)
        if !context.setAside.isEmpty {
            text += "\n\n" + Prompts.canvasAskSetAside
        }
        return text + "\n\nThe Canvas:\n" + String(decoding: data, as: UTF8.self)
    }

    /// The task text of the ask; a tree that hangs from the card asked about
    /// tells the model that card is its root.
    static func instructions(for context: Context) -> String {
        switch context.tool {
        case .bridge: return Prompts.canvasAskBridge
        case .connect: return Prompts.canvasAskConnect
        case .gaps: return Prompts.canvasAskGaps
        case .summarize: return Prompts.canvasAskSummarize
        case .breakDown: return Prompts.canvasAskBreakDown
        case .mindMap: return context.rootCard == nil ? Prompts.canvasAskMindMap : Prompts.canvasAskMindMapRooted
        case .questionMap: return context.rootCard == nil ? Prompts.canvasAskQuestionMap : Prompts.canvasAskQuestionMapRooted
        }
    }

    // MARK: The answer

    enum ParseError: LocalizedError {
        case unreadable

        var errorDescription: String? { "The model's answer could not be read." }
    }

    /// Why the context could not be read.
    enum ContextError: LocalizedError {
        /// A source to be read whole (a Break Down, a Mind Map of it) with no
        /// text on this Mac.
        case noText(String)

        var errorDescription: String? {
            switch self {
            case .noText(let title): return "“\(title)” has no text on this Mac to read"
            }
        }
    }

    /// What one reply came to: the proposals, and for a Break Down or a tree
    /// the region and arrows keeping the whole set writes.
    struct Parsed: Equatable, Sendable {
        var answers: [Answer]
        var plan: KnowledgeMapBreakDownPlan?
    }

    /// The proposals in the model's reply, validated against what it was given:
    /// an id it was not given is dropped, and so is everything that leans on
    /// one; counts are capped; lines are cut at a word.
    static func answers(from response: String, context: Context) throws -> [Answer] {
        try parsed(from: response, context: context).answers
    }

    static func parsed(from response: String, context: Context) throws -> Parsed {
        let value = jsonObject(from: response)
        if context.tool == .breakDown || context.tool.drawsTree {
            guard let object = value as? [String: Any] else { throw ParseError.unreadable }
            return context.tool == .breakDown ? breakDownParsed(object, context: context) : treeParsed(object, context: context)
        }
        let list: [[String: Any]]
        if let object = value as? [String: Any], let proposals = object["proposals"] as? [[String: Any]] {
            list = proposals
        } else if let object = value as? [String: Any], context.tool == .summarize, object["title"] != nil {
            // A Summarize may answer with the one Idea itself.
            list = [object]
        } else if let array = value as? [[String: Any]] {
            list = array
        } else {
            throw ParseError.unreadable
        }
        switch context.tool {
        case .bridge: return Parsed(answers: bridgeAnswers(list, context: context), plan: nil)
        case .connect: return Parsed(answers: connectAnswers(list, context: context), plan: nil)
        case .gaps: return Parsed(answers: gapAnswers(list, context: context), plan: nil)
        case .summarize: return Parsed(answers: summarizeAnswers(list, context: context), plan: nil)
        case .breakDown, .mindMap, .questionMap: return Parsed(answers: [], plan: nil)
        }
    }

    private static func bridgeAnswers(_ list: [[String: Any]], context: Context) -> [Answer] {
        let asked = context.askedSourceIDs
        var seen: Set<String> = []
        var answers: [Answer] = []
        for entry in list where answers.count < maximumBridges {
            guard let id = shortID(entry["candidate"]), let candidate = context.candidate(id),
                  !asked.contains(candidate.sourceID), seen.insert(candidate.sourceID).inserted else { continue }
            let why = words(entry["why"] as? String, max: bridgeWhyWords)
            answers.append(Answer(
                proposal: KnowledgeMapProposal(
                    kind: .source,
                    ref: KnowledgeMap.ItemRef(kind: .source, id: candidate.sourceID).description,
                    why: why.isEmpty ? nil : why,
                    near: cardRefs(entry["near"], context: context)
                ),
                cites: passageIDs(entry["cites"], context: context)
            ))
        }
        return answers
    }

    private static func connectAnswers(_ list: [[String: Any]], context: Context) -> [Answer] {
        let placed = Set(context.cards.filter(\.item.placed).map(\.id))
        let joined = Set(context.arrows.map { pairKey($0.from, $0.to) })
        var pairs: Set<String> = []
        var answers: [Answer] = []
        for entry in list where answers.count < maximumArrows {
            guard let from = shortID(entry["from"]), let to = shortID(entry["to"]), from != to,
                  placed.contains(from), placed.contains(to),
                  let fromCard = context.card(from), let toCard = context.card(to) else { continue }
            let key = pairKey(from, to)
            guard !joined.contains(key), pairs.insert(key).inserted else { continue }
            let relation = (entry["relation"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
                .flatMap { relations.contains($0) ? $0 : nil }
            var label = words(
                (entry["label"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.")),
                max: labelWords,
                ellipsis: false
            )
            if label.isEmpty { label = relation?.replacingOccurrences(of: "_", with: " ") ?? "" }
            guard !label.isEmpty else { continue }
            let why = words(entry["why"] as? String, max: arrowWhyWords)
            answers.append(Answer(
                proposal: KnowledgeMapProposal(
                    kind: .edge,
                    from: fromCard.item.ref,
                    to: toCard.item.ref,
                    label: label,
                    relation: relation,
                    why: why.isEmpty ? nil : why,
                    near: [fromCard.item.ref, toCard.item.ref]
                ),
                cites: passageIDs(entry["cites"], context: context)
            ))
        }
        return answers
    }

    private static func gapAnswers(_ list: [[String: Any]], context: Context) -> [Answer] {
        var seen: Set<String> = []
        var answers: [Answer] = []
        for entry in list where answers.count < maximumGaps {
            let question = words(entry["question"] as? String, max: questionWords)
            guard !question.isEmpty, seen.insert(question.lowercased()).inserted else { continue }
            let why = words(entry["why"] as? String, max: gapWhyWords)
            answers.append(Answer(
                proposal: KnowledgeMapProposal(
                    kind: .question,
                    text: question,
                    why: why.isEmpty ? nil : why,
                    near: cardRefs(entry["near"], context: context)
                ),
                cites: passageIDs(entry["cites"], context: context)
            ))
        }
        return answers
    }

    /// A Summarize: the one Idea that sums the asked cards up, a title of at
    /// most `summaryTitleCharacters` and a note of at most `summarySentences`
    /// sentences. The first usable entry is the answer; it is set down beside
    /// the asked cards that are on the canvas, and its note is what the Idea
    /// is written with (the ghost shows the title and the note's first
    /// sentence). Kept like a Gaps question.
    private static func summarizeAnswers(_ list: [[String: Any]], context: Context) -> [Answer] {
        for entry in list {
            let title = cut(entry["title"] as? String, characters: summaryTitleCharacters)
            guard !title.isEmpty else { continue }
            let note = sentences(entry["note"] as? String, max: summarySentences, characters: summaryNoteCharacters)
            let first = sentences(note, max: 1, characters: summaryNoteCharacters)
            let asked = context.cards.filter(\.item.placed).map(\.item.ref)
            return [Answer(
                proposal: KnowledgeMapProposal(
                    kind: .question,
                    text: title,
                    why: first.isEmpty ? nil : words(first, max: questionWords),
                    near: asked.isEmpty ? context.cards.map(\.item.ref) : asked,
                    note: note.isEmpty ? nil : note
                ),
                cites: passageIDs(entry["cites"], context: context)
            )]
        }
        return []
    }

    /// A Break Down: the source's concepts as question proposals (each kept
    /// as an Idea with its one-sentence note) in the order the model gave
    /// them, and the plan: the region named for the source and the arrows
    /// among the concepts. A concept without a title, a title twice, an
    /// arrow to a concept that is not there or between two the model already
    /// joined, and anything past the caps is dropped; fewer than
    /// `minimumConcepts` is no breakdown.
    private static func breakDownParsed(_ object: [String: Any], context: Context) -> Parsed {
        guard let card = context.cards.first, card.item.kind == .source else { return Parsed(answers: [], plan: nil) }
        var answers: [Answer] = []
        var proposalIDs: [String: String] = [:]
        var titles: Set<String> = []
        for entry in object["concepts"] as? [[String: Any]] ?? [] where answers.count < maximumConcepts {
            // The model's key, kept in the ghost's id so arrows can name it.
            let key = idKey(entry["id"])
            guard !key.isEmpty, proposalIDs[key] == nil else { continue }
            let title = words(entry["title"] as? String, max: conceptTitleWords, ellipsis: false)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".;:"))
            guard !title.isEmpty, titles.insert(title.lowercased()).inserted else { continue }
            let note = words(entry["note"] as? String, max: conceptNoteWords)
            let id = "p:" + key
            proposalIDs[key] = id
            answers.append(Answer(
                proposal: KnowledgeMapProposal(
                    id: id,
                    kind: .question,
                    text: title,
                    why: note.isEmpty ? nil : note,
                    near: [card.item.ref],
                    note: note.isEmpty ? nil : note
                ),
                cites: passageIDs(entry["cites"], context: context)
            ))
        }
        guard answers.count >= minimumConcepts else { return Parsed(answers: [], plan: nil) }
        var arrows: [KnowledgeMapBreakDownPlan.Arrow] = []
        var pairs: Set<String> = []
        for entry in object["arrows"] as? [[String: Any]] ?? [] where arrows.count < maximumBreakDownArrows {
            guard let from = shortID(entry["from"]), let to = shortID(entry["to"]), from != to,
                  let fromID = proposalIDs[idKey(from)], let toID = proposalIDs[idKey(to)],
                  pairs.insert(pairKey(fromID, toID)).inserted else { continue }
            let label = words(
                (entry["label"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.")),
                max: labelWords,
                ellipsis: false
            )
            guard !label.isEmpty else { continue }
            arrows.append(.init(from: fromID, to: toID, label: label))
        }
        let name = cut(card.item.title, characters: 80)
        let plan = KnowledgeMapBreakDownPlan(sourceRef: card.item.ref, regionName: name.isEmpty ? "Concepts" : name, arrows: arrows)
        return Parsed(answers: answers, plan: plan)
    }

    /// A Mind Map or a Question Map: the tree's nodes as question proposals
    /// (each kept as an Idea with its one-sentence note), the root first when
    /// the model wrote one, then the nodes in the order it gave them; and the
    /// plan: the branches from parent to child, `tree` set, and `rootRef` the
    /// card asked about when the tree hangs from it. A node is kept only when
    /// its parent is the root (`root`, which the asked card answers to as well
    /// as `c1` when the tree hangs from it) or a node kept before it, so a
    /// dropped node takes with it everything that hung from it. A title the
    /// tree has already, a question that does not end in a question mark
    /// (Question Map), a node past `maximumTreeNodes` or `maximumTreeDepth`
    /// levels is dropped; fewer than `minimumTreeNodes` nodes is no tree.
    private static func treeParsed(_ object: [String: Any], context: Context) -> Parsed {
        guard let asked = context.cards.first?.item.ref else { return Parsed(answers: [], plan: nil) }
        let near = context.cards.map(\.item.ref)
        let hung = context.rootCard
        var titles: Set<String> = []
        var answers: [Answer] = []
        // What the first branches leave from: the asked card, else the root
        // the model wrote (a proposal no branch leads to).
        let rootEnd: String
        let rootTitle: String
        if let hung {
            rootEnd = hung.item.ref
            rootTitle = hung.item.title
            titles.insert(normalized(hung.item.title).lowercased())
        } else {
            guard let root = object["root"] as? [String: Any], let title = treeTitle(root["title"], tool: context.tool) else {
                return Parsed(answers: [], plan: nil)
            }
            rootEnd = "p:root"
            rootTitle = title
            titles.insert(title.lowercased())
            let note = words(root["note"] as? String, max: treeNoteWords)
            answers.append(Answer(
                proposal: KnowledgeMapProposal(id: rootEnd, kind: .question, text: title, near: near, note: note.isEmpty ? nil : note),
                cites: passageIDs(root["cites"], context: context)
            ))
        }
        // The level of each node kept, by the model's key: 1 for a branch.
        var levels: [String: Int] = [:]
        var arrows: [KnowledgeMapBreakDownPlan.Arrow] = []
        for entry in object["nodes"] as? [[String: Any]] ?? [] where arrows.count < maximumTreeNodes {
            // The model's key, kept in the ghost's id so branches can name it.
            let key = idKey(entry["id"])
            guard !key.isEmpty, key != "root", key != hung?.id, levels[key] == nil else { continue }
            let parent = idKey(entry["parent"])
            let level: Int
            let from: String
            if parent == "root" || parent == hung?.id {
                level = 1
                from = rootEnd
            } else if let parentLevel = levels[parent] {
                level = parentLevel + 1
                from = "p:" + parent
            } else {
                continue
            }
            guard level <= maximumTreeDepth, let title = treeTitle(entry["title"], tool: context.tool),
                  titles.insert(title.lowercased()).inserted else { continue }
            let note = words(entry["note"] as? String, max: treeNoteWords)
            levels[key] = level
            arrows.append(.init(from: from, to: "p:" + key, label: ""))
            answers.append(Answer(
                proposal: KnowledgeMapProposal(id: "p:" + key, kind: .question, text: title, near: near, note: note.isEmpty ? nil : note),
                cites: passageIDs(entry["cites"], context: context)
            ))
        }
        guard arrows.count >= minimumTreeNodes else { return Parsed(answers: [], plan: nil) }
        let plan = KnowledgeMapBreakDownPlan(
            sourceRef: asked,
            regionName: cut(rootTitle, characters: 80),
            arrows: arrows,
            tree: true,
            rootRef: hung?.item.ref
        )
        return Parsed(answers: answers, plan: plan)
    }

    /// A tree node's title as the model wrote it: for a Mind Map cut at
    /// `treeTitleWords` words; for a Question Map whole, and nothing when it
    /// is not a question or too long to show.
    private static func treeTitle(_ value: Any?, tool: CanvasAskTool) -> String? {
        var flat = normalized((value as? String) ?? "")
        // A title the model put in quotes.
        if flat.count > 1, let first = flat.first, let last = flat.last, "\"“".contains(first), "\"”".contains(last) {
            flat = String(flat.dropFirst().dropLast())
        }
        if tool == .questionMap {
            guard KnowledgeMap.isQuestion(flat), flat.split(separator: " ").count <= treeQuestionWords else { return nil }
            return flat
        }
        let title = words(flat, max: treeTitleWords, ellipsis: false).trimmingCharacters(in: CharacterSet(charactersIn: ".;:"))
        return title.isEmpty ? nil : title
    }

    /// A model's own id for a concept or a node, safe to keep in a proposal's
    /// id: lower case, letters, digits, `_` and `-`.
    private static func idKey(_ value: Any?) -> String {
        (shortID(value) ?? "").filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// An id as the model wrote it: trimmed, lower case.
    private static func shortID(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
        return text
    }

    private static func ids(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap(shortID) }
        return shortID(value).map { [$0] } ?? []
    }

    /// The asked cards an answer names, by ref, each once.
    private static func cardRefs(_ value: Any?, context: Context) -> [String] {
        var refs: [String] = []
        for id in ids(value) {
            guard let card = context.card(id), !refs.contains(card.item.ref) else { continue }
            refs.append(card.item.ref)
        }
        return refs
    }

    private static func passageIDs(_ value: Any?, context: Context) -> [String] {
        var cited: [String] = []
        for id in ids(value) where context.passage(id) != nil && !cited.contains(id) && cited.count < 3 {
            cited.append(id)
        }
        return cited
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? a + "|" + b : b + "|" + a
    }

    // MARK: Text

    /// Whitespace collapsed to single spaces, ends trimmed.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` flattened and cut to at most `characters` characters at a word,
    /// marked … when cut.
    static func cut(_ text: String?, characters: Int) -> String {
        let flat = normalized(text ?? "")
        guard flat.count > characters else { return flat }
        var kept = String(flat.prefix(max(1, characters - 1)))
        if let space = kept.lastIndex(of: " ") { kept = String(kept[..<space]) }
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: ",;:—–- ")) + "…"
    }

    /// The first `max` sentences of `text`, flattened, at most `characters`
    /// characters (cut at a word, marked …).
    static func sentences(_ text: String?, max: Int, characters: Int) -> String {
        let flat = normalized(text ?? "")
        guard !flat.isEmpty else { return "" }
        var kept: [String] = []
        (flat as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (flat as NSString).length), options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { kept.append(sentence) }
            if kept.count >= max { stop.pointee = true }
        }
        return cut(kept.joined(separator: " "), characters: characters)
    }

    /// A source's text as passages spread evenly from its start to its end,
    /// so a Break Down reads the whole of it and not only its opening.
    static func spreadPassages(
        from content: String,
        count: Int = breakDownPassageCount,
        characters: Int = breakDownPassageCharacters
    ) -> [String] {
        let chunks = SourceEmbeddingText.textChunks(from: content)
        guard !chunks.isEmpty, count > 0 else { return [] }
        let picks: [Int]
        if chunks.count <= count {
            picks = Array(chunks.indices)
        } else if count == 1 {
            picks = [0]
        } else {
            picks = (0..<count).map { Int((Double($0) * Double(chunks.count - 1) / Double(count - 1)).rounded()) }
        }
        var seen: Set<Int> = []
        return picks
            .filter { seen.insert($0).inserted }
            .map { excerpt(chunks[$0], terms: [], length: characters) }
            .filter { !$0.isEmpty }
    }

    /// `text` cut to at most `max` words, marked … when cut.
    static func words(_ text: String?, max: Int, ellipsis: Bool = true) -> String {
        let flat = normalized(text ?? "")
        guard !flat.isEmpty else { return "" }
        let parts = flat.split(separator: " ")
        guard parts.count > max else { return flat }
        let kept = parts.prefix(max).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:—–-"))
        return ellipsis ? kept + "…" : kept
    }

    /// The JSON value in a reply, tolerating a fenced block or prose around it.
    static func jsonObject(from response: String) -> Any? {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return value }
        for (open, close) in [("{", "}"), ("[", "]")] {
            guard let start = text.firstIndex(of: Character(open)),
                  let end = text.lastIndex(of: Character(close)), start < end else { continue }
            if let value = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) { return value }
        }
        return nil
    }
}

extension AIService {
    /// Asks the model one Canvas question; the proposals it gave, validated.
    /// A reply that cannot be read is no answer: it is not cached, and the
    /// next backup model is asked.
    func canvasAsk(_ context: CanvasAskService.Context, config: AITaskConfig) async throws -> CanvasAskService.Parsed {
        let system = AITask.canvasAsk.effectivePrompt ?? Prompts.canvasAsk
        let response = try await call(
            config: config,
            system: system,
            user: CanvasAskService.message(context),
            // A Break Down writes a dozen concepts and their arrows, a tree up
            // to thirty nodes with a note each; a Summarize one title and a
            // few sentences.
            maxTokens: context.tool.drawsTree ? 3600 : context.tool == .breakDown ? 2800 : context.tool == .summarize ? 800 : 1400,
            temperature: context.tool == .connect ? 0.3 : (context.tool == .summarize || context.tool == .breakDown || context.tool.drawsTree ? 0.4 : 0.6),
            jsonMode: true,
            validateResponse: { response in _ = try CanvasAskService.parsed(from: response, context: context) },
            sourceTitle: "Canvas",
            subjectID: "map"
        )
        do {
            return try CanvasAskService.parsed(from: response, context: context)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
