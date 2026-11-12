import AppKit
import SwiftUI

// MARK: - Adding to the canvas: the add box, and the list the find field shares
//
// docs/knowledge-map-design.md, "Adding to the canvas (2026-10-10)", parts 1
// and 2. The add box is a floating card with a field, opened where the learner
// is looking (right-click ▸ Add Here…, / on the plane, the + after the tools).
// It lists what the canvas points at while nothing is typed and what the query
// finds once something is. The find field under the tools lists the same rows
// (`KnowledgeMapAddResults`); what the rows are, and how many of each, is
// `KnowledgeMapAddSearch.listing`.

// MARK: Where the chrome is

/// Where the pane's own chrome sits over the plane, so what floats under it
/// (the add box under the tools, the find field's list under the field) is
/// placed from where the pills really are.
struct KnowledgeMapChromeAnchors {
    var tools: Anchor<CGRect>?
    var find: Anchor<CGRect>?
}

struct KnowledgeMapChromeAnchorKey: PreferenceKey {
    static var defaultValue = KnowledgeMapChromeAnchors()

    static func reduce(value: inout KnowledgeMapChromeAnchors, nextValue: () -> KnowledgeMapChromeAnchors) {
        let next = nextValue()
        if let tools = next.tools { value.tools = tools }
        if let find = next.find { value.find = find }
    }
}

// MARK: Taking a row

/// Where the learner asked to add: the point in the plane's points, and the
/// same in world units, which a new Idea is written at. Neither when it was
/// asked for from the + or the find field.
struct KnowledgeMapAddSpot {
    var view: CGPoint?
    var world: (x: Double, y: Double)?
}

extension StudioViewModel {
    /// What choosing a row of the add box or the find field's list does: a
    /// library card is set down at the spot (beside the selection, else in the
    /// middle of the view, when there is none), a notebook as its frame, a
    /// card of the canvas is flown to and ringed, and what was typed is
    /// written as a new Idea at the spot, else the middle of the view. Nothing
    /// is filed into a notebook.
    func takeKnowledgeMapAddRow(_ row: KnowledgeMapAddSearch.Row, at spot: KnowledgeMapAddSpot) {
        let map = knowledgeMap
        switch row {
        case .place(let ref):
            setDownKnowledgeMapCards([ref], at: spot.view)
        case .show(let ref):
            map.send(.focus(refs: [ref], regionID: nil))
        case .showAll(let refs):
            map.send(.focus(refs: refs, regionID: nil))
        case .notebook(let id):
            setDownKnowledgeMapNotebook(id, at: spot.view)
        case .newIdea(let text):
            // The view's centre is in world units; a card's spot is its corner.
            let centre = map.viewport.center
            let world = spot.world ?? (x: centre.x - KnowledgeMap.cardWidth / 2, y: centre.y - KnowledgeMap.cardHeight / 2)
            Task { await createKnowledgeMapNote(text, at: world, on: map) }
        }
    }

    /// Cards set down at a point in the plane's points, or beside the
    /// selection, else in the middle of the view.
    func setDownKnowledgeMapCards(_ refs: [String], at point: CGPoint?) {
        if let point {
            knowledgeMap.send(.drop(x: point.x, y: point.y, refs: refs, regionName: nil))
        } else {
            knowledgeMap.send(.dropAtCenter(refs: refs, regionName: nil))
        }
    }

    /// A notebook set down as its frame: its ticked sources and what it made
    /// in a region named for it (`knowledgeMapDrop`), at a point or as cards
    /// are when there is none. A notebook with nothing to set down sets down nothing.
    func setDownKnowledgeMapNotebook(_ notebookID: String, at point: CGPoint?) {
        let placed = knowledgeMapDrop(sourceIDs: [], docIDs: [], notebookIDs: [notebookID])
        guard !placed.refs.isEmpty else { return }
        if let point {
            knowledgeMap.send(.drop(x: point.x, y: point.y, refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID))
        } else {
            knowledgeMap.send(.dropAtCenter(refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID))
        }
    }
}

// MARK: The list

/// The rows `KnowledgeMapAddSearch.listing` made, drawn like the Library's:
/// each card as what it is, a notebook, Show All, and New idea last. The
/// highlighted row (↑ ↓ move it, ↵ takes it) is tinted; a click takes a row;
/// a card or notebook drags as it does from the Library.
struct KnowledgeMapAddResults: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    let listing: KnowledgeMapAddSearch.Listing
    /// The index into `listing.rows` ↵ takes.
    let highlighted: Int
    /// `knowledgeMap.addBox` or `knowledgeMap.find`: what the rows' ids start with.
    let identifierPrefix: String
    /// The list is as tall as its rows, up to this, then it scrolls.
    let maximumHeight: CGFloat
    let onTake: (KnowledgeMapAddSearch.Row) -> Void

    @State private var contentHeight: CGFloat = 1

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }

    var body: some View {
        let rows = listing.rows
        // The model's index of cards is not observed; its revision is, so the
        // rows are drawn again when a card's words change.
        let _ = map.contentRevision
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if listing.nothingMatched {
                        Text("Nothing in your library is called that")
                            .zoomedSystemFont(size: 11.5)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .textSelection(.disabled)
                    }
                    ForEach(listing.sections) { section in
                        if let title = section.title {
                            Text(title)
                                .zoomedSystemFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                                .textSelection(.disabled)
                        }
                        ForEach(section.rows) { row in
                            resultRow(row, isHighlighted: rows.firstIndex(of: row) == highlighted)
                                .id(row.id)
                        }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    if abs(height - contentHeight) > 0.5 { contentHeight = height }
                }
            }
            .frame(height: min(contentHeight, maximumHeight))
            .onChange(of: highlighted) { _, index in
                guard rows.indices.contains(index) else { return }
                proxy.scrollTo(rows[index].id)
            }
        }
    }

    private func resultRow(_ row: KnowledgeMapAddSearch.Row, isHighlighted: Bool) -> some View {
        content(of: row)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .hoverHighlight(cornerRadius: 8, inset: 0, opacity: 0.06)
            .textSelection(.disabled)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("\(identifierPrefix).row.\(row.id)")
            .modifier(DraggableRow(row: row))
            .onTapGesture { onTake(row) }
    }

    @ViewBuilder
    private func content(of row: KnowledgeMapAddSearch.Row) -> some View {
        switch row {
        case .place(let ref), .show(let ref):
            if let node = map.nodesByRef[ref] {
                KnowledgeMapCardRowLabel(node: node, map: map)
            }
        case .showAll(let refs):
            HStack(spacing: 9) {
                KnowledgeMapGlyphTile(symbol: "scope", tint: .accentColor)
                Text("Show All \(refs.count)")
                    .zoomedSystemFont(size: 12, weight: .medium)
                Spacer(minLength: 0)
            }
        case .notebook(let id):
            if let notebook = map.content.notebooks.first(where: { $0.id == id }) {
                KnowledgeMapNotebookRowLabel(notebook: notebook)
            }
        case .newIdea(let text):
            HStack(spacing: 9) {
                KnowledgeMapGlyphTile(symbol: "plus", tint: Color(mapHex: "#EF9F27"))
                Text("New idea “\(text)”")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// A library card and a notebook drag as the Library's rows do; a card
    /// already on the canvas, Show All and New idea do not.
    private struct DraggableRow: ViewModifier {
        @Environment(StudioViewModel.self) private var vm
        @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
        let row: KnowledgeMapAddSearch.Row

        func body(content: Content) -> some View {
            let map = vm.knowledgeMap(in: windowState)
            switch row {
            case .place(let ref):
                content
                    .openHandCursor()
                    .onDrag { knowledgeMapCardDragProvider(ref: ref, vm: vm, map: map) }
            case .notebook(let id):
                let title = map.content.notebooks.first(where: { $0.id == id })?.title ?? ""
                content
                    .openHandCursor()
                    .onDrag { notebookDragProvider(for: StudioNotebookTransfer(notebookID: id), title: title) }
            case .show, .showAll, .newIdea:
                content
            }
        }
    }
}

// MARK: The find field's list

/// The list under the find field: the same rows as the add box, in a floating
/// card hanging from the field's trailing edge.
struct KnowledgeMapFindDropdown: View {
    static let width: CGFloat = 340

    let listing: KnowledgeMapAddSearch.Listing
    let highlighted: Int
    let onTake: (KnowledgeMapAddSearch.Row) -> Void

    var body: some View {
        KnowledgeMapAddResults(
            listing: listing,
            highlighted: highlighted,
            identifierPrefix: "knowledgeMap.find",
            maximumHeight: KnowledgeMapAddBox.resultsMaximumHeight,
            onTake: onTake
        )
        .frame(width: Self.width)
        .mapFloatingChrome(cornerRadius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("knowledgeMap.find.results")
    }
}

// MARK: The add box

/// The add box in the window it was asked for in, drawn over the plane while
/// `KnowledgeMapModel.addBox` is set.
struct KnowledgeMapAddBoxLayer: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    /// The plane's size, and where the tools pill is in it: the box opens
    /// under the pill when it was not asked for at a point.
    let plane: CGSize
    let toolsPill: CGRect?
    /// Gives the keys back to the plane when the box closes by itself.
    let focusPlane: () -> Void

    var body: some View {
        if let request = vm.knowledgeMap(in: windowState).addBox, request.windowID == nil || request.windowID == windowState.id {
            KnowledgeMapAddBox(request: request, plane: plane, toolsPill: toolsPill, focusPlane: focusPlane)
                .id(request)
        }
    }
}

/// A 340-point floating card with its field focused, *Find or write an idea…*,
/// and the list under it. It closes after one choice and opens empty again;
/// Esc, a click on the plane (the selection or the camera moving, or the
/// field losing the cursor) and the pane closing take it away.
struct KnowledgeMapAddBox: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    static let width: CGFloat = 340
    /// The list scrolls once its rows would pass this.
    static let resultsMaximumHeight: CGFloat = 360
    /// The room kept between the box and the plane's edges.
    static let margin: CGFloat = 12

    let request: KnowledgeMapAddBoxRequest
    let plane: CGSize
    let toolsPill: CGRect?
    let focusPlane: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var boxHeight: CGFloat = 48
    @State private var armed = false
    @FocusState private var fieldFocused: Bool

    private var map: KnowledgeMapModel { vm.knowledgeMap(in: windowState) }

    /// Where the camera is, so a pan or a zoom takes the box away.
    private var cameraKey: [Double] {
        let view = map.viewport
        return [view.center.x, view.center.y, view.span.w, view.span.h]
    }

    private var listing: KnowledgeMapAddSearch.Listing {
        KnowledgeMapAddSearch.listing(
            query: query,
            mode: .box,
            content: map.content,
            placed: Set(map.layout.placements.keys),
            selection: map.selection,
            index: map.addSearchIndex
        )
    }

    /// The card's top left: at the point asked for, else centred under the
    /// tools; kept inside the plane.
    private var origin: CGPoint {
        var x: CGFloat
        var y: CGFloat
        if let spot = request.view {
            x = spot.x
            y = spot.y
        } else if let pill = toolsPill {
            x = pill.midX - Self.width / 2
            y = pill.maxY + 8
        } else {
            x = (plane.width - Self.width) / 2
            y = 64
        }
        let margin = Self.margin
        x = min(max(x, margin), max(margin, plane.width - Self.width - margin))
        y = min(max(y, margin), max(margin, plane.height - boxHeight - margin))
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        let listing = listing
        let rows = listing.rows
        ZStack(alignment: .topLeading) {
            Color.clear
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                TextField("Find or write an idea…", text: $query)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 13)
                    .focused($fieldFocused)
                    .onSubmit {
                        if rows.indices.contains(highlighted) { take(rows[highlighted]) }
                    }
                    .onKeyPress(.downArrow) { move(1, in: rows) }
                    .onKeyPress(.upArrow) { move(-1, in: rows) }
                    .onKeyPress(.escape) {
                        close(returningKeys: true)
                        return .handled
                    }
                    .onExitCommand { close(returningKeys: true) }
                    .accessibilityIdentifier("knowledgeMap.addBox.field")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                if !rows.isEmpty {
                    Divider().opacity(0.5)
                    KnowledgeMapAddResults(
                        listing: listing,
                        highlighted: highlighted,
                        identifierPrefix: "knowledgeMap.addBox",
                        maximumHeight: Self.resultsMaximumHeight,
                        onTake: take
                    )
                }
            }
            .frame(width: Self.width)
            .mapFloatingChrome(cornerRadius: 14)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if abs(height - boxHeight) > 0.5 { boxHeight = height }
            }
            .offset(x: origin.x, y: origin.y)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("knowledgeMap.addBox")
        }
        .frame(width: plane.width, height: plane.height, alignment: .topLeading)
        .task {
            fieldFocused = true
            try? await Task.sleep(for: KnowledgeMapPopupMetrics.armDelay)
            armed = true
        }
        .onChange(of: query) { highlighted = 0 }
        // A click elsewhere on the plane: the selection or the camera moves,
        // or the field loses the cursor to the plane.
        .onChange(of: map.selection) { if armed { close() } }
        .onChange(of: map.selectedRegionID) { _, id in
            if armed, id != nil { close() }
        }
        .onChange(of: map.selectedEdgeID) { _, id in
            if armed, id != nil { close() }
        }
        .onChange(of: cameraKey) { if armed { close() } }
        .onChange(of: fieldFocused) { _, focused in
            if armed, !focused { close() }
        }
        // The pane closing, or another ask replacing this one.
        .onDisappear {
            if map.addBox == request { map.addBox = nil }
        }
    }

    private func move(_ step: Int, in rows: [KnowledgeMapAddSearch.Row]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        highlighted = min(max(highlighted + step, 0), rows.count - 1)
        return .handled
    }

    private func take(_ row: KnowledgeMapAddSearch.Row) {
        let world: (x: Double, y: Double)? = request.worldX.flatMap { x in request.worldY.map { (x: x, y: $0) } }
        let spot = KnowledgeMapAddSpot(view: request.view, world: world)
        close(returningKeys: true)
        vm.takeKnowledgeMapAddRow(row, at: spot)
    }

    /// Closes the box; by Esc or a choice, the keys go back to the plane.
    private func close(returningKeys: Bool = false) {
        if map.addBox == request { map.addBox = nil }
        if returningKeys { focusPlane() }
    }
}
