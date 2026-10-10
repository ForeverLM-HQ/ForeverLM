import Foundation

// MARK: - Chats opened from the Canvas (docs/knowledge-map-design.md, "Circling and the inspector")
//
// Ask in Chat on a selection or a region, Lay Out a Topic, and a canvas made
// from sources each open a fresh chat beside the Canvas with something typed,
// unsent. The chat's empty state also offers three suggested questions drawn
// from the canvas (`KnowledgeMapSuggestedQuestions`), which the chat pane takes
// from `pendingReviewChatCanvasQuestions` when it starts the chat.

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
        // tray lists them.
        let around = Set(refs.compactMap { map.regionID(containing: $0) })
        let outline = map.layout.regionOutline().map(\.id)
        let regionIDs = outline.filter { around.contains($0) } + outline.filter { !around.contains($0) }
        let regions = regionIDs.map { id in
            map.notebook(ofRegion: id)?.title ?? map.layout.regions[id]?.name ?? ""
        }
        return KnowledgeMapSuggestedQuestions.questions(ideas: ideas, regions: regions)
    }

    /// Opens a fresh chat beside the Canvas, with `sourceIDs` as its context
    /// (when there are any) and `draft` typed, unsent, and the canvas's
    /// suggested questions waiting in its empty state (unless
    /// `offersQuestions` is false).
    func openChatBesideKnowledgeMap(draft: String, sourceIDs: [String]?, selection: [String] = [], offersQuestions: Bool = true) {
        if let sourceIDs { setContextSources(sourceIDs) }
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = draft
        pendingReviewChatCanvasQuestions = offersQuestions ? knowledgeMapSuggestedQuestions(selection: selection) : []
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        openCenterTabBeside(.chat)
    }
}
