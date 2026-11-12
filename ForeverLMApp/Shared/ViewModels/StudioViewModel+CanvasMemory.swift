import Foundation

// MARK: - Memory on the Canvas (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// Three things the Canvas does with Memory, on the Mac:
//
// - **The Memory layer.** Each card the Canvas can draw carries a mark of the
//   kept cards anchored to its sources — a source card its own, an Idea its
//   evidence's, a Doc its citations' — and how they stand today
//   (`CanvasMemoryMarks`). Read in one read of the kept cards, off the main
//   actor, when the Canvas opens, when the cards change and after each answer.
// - **Review Here.** The kept cards behind the selected cards, dealt as the
//   card review deals practice (`MemoryCardSitting`, `MemoryCardSessionModel`:
//   the same writes, so generation 2's Sitting records stay right), and asked
//   in place: the Canvas flies to each card and the question floats beside it
//   (`KnowledgeMapCanvasView+Memory.swift`).
// - **Make Cards** from the learner's own Ideas and arrows
//   (`SituatedCardDrafter`), into To Check. Sources selected alone go to the
//   source Make Cards the Reader's button opens.

/// What Make Cards on the Canvas drafts from: the anchors, and why some
/// selected cards gave none.
struct KnowledgeMapCardAnchors: Sendable {
    var anchors: [SituatedAnchor] = []
    /// For each anchor, the queries its passages are searched with, one per
    /// group of its sources: an arrow's two ends are searched apart, so both
    /// stand in its passages.
    var passageSearches: [[KnowledgeMapPassageSearch]] = []
    /// Sources selected with no Idea or arrow: the source Make Cards takes them.
    var sourceIDs: [String] = []
    var ideasWithoutEvidence = 0
    var arrowsWithoutSources = 0
}

struct KnowledgeMapPassageSearch: Sendable {
    let query: String
    let sourceIDs: [String]
}

/// What Make Cards on the Canvas did.
struct KnowledgeMapCardsResult: Sendable {
    /// Nil when the selection went to the source Make Cards instead.
    var report: SituatedCardDrafter.Report?
    /// The sources handed to the source Make Cards (the Reader's sheet).
    var sourceIDsForSourceMakeCards: [String] = []
    var ideasWithoutEvidence = 0
    var arrowsWithoutSources = 0
}

extension StudioViewModel {

    // MARK: The Memory layer

    /// How the kept cards anchored to each source stand today, by the id
    /// asked for (`memoryMarks(forSourceIDs:)`, which the Atlas reads too). A
    /// team's copy counts the cards on the learner's own source.
    func canvasMemoryMarks(forSourceIDs sourceIDs: [String]) async -> [String: KnowledgeMapMemoryMark] {
        var groups: [String: Set<String>] = [:]
        for raw in sourceIDs {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            groups[id] = [id, canonicalSourceID(id)]
        }
        guard !groups.isEmpty else { return [:] }
        do {
            return try await storage.canvasMemoryMarks(for: groups)
        } catch {
            logger.error("Memory marks could not be read: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Every Canvas card's mark, read again while the layer shows or a review
    /// runs. A failed read leaves the last marks standing rather than
    /// inventing none; it is logged.
    func refreshKnowledgeMapMemory(for model: KnowledgeMapModel? = nil) async {
        let knowledgeMap = model ?? self.knowledgeMap
        let memory = knowledgeMap.memory
        guard memory.isShown || memory.review != nil else { return }
        let groups = CanvasMemoryMarks.refSources(content: knowledgeMap.content) { self.canonicalSourceID($0) }
        let request = memory.beginRead()
        do {
            let marks = try await storage.canvasMemoryMarks(for: groups)
            memory.finishRead(request, marks: marks)
        } catch {
            logger.error("Canvas memory marks could not be read: \(error.localizedDescription)")
        }
    }

    /// The sources behind a Canvas card, as the learner's cards stand on
    /// them: a source card its own, an Idea its evidence, a Doc the sources
    /// it cites; a team's copy resolved to the learner's own source.
    func knowledgeMapSourceIDs(behind ref: String) -> [String] {
        guard let item = KnowledgeMap.ItemRef(ref) else { return [] }
        var ids: [String]
        switch item.kind {
        case .source:
            ids = [item.id]
        case .idea, .doc, .clip, .page:
            // A clip, or a page, stands on the source it was cut from.
            let kind = item.kind == .idea ? "idea" : item.kind == .doc ? "doc" : "clip"
            ids = knowledgeMap.content.links
                .filter { $0.kind == kind && $0.a == ref }
                .compactMap { KnowledgeMap.ItemRef($0.b) }
                .filter { $0.kind == .source }
                .map(\.id)
        case .canvas, .chat, .picture:
            // A shortcut, a chat and a picture stand on no source of their own.
            ids = []
        }
        var seen = Set<String>()
        return ids.map { canonicalSourceID($0) }.filter { seen.insert($0).inserted }
    }

    // MARK: Review in place

    /// Review Here (`canvasReviewHere(refs:)`): the kept cards anchored to the
    /// sources behind `refs` — a source's own, an Idea's evidence, a Doc's
    /// citations — dealt as `CanvasReviewDeal` deals them (the due ones, else
    /// a practice of the weakest), asked as a tour of the Canvas. A sitting of
    /// the card review's own, as learner-started practice: storage writes an
    /// answer only for a card due or never answered, so nothing stretches an
    /// interval. With no kept card behind the selection a toast offers Make
    /// Cards.
    func startKnowledgeMapReview(refs: [String]) {
        let map = knowledgeMap
        let memory = map.memory
        guard memory.review == nil, !memory.isStartingReview else { return }
        var seen = Set<String>()
        let asked = refs.filter { seen.insert($0).inserted }
        // A card's anchor is its source's own card when that was asked, else
        // the first Idea or Doc it hangs under.
        let preferred = asked.filter { KnowledgeMap.ItemRef($0)?.kind == .source }
            + asked.filter { KnowledgeMap.ItemRef($0)?.kind != .source }
        let groups = preferred
            .map { (ref: $0, sourceIDs: Set(knowledgeMapSourceIDs(behind: $0))) }
            .filter { !$0.sourceIDs.isEmpty }
        let scope = groups.reduce(into: Set<String>()) { $0.formUnion($1.sourceIDs) }
        guard !scope.isEmpty else {
            knowledgeMapNoCardsYet(refs: asked)
            return
        }
        var positions: [String: (x: Double, y: Double)] = [:]
        for group in groups {
            if let spot = map.layout.placements[group.ref] { positions[group.ref] = (spot.x, spot.y) }
        }
        // The window whose Canvas this is runs the review.
        let window = window(showing: map) ?? activeWindowState
        let now = Date()
        memory.isStartingReview = true
        Task { [weak self] in
            defer { memory.isStartingReview = false }
            guard let self else { return }
            do {
                let read = try await self.storage.canvasMemoryRead(anchoredOn: scope)
                let anchors = CanvasReviewDeal.anchors(items: read.items, refs: groups)
                let dealt = CanvasReviewDeal.deal(
                    items: read.items,
                    attempts: read.attempts,
                    anchors: anchors,
                    positions: positions,
                    now: now
                )
                let cards = self.memorySittingCards(
                    dealt.entries,
                    attemptsByItemID: Dictionary(grouping: read.attempts, by: \.memoryItemID)
                )
                guard !cards.isEmpty else {
                    self.knowledgeMapNoCardsYet(refs: asked)
                    return
                }
                guard memory.review == nil else { return }
                let session = MemoryCardSessionModel(
                    sitting: MemoryCardSitting(
                        key: MemoryCardSitting.newKey(day: MemoryReviewGoal.dayKey(for: now)),
                        kind: .practice,
                        cards: cards
                    ),
                    scope: .allNotebooks,
                    scopeTitle: "Canvas",
                    isCommitted: false,
                    sourceTitles: self.knowledgeMapReviewSourceTitles(cards),
                    storage: self.storage,
                    // A review in place deals what it was asked on and nothing after it.
                    followup: { MemoryCardSessionModel.Followup(cards: [], dayHasCardsLeft: true) },
                    answerCheck: self.memoryCardAnswerCheck()
                )
                memory.begin(KnowledgeMapReview(session: session, kind: dealt.kind, anchors: dealt.anchors, windowID: window.id))
            } catch {
                self.showToast("The cards behind these could not be read. \(error.localizedDescription)")
            }
        }
    }

    private func knowledgeMapNoCardsYet(refs: [String]) {
        showToast(
            "No cards on these yet \u{2014} Make Cards first",
            action: StudioToastAction(title: "Make Cards") { [weak self] _ in
                self?.canvasMakeCards(refs: refs, edgeIDs: [])
            }
        )
    }

    private func knowledgeMapReviewSourceTitles(_ cards: [MemoryCardSitting.Card]) -> [String: String] {
        var titles: [String: String] = [:]
        for case let sourceID? in cards.map(\.sourceID) where titles[sourceID] == nil {
            if let title = articlesById[canonicalSourceID(sourceID)]?.title, !title.isEmpty {
                titles[sourceID] = title
            }
        }
        return titles
    }

    /// Check (Return) on the card asked: the learner's answer, typed or
    /// dictated, turns it. A blank answer turns nothing.
    func checkKnowledgeMapReviewAnswer() {
        knowledgeMap.memory.review?.session.checkAttempt()
    }

    /// Show Answer on the card asked: its back shows with nothing typed, and
    /// the learner grades themselves.
    func showKnowledgeMapReviewAnswerUnanswered() {
        knowledgeMap.memory.review?.session.showAnswerUnanswered()
    }

    /// Return once the check's verdict is in: the grade it suggests.
    func confirmKnowledgeMapReviewVerdict() {
        guard let remembered = knowledgeMap.memory.review?.session.sitting.verdictRemembers else { return }
        answerKnowledgeMapReview(remembered: remembered)
    }

    /// Forgot or Remembered on the card asked, once its back shows: written
    /// through the sitting as the card review writes it, then the marks are
    /// read again.
    func answerKnowledgeMapReview(remembered: Bool) {
        let map = knowledgeMap
        guard let review = map.memory.review, review.session.sitting.isAnswerShown else { return }
        let previous = review.focusRef
        review.session.answer(remembered: remembered)
        review.cardChanged(from: previous)
        let session = review.session
        Task { [weak self] in
            await session.waitForWrites()
            await self?.refreshKnowledgeMapMemory(for: map)
        }
    }

    /// Again for the round's forgotten cards: asked again, nothing written.
    func againKnowledgeMapReview() {
        knowledgeMap.memory.review?.againForForgotten()
    }

    /// Done, Escape or ×: the Canvas comes back as it was, and once the
    /// answers have landed the counts and the marks are read again.
    func endKnowledgeMapReview() {
        let map = knowledgeMap
        guard let review = map.memory.end() else { return }
        cardSessionDidEnd(review.session)
        Task { [weak self] in
            await review.session.waitForWrites()
            await self?.refreshKnowledgeMapMemory(for: map)
        }
    }

    /// Ends a review whose window no longer shows the Canvas — closed, or
    /// showing something else in its place — so no Canvas is left dimmed
    /// with no question beside it.
    func endKnowledgeMapReviewIfStranded() {
        guard let review = knowledgeMap.memory.review else { return }
        let window = allWindowStates.first { $0.id == review.windowID }
        let showsCanvas = window?.centerTabGroups.groups.contains { $0.activeTab == .knowledgeMap } ?? false
        if !showsCanvas { endKnowledgeMapReview() }
    }

    /// The question's source chip: the Reader beside the Canvas, at the
    /// passage the card quotes. The review goes on, and the Canvas flies to
    /// the card again in the room it has left.
    func openKnowledgeMapReviewSource(_ sourceID: String, quote: String?, in windowState: StudioWindowState) async {
        let id = canonicalSourceID(sourceID)
        guard articlesById[id] != nil, await openSourceBesideChat(id, beside: .knowledgeMap, in: windowState) else {
            showToast("Source not found in library")
            return
        }
        requestReaderPassage(quote, for: id, in: windowState)
        knowledgeMap(in: windowState).memory.review?.refocus()
    }

    // MARK: Cards from what the learner made sense of

    /// Make Cards on the Canvas (`canvasMakeCards(refs:edgeIDs:)`), from the
    /// inspector's button: drafted in the background and announced in a
    /// toast whose Show opens To Check beside the Canvas.
    func startKnowledgeMapCards(refs: [String], edgeIDs: [String]) {
        let memory = knowledgeMap.memory
        guard !memory.isMakingCards else {
            showToast("Cards are being drafted from the Canvas already")
            return
        }
        let plan = knowledgeMapCardAnchors(refs: refs, edgeIDs: edgeIDs)
        guard !plan.anchors.isEmpty else {
            _ = knowledgeMapHandOff(plan)
            return
        }
        memory.isMakingCards = true
        showToast("Drafting cards from \(Self.knowledgeMapAnchorsPhrase(plan.anchors))\u{2026}")
        Task { [weak self] in
            defer { memory.isMakingCards = false }
            guard let self else { return }
            do {
                let report = try await self.draftKnowledgeMapCards(plan)
                self.announceKnowledgeMapCards(report)
            } catch {
                self.showToast(error is CancellationError ? "Stopped making cards" : error.localizedDescription)
            }
        }
    }

    /// "2 ideas and 1 arrow", what a Make Cards on the Canvas drafts from.
    nonisolated static func knowledgeMapAnchorsPhrase(_ anchors: [SituatedAnchor]) -> String {
        let ideas = anchors.filter { $0.kind != .relation }.count
        let arrows = anchors.count - ideas
        var parts: [String] = []
        if ideas > 0 { parts.append(ideas == 1 ? "1 idea" : "\(ideas) ideas") }
        if arrows > 0 { parts.append(arrows == 1 ? "1 arrow" : "\(arrows) arrows") }
        return parts.joined(separator: " and ")
    }

    /// Make Cards as `make_cards_from_canvas` runs it: the same anchors and
    /// drafting, awaited. A selection of sources alone goes to the source
    /// Make Cards (a chat, in the app; `draft_cards`, for an assistant).
    func makeKnowledgeMapCards(refs: [String], edgeIDs: [String], presentingSourceSheet: Bool) async throws -> KnowledgeMapCardsResult {
        let plan = knowledgeMapCardAnchors(refs: refs, edgeIDs: edgeIDs)
        var result = KnowledgeMapCardsResult(
            ideasWithoutEvidence: plan.ideasWithoutEvidence,
            arrowsWithoutSources: plan.arrowsWithoutSources
        )
        guard !plan.anchors.isEmpty else {
            result.sourceIDsForSourceMakeCards = plan.sourceIDs
            if presentingSourceSheet { _ = knowledgeMapHandOff(plan) }
            return result
        }
        let memory = knowledgeMap.memory
        memory.isMakingCards = true
        defer { memory.isMakingCards = false }
        result.report = try await draftKnowledgeMapCards(plan)
        return result
    }

    /// A selection with no Idea or arrow to draft from: its sources go to
    /// the Reader's Write Card, one source after another
    /// (`requestWriteCards`); with none, a toast says what is missing. True
    /// when the writing was opened.
    private func knowledgeMapHandOff(_ plan: KnowledgeMapCardAnchors) -> Bool {
        if !plan.sourceIDs.isEmpty {
            requestWriteCards(notebookID: nil, sourceIDs: plan.sourceIDs)
            return true
        }
        if plan.ideasWithoutEvidence > 0 || plan.arrowsWithoutSources > 0 {
            showToast("A card stands on a passage of a source: drop a source on the idea first")
        } else {
            showToast("Select an idea, an arrow or a source to make cards from")
        }
        return false
    }

    /// The anchors of the selection: each Idea with evidence (its sentence,
    /// its note, the region it sits in, its evidence sources), each arrow
    /// whose two ends have sources ("A — label → B", the sources of both), and
    /// the sources selected, which give no anchor of their own.
    func knowledgeMapCardAnchors(refs: [String], edgeIDs: [String]) -> KnowledgeMapCardAnchors {
        let map = knowledgeMap
        var plan = KnowledgeMapCardAnchors()
        var seen = Set<String>()
        for ref in refs where seen.insert(ref).inserted {
            guard let item = KnowledgeMap.ItemRef(ref) else { continue }
            switch item.kind {
            case .source:
                let id = canonicalSourceID(item.id)
                if !plan.sourceIDs.contains(id) { plan.sourceIDs.append(id) }
            case .doc, .clip, .page, .canvas, .chat, .picture:
                continue
            case .idea:
                guard let idea = ideas.first(where: { $0.id == item.id }) else { continue }
                let sources = knowledgeMapSourceIDs(behind: ref)
                guard !sources.isEmpty else {
                    plan.ideasWithoutEvidence += 1
                    continue
                }
                var context: [String] = []
                if let note = idea.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    context.append("The learner's note on it: " + note)
                }
                if let region = knowledgeMapRegionName(holding: ref) {
                    context.append("On their Canvas it sits in the region \u{201C}\(region)\u{201D}.")
                }
                plan.anchors.append(SituatedAnchor(
                    kind: .idea,
                    text: idea.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: context.isEmpty ? nil : context.joined(separator: "\n"),
                    sourceIDs: sources
                ))
                plan.passageSearches.append([KnowledgeMapPassageSearch(query: idea.title, sourceIDs: sources)])
            }
        }
        var seenEdges = Set<String>()
        for id in edgeIDs where seenEdges.insert(id).inserted {
            guard let edge = map.layout.edges[id] else { continue }
            let from = knowledgeMapSourceIDs(behind: edge.from)
            let to = knowledgeMapSourceIDs(behind: edge.to)
            guard !from.isEmpty, !to.isEmpty else {
                plan.arrowsWithoutSources += 1
                continue
            }
            let a = map.title(of: edge.from)
            let b = map.title(of: edge.to)
            let label = edge.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = label.isEmpty ? "\(a) \u{2192} \(b)" : "\(a) \u{2014} \(label) \u{2192} \(b)"
            var sourceSeen = Set<String>()
            let sources = (from + to).filter { sourceSeen.insert($0).inserted }
            let query = [label, a, b].filter { !$0.isEmpty }.joined(separator: " ")
            var context: [String] = []
            if let region = knowledgeMapRegionName(holding: edge.from) ?? knowledgeMapRegionName(holding: edge.to) {
                context.append("On their Canvas it runs in the region \u{201C}\(region)\u{201D}.")
            }
            plan.anchors.append(SituatedAnchor(
                kind: .relation,
                text: text,
                context: context.isEmpty ? nil : context.joined(separator: "\n"),
                sourceIDs: sources
            ))
            plan.passageSearches.append([
                KnowledgeMapPassageSearch(query: query, sourceIDs: from),
                KnowledgeMapPassageSearch(query: query, sourceIDs: to),
            ])
        }
        // Sources go to the source Make Cards only when nothing else was
        // selected to draft from: beside an Idea they are its context.
        if !plan.anchors.isEmpty { plan.sourceIDs = [] }
        return plan
    }

    private func knowledgeMapRegionName(holding ref: String) -> String? {
        let map = knowledgeMap
        guard let id = map.regionID(containing: ref) else { return nil }
        if let notebook = map.notebook(ofRegion: id) { return notebook.title }
        let name = map.layout.regions[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The anchors' passages, searched in their sources, then drafted.
    private func draftKnowledgeMapCards(_ plan: KnowledgeMapCardAnchors) async throws -> SituatedCardDrafter.Report {
        var anchors = plan.anchors
        for index in anchors.indices {
            try Task.checkCancellation()
            let searches = index < plan.passageSearches.count ? plan.passageSearches[index] : []
            anchors[index].passages = await situatedPassages(searches)
        }
        return try await SituatedCardDrafter.draftReport(anchors, studio: self)
    }

    /// What drafting did, in a toast; Show opens To Check beside the Canvas.
    private func announceKnowledgeMapCards(_ report: SituatedCardDrafter.Report) {
        guard report.drafted > 0 else {
            showToast(report.nothingDraftedMessage)
            return
        }
        showToast(report.summary, action: StudioToastAction(title: "Show") { [weak self] window in
            self?.openCardsToCheckBesideCanvas(in: window)
        })
    }

    /// To Check over every notebook, beside the Canvas when the window shows
    /// it, else where Memory opens.
    func openCardsToCheckBesideCanvas(in window: StudioWindowState?) {
        let destination = window ?? activeWindowState
        guard destination.centerTabGroups.groups.contains(where: { $0.tabs.contains(.knowledgeMap) }) else {
            openCardsToCheck(scope: .allNotebooks, in: destination)
            return
        }
        if destination.memoryPaneScope != .allNotebooks { destination.memoryPaneScope = .allNotebooks }
        if destination.memoryPaneSection != .toCheck { destination.memoryPaneSection = .toCheck }
        revealCenterTab(.memory, beside: .knowledgeMap, in: destination)
    }

    // MARK: Passages

    /// The passages that bear on `searches`: for each, its sources' best
    /// passages for its query (`StorageService.searchSources`, the hybrid
    /// search, restricted to them, so a source kept from AI never gives
    /// one), cut from each source's stored text to about 600 characters
    /// around what matched. At most `limit` in all, shared across the
    /// searches so each gives some.
    func situatedPassages(_ searches: [KnowledgeMapPassageSearch], limit: Int = 4) async -> [SituatedPassage] {
        let searches = searches.filter { !$0.sourceIDs.isEmpty && !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !searches.isEmpty else { return [] }
        let share = max(1, Int((Double(limit) / Double(searches.count)).rounded(.up)))
        var passages: [SituatedPassage] = []
        var used = Set<String>()
        for search in searches {
            guard passages.count < limit else { break }
            let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let vector: [Float]?
            do {
                vector = try await aiService.embedText(query)
            } catch {
                // The lexical branch still finds a passage that names it.
                logger.error("A passage search could not embed its words; searching by text: \(error.localizedDescription)")
                vector = nil
            }
            let hits = await storage.searchSources(
                queryText: query,
                queryVector: vector,
                limit: max(search.sourceIDs.count, 1),
                restrictedTo: Set(search.sourceIDs)
            )
            var texts: [String: String] = [:]
            var usedChunks = Set<String>()
            var taken = 0
            func take(_ sourceID: String, chunkID: String?) async {
                guard taken < share, passages.count < limit else { return }
                if let chunkID, !usedChunks.insert(chunkID).inserted { return }
                if texts[sourceID] == nil {
                    guard let text = await loggedLookup("source text", { try await storage.situatedSourceText(sourceID) }) else { return }
                    texts[sourceID] = text
                }
                guard let text = texts[sourceID] else { return }
                let chunks = SourceEmbeddingText.textChunks(from: text)
                var passageText = text
                if let chunkID, let index = StorageService.sourceChunkIndex(fromSourceChunkEmbeddingId: chunkID), index < chunks.count {
                    passageText = chunks[index]
                }
                let excerpt = SituatedPassageCutter.excerpt(passageText, query: query)
                guard !excerpt.isEmpty, used.insert(excerpt).inserted else { return }
                passages.append(SituatedPassage(sourceID: sourceID, text: excerpt))
                taken += 1
            }
            // Each source's best passage first, the best source first.
            for hit in hits { await take(hit.sourceId, chunkID: hit.bestChunkId) }
            // Room left: the next nearest passages of the sources the search
            // found (never another source, so one kept from AI stays out).
            if taken < share, let vector {
                let found = Set(hits.map(\.sourceId))
                for chunk in await storage.findSimilarSourceChunks(queryVector: vector, topK: 200) where found.contains(chunk.sourceId) {
                    await take(chunk.sourceId, chunkID: chunk.chunkId)
                }
            }
        }
        return passages
    }
}

/// A passage cut to a length a prompt carries: the stretch around the first
/// word of the query it holds (the longest word first), on whole words, so a
/// quote copied from it is found in its source again (`MemoryGroundingText`
/// matches whole words).
enum SituatedPassageCutter {
    static let defaultLength = 600

    static func excerpt(_ passage: String, query: String, maxLength: Int = defaultLength) -> String {
        let words = passage.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "" }
        let whole = words.joined(separator: " ")
        guard whole.count > maxLength else { return whole }
        let terms = SourceSearchEngine.searchTerms(for: query).sorted { $0.count > $1.count }
        let lowered = words.map { $0.lowercased() }
        let hit = terms.lazy.compactMap { term in lowered.firstIndex { $0.contains(term) } }.first ?? 0
        // Start a little before the word that matched, and keep whole words.
        var start = hit
        var leading = 0
        while start > 0, leading + words[start - 1].count + 1 <= maxLength / 3 {
            start -= 1
            leading += words[start].count + 1
        }
        var end = start
        var length = 0
        while end < words.count, length + words[end].count + (length == 0 ? 0 : 1) <= maxLength {
            length += words[end].count + (length == 0 ? 0 : 1)
            end += 1
        }
        return words[start..<max(end, start + 1)].joined(separator: " ")
    }
}
