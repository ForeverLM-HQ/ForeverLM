import Foundation

// MARK: - What the Canvas's inspector offers, as calls (docs/knowledge-map-design.md, "Circling and the inspector")
//
// The selection inspector's ⋯ menu and colour row, the region and arrow
// controls, and the plane's right-click menu (`KnowledgeMapCanvasView`'s native
// menu) offer the same acts on the same cards. They share this file, so a
// menu item and an inspector control can never do two things: each call keeps
// to the cards a write applies to (a card not placed has no spot to colour,
// fold or line up), and each ends in one `KnowledgeMapModel` write, one Undo
// step.

/// What the pickers offer, once, for the inspector and the native menu.
enum KnowledgeMapInspectorChoices {
    struct Tint: Equatable {
        let hex: String
        let name: String
    }

    /// The eight tints a card, a region or an arrow takes, named. The hexes
    /// are `KnowledgeMapModel.regionColors`, in order.
    @MainActor static let tints: [Tint] = zip(
        KnowledgeMapModel.regionColors,
        ["Violet", "Green", "Orange", "Pink", "Amber", "Blue", "Lime", "Grey"]
    ).map { Tint(hex: $0, name: $1) }

    static let arrangements: [(title: String, value: KnowledgeMapArrangement)] = [
        ("Grid", .grid), ("Row", .row), ("Column", .column),
    ]

    static let alignments: [(title: String, value: KnowledgeMapAlignment)] = [
        ("Left", .left), ("Center", .centerX), ("Right", .right),
        ("Top", .top), ("Middle", .centerY), ("Bottom", .bottom),
    ]

    /// An arrow's route, as `KnowledgeMapLayout.Edge.route` stores it.
    static let routes: [(title: String, value: String)] = [
        ("Curve", "curve"), ("Straight", "straight"), ("Elbow", "elbow"),
    ]

    /// Where an arrow has a head, as `Edge.heads` stores it.
    static let heads: [(title: String, symbol: String, value: String)] = [
        ("One Way", "arrow.right", "end"), ("Both Ways", "arrow.left.and.right", "both"), ("No Heads", "minus", "none"),
    ]

    /// A region's layout, as `Region.layout` stores it: free (nil) or a mind map.
    static let treeLayout = "tree"
}

/// What Open in Other Window opens for a card: its source, its Doc, Ideas,
/// the canvas, the chat.
enum KnowledgeMapOtherWindowTarget: Equatable {
    case source(String)
    case doc(String)
    case ideas
    case canvas(String)
    case chat(String)
}

extension StudioViewModel {
    /// Where a card opens in another window: a source (a passage, a figure
    /// or a page opens the paper it is cut from), a Doc, Ideas, a canvas, a
    /// chat; nil for a card with nowhere else to open.
    func knowledgeMapOtherWindowTarget(for ref: String) -> KnowledgeMapOtherWindowTarget? {
        if let id = Self.knowledgeMapID(of: ref, prefix: "canvas:") { return .canvas(id) }
        if let id = Self.knowledgeMapID(of: ref, prefix: "chat:") { return .chat(id) }
        guard let item = KnowledgeMap.ItemRef(ref) else { return nil }
        if item.kind == .source { return .source(item.id) }
        if item.kind == .doc { return .doc(item.id) }
        if item.kind == .idea { return .ideas }
        if item.kind == .clip { return knowledgeMap.clips[item.id].map { .source($0.sourceID) } }
        return item.pageParts.map { .source($0.sourceID) }
    }

    // MARK: Cards

    /// The cards of `refs` that are placed on the open canvas: the only ones
    /// a colour, a fold, a size or a line-up applies to.
    func knowledgeMapPlacedRefs(among refs: [String]) -> [String] {
        refs.filter { knowledgeMap.layout.placements[$0] != nil }
    }

    /// Colours the placed cards of `refs`; nil is the card kind's own tint.
    func setKnowledgeMapCardColor(_ refs: [String], to hex: String?) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardColor(placed, hex)
    }

    /// Whether every placed card of `refs` is folded to its title.
    func knowledgeMapCardsAreFolded(_ refs: [String]) -> Bool {
        let placed = knowledgeMapPlacedRefs(among: refs)
        return !placed.isEmpty && placed.allSatisfy { knowledgeMap.layout.placements[$0]?.folded == true }
    }

    /// Fold, or Unfold when every one is folded already.
    func toggleKnowledgeMapFold(_ refs: [String]) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardFolded(placed, !knowledgeMapCardsAreFolded(placed))
    }

    /// Clears a size the learner dragged: the cards take their own height
    /// and the usual width.
    func fitKnowledgeMapCardsToContent(_ refs: [String]) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.fitCardsToContent(placed)
    }

    /// Tidy Up: two cards or more in a grid, a row or a column.
    func tidyUpKnowledgeMapCards(_ refs: [String], as arrangement: KnowledgeMapArrangement) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard placed.count >= 2 else { return }
        knowledgeMap.tidyUp(placed, as: arrangement)
    }

    /// Align: two cards or more on one edge or axis.
    func alignKnowledgeMapCards(_ refs: [String], _ alignment: KnowledgeMapAlignment) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard placed.count >= 2 else { return }
        knowledgeMap.align(placed, alignment)
    }

    /// The canvases cards can move to: every other canvas in use.
    func knowledgeMapMoveTargets() -> [KnowledgeMapCanvas] {
        listedCanvases.filter { $0.id != knowledgeMap.mapID && !$0.isTrashed }
    }

    /// Move to Canvas ▸: the placed cards of `refs` leave this canvas for
    /// `canvasID` (the "outside in" hand's `moveKnowledgeMapSelection`).
    func moveKnowledgeMapCards(_ refs: [String], toCanvas canvasID: String) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        moveKnowledgeMapSelection(refs: placed, toCanvas: canvasID)
    }

    // MARK: Regions

    func setKnowledgeMapRegionLocked(_ id: String, _ locked: Bool) {
        guard knowledgeMap.layout.regions[id] != nil else { return }
        knowledgeMap.setRegionLocked(id, locked)
    }

    func fitKnowledgeMapRegionToContent(_ id: String) {
        guard knowledgeMap.layout.regions[id] != nil else { return }
        knowledgeMap.fitRegionToContent(id)
    }

    /// Free, or a mind map (`KnowledgeMapInspectorChoices.treeLayout`).
    func setKnowledgeMapRegionLayout(_ id: String, _ layout: String?) {
        guard knowledgeMap.layout.regions[id] != nil else { return }
        knowledgeMap.setRegionLayout(id, layout)
    }

    /// A mind map's cards and branches become plain cards and arrows.
    func turnKnowledgeMapTreeIntoArrows(regionID: String) {
        guard knowledgeMap.layout.regions[regionID]?.layout == KnowledgeMapInspectorChoices.treeLayout else { return }
        knowledgeMap.turnTreeIntoArrows(regionID: regionID)
    }

    // MARK: Arrows

    /// An arrow's route, heads, dashing or colour; a nil part is left alone.
    /// An empty `color` puts the arrow back to the default colour.
    func updateKnowledgeMapArrow(_ id: String, route: String? = nil, dashed: Bool? = nil, heads: String? = nil, color: String? = nil) {
        guard knowledgeMap.layout.edges[id] != nil else { return }
        knowledgeMap.updateEdgeStyle(id, route: route, dashed: dashed, heads: heads, color: color)
    }
}
