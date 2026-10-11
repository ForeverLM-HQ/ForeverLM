import Foundation

// MARK: - What Sapience showed: the model API
// (docs/knowledge-map-design.md, "What Sapience showed (2026-10-10): the
// contract").
//
// A paper drawn as its page, the learner's words under a card, an Idea as
// plain words, a question marked answered, an arrow's stance, and what a
// mind map's nodes measure. Each call is one write of the learner's, so one
// Undo step (a burst of calls within `editBurst` is one, as the renderer's own
// writes are). The page and the MCP tools both go through here, so the row is
// never written two ways.

extension KnowledgeMapModel {
    /// Where a usual card's middle is from its top left: the point that holds a
    /// card (and a mind-map node) in a region.
    nonisolated static let usualMiddle: (x: Double, y: Double) = (KnowledgeMap.cardWidth / 2, KnowledgeMap.cardHeight / 2)

    // MARK: A paper as its page

    /// Gives the sources `row` holds that `before` did not, and that name no
    /// page, their first page, when `pageFaceDefault` says a paper placed
    /// for the first time shows it (`updateLayout`).
    func showPapersAsPages(in row: inout KnowledgeMapLayout, placedSince before: KnowledgeMapLayout) {
        guard let showsPage = pageFaceDefault else { return }
        let fresh = row.placements.filter { ref, placement in
            ref.hasPrefix("source:") && placement.page == nil && before.placements[ref] == nil
        }
        for (ref, var placement) in fresh {
            guard let item = KnowledgeMap.ItemRef(ref), showsPage(item.id) else { continue }
            placement.page = 1
            row.placements[ref] = placement
        }
    }

    /// Moves whenever a source is placed showing a page, or one is taken off or
    /// turned back into its card, so the PDFs those cards need are read
    /// (`StudioViewModel.knowledgeMapContentSignature`).
    var placedPageFacesStamp: Int {
        layout.placements.reduce(0) { $0 &+ ($1.value.page != nil ? $1.key.hashValue : 0) }
    }

    /// `page` as a source's card may show it: at least 1, and no later than the
    /// last page of its PDF once this Mac has read it.
    func clampedPage(_ page: Int, for ref: String) -> Int {
        let wanted = max(page, 1)
        guard let item = KnowledgeMap.ItemRef(ref), item.kind == .source,
              let count = pageFaces[item.id]?.pageCount, count > 0 else { return wanted }
        return min(wanted, count)
    }

    /// Shows sources as page `page` of their PDF (one-based), or with nil as
    /// their usual card. A page past the end of the PDF is its last, when this
    /// Mac knows how long it is; a card that is not a placed source is left
    /// alone. Returns how many cards changed.
    @discardableResult
    func setCardPage(_ refs: [String], _ page: Int?) -> Int {
        setPlacementStyle(refs.map { ref in
            KnowledgeMapPlacementStyle(ref: ref, page: page.map { .set(clampedPage($0, for: ref)) } ?? .clear)
        })
    }

    /// Turns a page face's page by `delta` (the pager's ‹ and ›), within the
    /// PDF once this Mac knows how long it is. False for a card that is not a
    /// page face, or one already at the end it was turned toward.
    @discardableResult
    func turnCardPage(_ ref: String, by delta: Int) -> Bool {
        guard KnowledgeMap.ItemRef(ref)?.kind == .source, let current = layout.placements[ref]?.page else { return false }
        let target = clampedPage(current + delta, for: ref)
        guard target != current else { return false }
        return setCardPage([ref], target) > 0
    }

    // MARK: Words, plain Ideas and answered questions

    /// Writes the words a card carries on this canvas (`Placement.annotation`):
    /// trimmed and held to 600 characters, nil or an empty text taking them
    /// off. False for an Idea, whose own note holds its words, for a card that
    /// is not placed, and when the words are the ones it has. The card is
    /// taller or shorter by the words, so a region that holds it grows to
    /// hold it, in the same step.
    @discardableResult
    func setCardAnnotation(_ ref: String, _ text: String?) -> Bool {
        guard let kind = KnowledgeMap.ItemRef(ref)?.kind, kind != .idea, layout.placements[ref] != nil else { return false }
        let change: KnowledgeMapFieldChange<String> = text.map { .set($0) } ?? .clear
        guard setPlacementStyle([KnowledgeMapPlacementStyle(ref: ref, annotation: change)]) > 0 else { return false }
        growRegions(toHold: [ref])
        return true
    }

    /// Draws Ideas as words on the plane, or as sticky notes again. Returns how
    /// many cards changed; a card that is not a placed Idea is left alone.
    @discardableResult
    func setCardPlain(_ refs: [String], _ plain: Bool) -> Int {
        setPlacementStyle(refs.filter { $0.hasPrefix("idea:") }.map { KnowledgeMapPlacementStyle(ref: $0, plain: .set(plain)) })
    }

    /// Marks questions answered on this canvas (their badge turns from ? to ✓),
    /// or open again. Only an Idea whose title is a question
    /// (`KnowledgeMap.isQuestion`) takes it. Returns how many cards changed.
    @discardableResult
    func setCardAnswered(_ refs: [String], _ answered: Bool) -> Int {
        let questions = refs.filter { $0.hasPrefix("idea:") && KnowledgeMap.isQuestion(nodesByRef[$0]?.title ?? "") }
        return setPlacementStyle(questions.map { KnowledgeMapPlacementStyle(ref: $0, answered: .set(answered)) })
    }

    // MARK: An arrow's side

    /// Puts an arrow on a side of an argument (drawn green or red), or with nil
    /// on neither. False for an unknown arrow or one already so.
    @discardableResult
    func setEdgeStance(_ id: String, _ stance: KnowledgeMapEdgeStance?) -> Bool {
        updateEdgeStyle(id, stance: stance?.rawValue ?? "")
    }

    // MARK: Mind-map nodes and what a card will measure

    /// What a placed card is in a mind map: an Idea with no width, height or
    /// fold of its own whose stored spot, at a usual card's middle
    /// (`regionMiddle`), is in a region whose layout is a tree. It is a
    /// `.root` when no branch leads to it, a `.branch` when one leads from it,
    /// else a `.leaf`. Read from where the card is stored, never from where
    /// the tree draws it, so a node's size and the tree's layout do not chase
    /// each other (the page reads it the same way). Nil for any other card.
    func isMindMapNode(_ ref: String) -> KnowledgeMapTreeNodeRole? {
        guard ref.hasPrefix("idea:"), let placement = layout.placements[ref],
              placement.w == nil, placement.h == nil, !placement.isFolded,
              let home = regionID(containing: ref), layout.regions[home]?.isTree == true else { return nil }
        if layout.treeParent(of: ref) == nil { return .root }
        let leadsOn = layout.edges.values.contains {
            $0.isTree && $0.from == ref && KnowledgeMap.regionID(fromRef: $0.to) == nil
        }
        return leadsOn ? .branch : .leaf
    }

    /// A mind-map node's size: its words in their box. Nil for a card that is
    /// not a node, and for one the library does not hold (its words are not
    /// known).
    func mindMapNodeSize(of ref: String) -> (w: Double, h: Double)? {
        guard let role = isMindMapNode(ref), let title = nodesByRef[ref]?.title else { return nil }
        return KnowledgeMap.treeNodeSize(title: title, role: role)
    }

    /// A card's size in a mind map that is being laid out: an Idea of no size
    /// of its own is a node of `role`, measured by its words (`titles` are the
    /// words of Ideas the map does not hold yet, by ref); every other card is
    /// the size it is.
    func treeSize(of ref: String, role: KnowledgeMapTreeNodeRole, titles: [String: String] = [:]) -> (w: Double, h: Double) {
        let own = (w: cardWidth(of: ref), h: cardHeight(of: ref))
        guard ref.hasPrefix("idea:"), let title = titles[ref] ?? nodesByRef[ref]?.title else { return own }
        if let placement = layout.placements[ref], placement.w != nil || placement.h != nil || placement.isFolded { return own }
        return KnowledgeMap.treeNodeSize(title: title, role: role)
    }

    /// The height a card will have once it is set down with `style` and the
    /// words `annotation`, so the cells it is set down in are laid out for it.
    /// A folded card is a title line and a card the learner gave a height has
    /// it; a card on the Canvas already is as tall as it is; any other is its
    /// kind's: a paper set down as its page is the page at `width` (its PDF's
    /// shape once this Mac has read it, a US Letter's until then) over its
    /// foot, and any card but an Idea has the room for its words under it.
    func heightWhenSetDown(_ ref: String, width: Double = KnowledgeMap.cardWidth, style: KnowledgeMapCardStyle? = nil, annotation: String? = nil) -> Double {
        if style?.folded == true { return KnowledgeMap.foldedCardHeight }
        if let own = style?.h { return min(max(own, KnowledgeMap.cardHeightRange.lowerBound), KnowledgeMap.cardHeightRange.upperBound) }
        guard layout.placements[ref] == nil else { return cardHeight(of: ref) }
        guard !ref.hasPrefix("idea:") else { return naturalCardHeight(of: ref) }
        var height = kindCardHeight(of: ref, width: width)
        if let item = KnowledgeMap.ItemRef(ref), item.kind == .source {
            let showsPage = style?.page.map { $0 > 0 } ?? (pageFaceDefault?(item.id) == true)
            if showsPage, pageFaces[item.id]?.pageCount != 0 {
                height = KnowledgeMap.pageFaceHeight(aspect: pageFaces[item.id]?.aspect, width: width)
            }
        }
        let words = (annotation ?? style?.annotation).flatMap(KnowledgeMap.annotation(from:))
        return height + KnowledgeMap.annotationHeight(words, width: width)
    }
}
