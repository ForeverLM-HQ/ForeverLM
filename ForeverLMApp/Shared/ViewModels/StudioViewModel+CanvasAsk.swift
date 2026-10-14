import Foundation

// MARK: - Ask the Canvas (WP-B1, docs/sensemaking-design.md)
//
// The inspector's Ask (Bridge, Connect, Gaps, Summarize, Break Down, a Mind Map
// and a Question Map), the chat's Make a Mind Map, and `ask_canvas` over MCP
// (Bridge, Connect and Gaps). One Ask at a time: a new one stops the one
// running. Its answer replaces the proposals showing; nothing is written
// until the learner keeps a proposal (`KnowledgeMapModel+Proposals.swift`).

extension StudioViewModel {
    /// Why an Ask was not started.
    enum CanvasAskRefusal: LocalizedError, Equatable {
        case lensShowing
        case noCards
        case needsTwoPlacedCards
        /// A Break Down needs exactly one source.
        case needsOneSource
        case notSetUp(String)

        var errorDescription: String? {
            switch self {
            case .lensShowing: return "Back to My Canvas first"
            case .noCards: return "Select cards on the canvas to ask about"
            case .needsTwoPlacedCards: return "Connect needs at least two cards placed on the canvas"
            case .needsOneSource: return "Break Down takes one source: select a paper, article or talk"
            case .notSetUp(let message): return message
            }
        }
    }

    /// The inspector's Ask: the answer arrives as proposals on the plane, a
    /// refusal or failure in the toast.
    func startCanvasAsk(_ tool: CanvasAskTool, refs: [String]) {
        do {
            try beginCanvasAsk(tool, refs: refs)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Starts `tool` over `refs` and returns the running Ask; throws when it
    /// is refused. Its answer replaces the proposals showing; a failure is
    /// shown in the toast as well as thrown to whoever awaits it.
    @discardableResult
    func beginCanvasAsk(_ tool: CanvasAskTool, refs: [String]) throws -> Task<CanvasAskService.Result, Error> {
        let map = knowledgeMap
        guard map.lens == nil else { throw CanvasAskRefusal.lensShowing }
        let snapshot = try canvasAskSnapshot(tool, refs: refs)
        guard let config = KeychainService.resolveConfig(for: .canvasAsk) else {
            throw CanvasAskRefusal.notSetUp(
                KeychainService.backgroundAIUnavailableMessage(for: .canvasAsk)
                    ?? "Set up AI in Settings to ask the canvas"
            )
        }
        stopCanvasAsk()
        map.clearProposals()
        map.askState.serial &+= 1
        let serial = map.askState.serial
        map.asking = tool
        let storage = storage
        let ai = aiService
        let task = Task<CanvasAskService.Result, Error> { [weak self] in
            defer {
                if map.askState.serial == serial {
                    map.asking = nil
                    map.askState.task = nil
                }
            }
            do {
                let context = try await CanvasAskService.context(for: snapshot, storage: storage, ai: ai)
                try Task.checkCancellation()
                let parsed = try await ai.canvasAsk(context, config: config)
                let answers = parsed.answers
                try Task.checkCancellation()
                guard map.askState.serial == serial else { throw CancellationError() }
                let set = KnowledgeMapProposalSet(
                    id: UUID().uuidString.lowercased(),
                    tool: tool,
                    title: tool.title,
                    anchor: snapshot.items.map(\.ref),
                    proposals: answers.map(\.proposal),
                    createdAt: Date(),
                    plan: parsed.plan
                )
                if set.proposals.isEmpty {
                    self?.showToast("\(tool.title) found nothing to propose for these cards")
                } else if !map.showProposals(set, makeIdea: { [weak self] text, spot in
                    await self?.keepCanvasQuestion(text, at: spot)
                }, writeIdea: { [weak self] text, note, spot in
                    guard let self else { return nil }
                    if let spot { return await self.keepCanvasQuestion(text, note: note, at: spot) }
                    // A Break Down writes a dozen: the pane reads the cards
                    // once for all of them, as the Ideas list changes.
                    return await self.createCanvasIdea(title: text, note: note, refreshesContent: false)
                }) {
                    self?.showToast("A lens is showing: Back to My Canvas, then ask again")
                }
                return CanvasAskService.Result(set: set, answers: answers, context: context)
            } catch {
                if !(error is CancellationError), !Task.isCancelled, map.askState.serial == serial {
                    self?.logger.error("Ask the Canvas failed: \(error.localizedDescription)")
                    self?.showToast("Could not ask the canvas: \(error.localizedDescription)")
                }
                throw error
            }
        }
        map.askState.task = task
        return task
    }

    /// Whether a source has text on this Mac for a Break Down to read. A
    /// loaded row carries no text until it is hydrated, so the word count
    /// the library keeps is the signal too.
    func knowledgeMapSourceHasText(_ sourceID: String) -> Bool {
        guard let article = articlesById[canonicalSourceID(sourceID)] else { return false }
        return (article.wordCount ?? 0) > 0 || Self.sourceHasReadableContent(article)
    }

    /// Stops the Ask running, if any: its answer is dropped when it arrives.
    func stopCanvasAsk() {
        let map = knowledgeMap
        map.askState.task?.cancel()
        map.askState.task = nil
        map.askState.serial &+= 1
        map.asking = nil
    }

    /// The asked cards as the Canvas holds them, in one cheap pass on the main
    /// actor: Ideas first, then the cards on the plane, then the rest, at most
    /// `CanvasAskService.maximumCards`. A Mind Map or Question Map takes any
    /// 1 to 24 of them; when the one card is an Idea on the canvas the tree
    /// hangs from it (`CanvasAskService.Context.rootCard`).
    func canvasAskSnapshot(_ tool: CanvasAskTool, refs: [String]) throws -> CanvasAskService.Snapshot {
        let map = knowledgeMap
        var seen: Set<String> = []
        let known = refs.filter { map.nodesByRef[$0] != nil && seen.insert($0).inserted }
        guard !known.isEmpty else { throw CanvasAskRefusal.noCards }
        let placed = Set(map.layout.placements.keys)
        if tool == .connect, known.filter(placed.contains).count < 2 { throw CanvasAskRefusal.needsTwoPlacedCards }
        if tool == .breakDown, known.count != 1 || KnowledgeMap.ItemRef(known[0])?.kind != .source {
            throw CanvasAskRefusal.needsOneSource
        }
        let isIdea: (String) -> Bool = { $0.hasPrefix(KnowledgeMap.ItemKind.idea.rawValue + ":") }
        let ordered = known.filter(isIdea)
            + known.filter { !isIdea($0) && placed.contains($0) }
            + known.filter { !isIdea($0) && !placed.contains($0) }
        let chosen = Array(ordered.prefix(CanvasAskService.maximumCards))
        let notes = Dictionary(ideas.map { ($0.id, $0.notes) }, uniquingKeysWith: { first, _ in first })
        // The asked Ideas' evidence, in one pass over the relations.
        let askedIdeas = Set(chosen.filter(isIdea))
        var evidence: [String: [String]] = [:]
        if !askedIdeas.isEmpty {
            for link in map.content.links where link.kind == "idea" && askedIdeas.contains(link.a) {
                evidence[link.a, default: []].append(link.b)
            }
        }
        let items: [CanvasAskService.Snapshot.Item] = chosen.compactMap { ref in
            guard let node = map.nodesByRef[ref], let item = KnowledgeMap.ItemRef(ref) else { return nil }
            return CanvasAskService.Snapshot.Item(
                ref: ref,
                kind: item.kind,
                title: node.title,
                byline: item.kind == .idea ? "" : node.sub,
                type: node.type,
                placed: placed.contains(ref),
                region: map.regionName(holding: ref),
                note: item.kind == .idea ? (notes[item.id] ?? nil) : nil,
                evidence: evidence[ref] ?? []
            )
        }
        let chosenSet = Set(chosen)
        let arrows = map.layout.edges
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { chosenSet.contains($0.from) && chosenSet.contains($0.to) }
            .map { CanvasAskService.Arrow(from: $0.from, to: $0.to, label: $0.label) }
        return CanvasAskService.Snapshot(
            tool: tool,
            items: items,
            arrows: arrows,
            setAside: map.setAsideExamples(for: tool),
            setAsideSourceIDs: tool == .bridge ? map.askState.setAsideSourceIDs : [],
            nodes: map.nodesByRef,
            placedRefs: placed
        )
    }

    /// A kept question becomes an Idea where its ghost was, the way the Note
    /// tool writes one (`createKnowledgeMapNote`); its ref, or nil when the
    /// Idea could not be saved (the toast says so).
    func keepCanvasQuestion(_ text: String, note: String? = nil, at spot: (x: Double, y: Double)) async -> String? {
        let canvas = knowledgeMap
        guard let ref = await createCanvasIdea(title: text, note: note) else { return nil }
        canvas.place([(ref: ref, x: spot.x.rounded(), y: spot.y.rounded())])
        return ref
    }

    /// Writes an Idea (with its note, when it has one) for the Canvas and
    /// gives back its ref, placed nowhere (a Break Down sets its Ideas down
    /// together afterwards). The cards are read again before it returns unless
    /// `refreshesContent` is false, when the pane's own refresh (the Ideas
    /// list moved) does it once for several.
    func createCanvasIdea(title: String, note: String? = nil, refreshesContent: Bool = true) async -> String? {
        guard let idea = await createIdea(title: title, notes: note) else { return nil }
        if refreshesContent { await refreshKnowledgeMapContent() }
        return KnowledgeMap.ItemRef(kind: .idea, id: idea.id).description
    }

    /// The edges among `refs` (both ends in them), for Make Cards.
    func knowledgeMapEdgeIDs(among refs: [String]) -> [String] {
        let set = Set(refs)
        return knowledgeMap.layout.edges
            .filter { set.contains($0.value.from) && set.contains($0.value.to) }
            .map(\.key)
            .sorted()
    }
}
