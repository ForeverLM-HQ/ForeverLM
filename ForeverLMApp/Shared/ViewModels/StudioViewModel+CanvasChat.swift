import Foundation

// MARK: - Chats opened from the Canvas (docs/knowledge-map-design.md, "Circling and the inspector", "Add to Chat and the chips")
//
// Ask in Chat on a selection or a region opens a fresh chat beside the Canvas
// with the cards as chips over its composer (`KnowledgeMapChatContext`) and
// nothing typed; a canvas made from sources opens one with something typed,
// unsent, and no cards. Add to Chat gives the cards to the chat
// already beside the Canvas, or opens one. The chat's empty state also offers
// three suggested questions drawn from the canvas
// (`KnowledgeMapSuggestedQuestions`), which the chat pane takes from
// `pendingReviewChatCanvasQuestions` when it starts the chat.

extension StudioViewModel {
    /// Three questions for a chat about the open canvas: its Ideas' sentences
    /// and its regions' names, the selected cards' first. Empty when nothing
    /// is written on it.
    func knowledgeMapSuggestedQuestions(selection refs: [String] = []) -> [String] {
        let map = knowledgeMap
        let placed = map.layout.placements
        let selected = Set(refs)
        func title(ofIdea ref: String) -> String? {
            guard let node = map.nodesByRef[ref], node.kind == "idea" else { return nil }
            return node.title
        }
        // The Ideas on the plane, the selected ones first, the rest in reading order.
        let readingOrder = placed.keys.sorted { a, b in
            let pa = placed[a]!, pb = placed[b]!
            let rowA = Int((pa.y / KnowledgeMap.cardHeight).rounded(.down)), rowB = Int((pb.y / KnowledgeMap.cardHeight).rounded(.down))
            if rowA != rowB { return rowA < rowB }
            return pa.x != pb.x ? pa.x < pb.x : a < b
        }
        let ideaRefs = readingOrder.filter { selected.contains($0) } + readingOrder.filter { !selected.contains($0) }
        let ideas = ideaRefs.compactMap(title(ofIdea:))
        // The regions, those around a selected card first, the rest as the
        // canvas menu lists them.
        let around = Set(refs.compactMap { map.regionID(containing: $0) })
        let outline = map.layout.regionOutline().map(\.id)
        let regionIDs = outline.filter { around.contains($0) } + outline.filter { !around.contains($0) }
        let regions = regionIDs.map { id in
            map.notebook(ofRegion: id)?.title ?? map.layout.regions[id]?.name ?? ""
        }
        return KnowledgeMapSuggestedQuestions.questions(ideas: ideas, regions: regions)
    }

    /// The cards of `refs` as a chat holds them: what each says, taken now
    /// (`KnowledgeMapChatCard`), in the order given, each once, at most
    /// `KnowledgeMapChatContext.cardLimit`. A ref the canvas's library does
    /// not hold any more is left out.
    func knowledgeMapChatCards(_ refs: [String]) -> [KnowledgeMapChatCard] {
        let map = knowledgeMap
        var seen: Set<String> = []
        var cards: [KnowledgeMapChatCard] = []
        for ref in refs where seen.insert(ref).inserted {
            guard let node = map.nodesByRef[ref] else { continue }
            cards.append(.card(of: node, annotation: map.layout.placements[ref]?.annotation))
            if cards.count == KnowledgeMapChatContext.cardLimit { break }
        }
        return cards
    }

    /// The library sources whose text a chat takes in at once for these cards:
    /// a source card's source and the paper a page card is a page of, each
    /// once.
    func knowledgeMapChatSourceIDs(_ cards: [KnowledgeMapChatCard]) -> [String] {
        var seen: Set<String> = []
        return cards.compactMap(\.librarySourceID).filter { seen.insert($0).inserted }
    }

    /// **Add to Chat** (the card menu, the inspector, ⌘L on the plane): the
    /// cards of `refs` join the chat `windowState` shows beside the Canvas, as
    /// chips over its composer and lines in what the model is told; a window
    /// with no chat beside the Canvas opens a fresh one with them, nothing
    /// typed and the canvas's suggested questions offered. The chat pane
    /// takes them from `pendingChatCanvasCards`, and loads the text of the
    /// sources and Docs among them as a dropped one is loaded.
    func addKnowledgeMapCardsToChat(_ refs: [String], in windowState: StudioWindowState) {
        let cards = knowledgeMapChatCards(refs)
        guard !cards.isEmpty else {
            showToast("Select cards on the canvas to add to the chat")
            return
        }
        let handOff = KnowledgeMapChatCards(
            windowID: windowState.id,
            canvasID: knowledgeMap.mapID,
            canvasName: openCanvasName,
            cards: cards,
            replaces: false
        )
        inWindow(windowState) {
            if visibleCenterTabs(in: windowState).contains(.chat) {
                pendingChatCanvasCards = handOff
                reviewChatFocusRequestID = UUID()
            } else {
                openChatBesideKnowledgeMap(
                    draft: nil,
                    sourceIDs: knowledgeMapChatSourceIDs(cards),
                    selection: refs,
                    cards: handOff
                )
            }
            showToast(Self.addedToChatMessage(cards.count == 1 ? "Card" : "\(cards.count) cards", elsewhere: chatRequestElsewhereNotice))
        }
    }

    /// A card chip's click: the Canvas shows the card, flying to it and ringing
    /// it (`focus_map`'s path). The canvas the chat was opened from is opened
    /// first when another is open, or the Canvas is not on screen.
    func showKnowledgeMapChatCard(_ ref: String, canvasID: String, in windowState: StudioWindowState?) async {
        let window = windowState ?? activeWindowState
        if knowledgeMap.mapID == canvasID, visibleCenterTabs(in: window).contains(.knowledgeMap) {
            knowledgeMap.send(.focus(refs: [ref], regionID: nil))
            return
        }
        guard listedCanvases.contains(where: { $0.id == canvasID }) else {
            showToast("That canvas is no longer there")
            return
        }
        await showCardOnCanvas(ref, canvasID: canvasID, in: window)
    }

    /// The canvas chip's click: the canvas the chat was opened from.
    func showKnowledgeMapChatCanvas(_ canvasID: String, in windowState: StudioWindowState?) {
        guard listedCanvases.contains(where: { $0.id == canvasID }) else {
            showToast("That canvas is no longer there")
            return
        }
        openCanvas(canvasID, in: windowState)
    }

    /// **Make a Mind Map** and **Break Into Questions** in the empty chat: the
    /// Ask runs on the open canvas over the chat's cards, else over what is
    /// selected there, and its answer arrives on the plane as proposals to
    /// keep (`startCanvasAsk`). Nothing is typed in the chat.
    func startCanvasAsk(_ tool: CanvasAskTool, from context: KnowledgeMapChatContext) {
        let refs = context.cards.isEmpty ? knowledgeMap.selection : context.cards.map(\.ref)
        startCanvasAsk(tool, refs: refs)
    }

    /// Opens a fresh chat beside the Canvas, with `sourceIDs` as its context
    /// (when there are any) and `draft` typed, unsent (when there is one), and
    /// the canvas's suggested questions waiting in its empty state (unless
    /// `offersQuestions` is false). `cards` become the chat's canvas context as
    /// it starts.
    func openChatBesideKnowledgeMap(
        draft: String?,
        sourceIDs: [String]?,
        selection: [String] = [],
        offersQuestions: Bool = true,
        cards: KnowledgeMapChatCards? = nil
    ) {
        if let sourceIDs { setContextSources(sourceIDs) }
        pendingChatCanvasCards = cards
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = draft
        pendingReviewChatCanvasQuestions = offersQuestions ? knowledgeMapSuggestedQuestions(selection: selection) : []
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        openCenterTabBeside(.chat)
    }
}
