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

    /// An arrow's stance, as `Edge.stance` stores it; empty is none. The
    /// others are `KnowledgeMapEdgeStance`'s raw values.
    static let stances: [(title: String, value: String)] = [
        ("None", ""), ("Supports", KnowledgeMapEdgeStance.supports.rawValue), ("Contradicts", KnowledgeMapEdgeStance.contradicts.rawValue),
    ]
}

/// Which of the page, words and answer acts a selection of cards takes
/// (docs/knowledge-map-design.md, "Menus and the inspector"): each is offered
/// only where it applies to every card selected, and says which way it goes
/// (Show Page or Show as Card) by what the cards are now. The native menu and
/// the inspector both ask it, so they can never differ.
struct KnowledgeMapCardActions: Equatable {
    /// What one selected card is, as far as these acts care.
    struct Card: Equatable {
        var ref: String
        /// `KnowledgeMapNode.kind`; empty for a ref the library does not hold.
        var kind: String
        var isPlaced: Bool
        /// An Idea whose title ends in a question mark.
        var isQuestion: Bool
        /// A source whose PDF this Mac holds, so it can be drawn as a page.
        var hasPDF: Bool
        var page: Int?
        /// How many pages the PDF has once this Mac has read it.
        var pageCount: Int?
        var isPlain: Bool
        var isAnswered: Bool
        var hasAnnotation: Bool
    }

    /// Show Page (sets down the page of the cards that show their usual
    /// face) or Show as Card (every card shows a page).
    enum Face: Equatable {
        case showPage([String])
        case showAsCard([String])
    }

    /// The page of the one page face selected, and where it can turn to.
    struct PageTurn: Equatable {
        var ref: String
        var page: Int
        var pageCount: Int?
        var canGoBack: Bool
        var canGoForward: Bool
    }

    /// Annotate… (the one card has no words yet) or Edit Annotation….
    struct Annotation: Equatable {
        var ref: String
        var isEdit: Bool
    }

    /// Show as Words (an Idea drawn as a note) or Show as Note (every Idea is
    /// drawn as words).
    enum Words: Equatable {
        case showAsWords([String])
        case showAsNote([String])
    }

    /// Mark Answered or Mark Open, over question Ideas.
    enum Answered: Equatable {
        case markAnswered([String])
        case markOpen([String])
    }

    var face: Face?
    var pageTurn: PageTurn?
    var annotation: Annotation?
    var words: Words?
    var answered: Answered?

    init(cards: [Card]) {
        guard !cards.isEmpty, cards.allSatisfy(\.isPlaced) else { return }
        // A page face is a source with a PDF here that has a page set; a card
        // with a page but no PDF here draws its usual face.
        if cards.allSatisfy({ $0.kind == "source" && $0.hasPDF }) {
            let faces = cards.filter { $0.page != nil }
            face = faces.count == cards.count
                ? .showAsCard(cards.map(\.ref))
                : .showPage(cards.filter { $0.page == nil }.map(\.ref))
            if cards.count == 1, let card = cards.first, let page = card.page {
                pageTurn = PageTurn(
                    ref: card.ref,
                    page: page,
                    pageCount: card.pageCount,
                    canGoBack: page > 1,
                    canGoForward: card.pageCount.map { page < $0 } ?? true
                )
            }
        }
        if cards.count == 1, let card = cards.first, card.kind != "idea", !card.kind.isEmpty {
            annotation = Annotation(ref: card.ref, isEdit: card.hasAnnotation)
        }
        if cards.allSatisfy({ $0.kind == "idea" }) {
            words = cards.allSatisfy(\.isPlain)
                ? .showAsNote(cards.map(\.ref))
                : .showAsWords(cards.filter { !$0.isPlain }.map(\.ref))
            if cards.allSatisfy(\.isQuestion) {
                answered = cards.allSatisfy(\.isAnswered)
                    ? .markOpen(cards.map(\.ref))
                    : .markAnswered(cards.filter { !$0.isAnswered }.map(\.ref))
            }
        }
    }
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

    // MARK: Faces, words and annotations

    /// What the cards of `refs` take of Show Page, Next Page, Annotate, Show as
    /// Words and Mark Answered, read from the canvas as it stands.
    func knowledgeMapCardActions(for refs: [String]) -> KnowledgeMapCardActions {
        let map = knowledgeMap
        return KnowledgeMapCardActions(cards: refs.map { ref in
            let node = map.nodesByRef[ref]
            let placement = map.layout.placements[ref]
            let sourceID = KnowledgeMap.ItemRef(ref).flatMap { $0.kind == .source ? $0.id : nil }
            let pageCount = sourceID.flatMap { map.pageFaces[$0]?.pageCount }
            return KnowledgeMapCardActions.Card(
                ref: ref,
                kind: node?.kind ?? "",
                isPlaced: placement != nil,
                isQuestion: node.map { $0.kind == "idea" && KnowledgeMap.isQuestion($0.title) } ?? false,
                hasPDF: sourceID.map(knowledgeMapSourceHasPages) ?? false,
                page: placement?.page,
                pageCount: pageCount.flatMap { $0 > 0 ? $0 : nil },
                isPlain: placement?.plain == true,
                isAnswered: placement?.answered == true,
                hasAnnotation: placement?.annotation?.isEmpty == false
            )
        })
    }

    /// Show Page: the papers of `refs` are drawn as their first page.
    func showKnowledgeMapPages(_ refs: [String]) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardPage(placed, 1)
    }

    /// Show as Card: the pages of `refs` are drawn as the usual card again.
    func showKnowledgeMapAsCards(_ refs: [String]) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardPage(placed, nil)
    }

    /// Next Page and Previous Page (`delta` 1 and -1) on a page face.
    func turnKnowledgeMapPage(_ ref: String, by delta: Int) {
        guard knowledgeMap.layout.placements[ref] != nil else { return }
        knowledgeMap.turnCardPage(ref, by: delta)
    }

    /// The learner's words under a card, for this canvas: why it is here. Empty
    /// takes them away. An Idea has its note instead and takes none.
    func setKnowledgeMapAnnotation(_ ref: String, _ text: String) {
        guard knowledgeMap.layout.placements[ref] != nil else { return }
        knowledgeMap.setCardAnnotation(ref, text)
    }

    /// Show as Words: the Ideas of `refs` are drawn as plain words (`plain`),
    /// or as notes again.
    func setKnowledgeMapWords(_ refs: [String], plain: Bool) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardPlain(placed, plain)
    }

    /// Mark Answered or Mark Open: the badge of the question Ideas of `refs`.
    func setKnowledgeMapAnswered(_ refs: [String], answered: Bool) {
        let placed = knowledgeMapPlacedRefs(among: refs)
        guard !placed.isEmpty else { return }
        knowledgeMap.setCardAnswered(placed, answered)
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

    /// An arrow's stance: it supports or contradicts the card it points at, and
    /// is drawn green or red; nil takes it away.
    func setKnowledgeMapArrowStance(_ id: String, _ stance: KnowledgeMapEdgeStance?) {
        guard knowledgeMap.layout.edges[id] != nil else { return }
        knowledgeMap.setEdgeStance(id, stance)
    }

    /// An arrow's route, heads, dashing or colour; a nil part is left alone.
    /// An empty `color` puts the arrow back to the default colour.
    func updateKnowledgeMapArrow(_ id: String, route: String? = nil, dashed: Bool? = nil, heads: String? = nil, color: String? = nil) {
        guard knowledgeMap.layout.edges[id] != nil else { return }
        knowledgeMap.updateEdgeStyle(id, route: route, dashed: dashed, heads: heads, color: color)
    }
}
