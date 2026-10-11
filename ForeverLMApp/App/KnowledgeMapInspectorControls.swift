import SwiftUI

// MARK: - The inspector's smaller controls (docs/knowledge-map-design.md, "Circling and the inspector")
//
// What `KnowledgeMapPane`'s inspector draws for a card's colour, how a card
// opens, what is written under it, which page it shows, and an arrow's style
// and stance. Each calls the view model's inspector calls
// (`StudioViewModel+CanvasInspector.swift`), which the plane's native menu
// calls too. Quiet by the Canvas's rule: a colour row and pickers, and the
// ⋯ menu for everything else, never a block of buttons.

/// The eight tints in a row, with Default before them when the thing has a
/// colour of its own to go back to.
struct KnowledgeMapColorRow: View {
    /// The colour everything selected shares; nil when none is coloured or
    /// they differ.
    let selected: String?
    /// Whether nothing selected has a colour set: Default is the lit one.
    var defaultIsSelected = false
    var offersDefault = true
    let pick: (String?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if offersDefault {
                Button {
                    pick(nil)
                } label: {
                    Image(systemName: "circle.slash")
                        .zoomedSystemFont(size: 14)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(defaultIsSelected ? 0.7 : 0), lineWidth: 2).padding(-1))
                }
                .buttonStyle(.hoverWash(in: Circle()))
                .help("Default colour")
                .accessibilityLabel("Default colour")
                .accessibilityIdentifier("knowledgeMap.colour.default")
            }
            ForEach(KnowledgeMapInspectorChoices.tints, id: \.hex) { tint in
                Button {
                    pick(tint.hex)
                } label: {
                    Circle()
                        .fill(Color(mapHex: tint.hex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected == tint.hex ? 0.7 : 0), lineWidth: 2))
                }
                .buttonStyle(.hoverWash(in: Circle()))
                .help(tint.name)
                .accessibilityLabel("Colour \(tint.name)")
                .accessibilityIdentifier("knowledgeMap.colour.\(tint.hex)")
            }
        }
    }
}

/// What a placed card's ⋯ offers besides opening it: Fold / Unfold, Fit to
/// Content, Tidy Up ▸ and Align ▸ (two cards or more), Move to Canvas ▸ and
/// Copy as Markdown. Shared by the selection inspector and a clip's, so the two
/// menus never differ. The cards of `refs` not placed on the canvas are left out
/// of what each applies to.
struct KnowledgeMapCardActionItems: View {
    @Environment(StudioViewModel.self) private var vm

    let refs: [String]

    var body: some View {
        let placed = vm.knowledgeMapPlacedRefs(among: refs)
        if !placed.isEmpty {
            facesAndWords(vm.knowledgeMapCardActions(for: placed))
            Button(vm.knowledgeMapCardsAreFolded(placed) ? "Unfold" : "Fold") { vm.toggleKnowledgeMapFold(placed) }
                .help("Draw a card as its title line, or open it again")
                .accessibilityIdentifier("knowledgeMap.selection.fold")
            Button("Fit to Content") { vm.fitKnowledgeMapCardsToContent(placed) }
                .help("Take the card's own size again")
                .accessibilityIdentifier("knowledgeMap.selection.fit")
            if placed.count >= 2 {
                Menu("Tidy Up") {
                    ForEach(KnowledgeMapInspectorChoices.arrangements, id: \.title) { choice in
                        Button(choice.title) { vm.tidyUpKnowledgeMapCards(placed, as: choice.value) }
                    }
                }
                Menu("Align") {
                    ForEach(KnowledgeMapInspectorChoices.alignments, id: \.title) { choice in
                        Button(choice.title) { vm.alignKnowledgeMapCards(placed, choice.value) }
                    }
                }
            }
            let canvases = vm.knowledgeMapMoveTargets()
            Menu("Move to Canvas") {
                ForEach(canvases) { canvas in
                    Button(canvas.name) { vm.moveKnowledgeMapCards(placed, toCanvas: canvas.id) }
                }
            }
            .disabled(canvases.isEmpty)
            .help(canvases.isEmpty ? "There is no other canvas to move them to" : "Move these cards, with the arrows among them, to another canvas")
        }
        Button("Copy as Markdown") { vm.copyKnowledgeMapMarkdown(refs) }
            .accessibilityIdentifier("knowledgeMap.selection.copyMarkdown")
    }

    /// Show Page / Show as Card for papers with a PDF here, and Show as Words /
    /// Show as Note for Ideas: only where it applies to every card.
    @ViewBuilder
    private func facesAndWords(_ actions: KnowledgeMapCardActions) -> some View {
        switch actions.face {
        case .showPage(let pages)?:
            Button("Show Page") { vm.showKnowledgeMapPages(pages) }
                .help("Draw the paper as a page of its PDF")
                .accessibilityIdentifier("knowledgeMap.selection.showPage")
        case .showAsCard(let pages)?:
            Button("Show as Card") { vm.showKnowledgeMapAsCards(pages) }
                .help("Draw the paper as its usual card again")
                .accessibilityIdentifier("knowledgeMap.selection.showAsCard")
        case nil:
            EmptyView()
        }
        switch actions.words {
        case .showAsWords(let ideas)?:
            Button("Show as Words") { vm.setKnowledgeMapWords(ideas, plain: true) }
                .help("Draw the idea as plain words, with no note behind them")
                .accessibilityIdentifier("knowledgeMap.selection.showAsWords")
        case .showAsNote(let ideas)?:
            Button("Show as Note") { vm.setKnowledgeMapWords(ideas, plain: false) }
                .help("Draw the idea as a note again")
                .accessibilityIdentifier("knowledgeMap.selection.showAsNote")
        case nil:
            EmptyView()
        }
    }
}

/// The page a page face shows, as the inspector says it: "Page 3 of 86" with
/// ‹ and › to turn it. The plane's own pill and the menu's Next Page and
/// Previous Page turn the same page.
struct KnowledgeMapPageTurner: View {
    @Environment(StudioViewModel.self) private var vm

    let turn: KnowledgeMapCardActions.PageTurn

    var body: some View {
        HStack(spacing: 6) {
            Button {
                vm.turnKnowledgeMapPage(turn.ref, by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.hoverWash(in: Circle()))
            .disabled(!turn.canGoBack)
            .help("Previous page")
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("knowledgeMap.page.previous")
            Text(turn.pageCount.map { "Page \(turn.page) of \($0)" } ?? "Page \(turn.page)")
                .zoomedSystemFont(size: 12)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .accessibilityIdentifier("knowledgeMap.page.label")
            Button {
                vm.turnKnowledgeMapPage(turn.ref, by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.hoverWash(in: Circle()))
            .disabled(!turn.canGoForward)
            .help("Next page")
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("knowledgeMap.page.next")
        }
    }
}

/// The learner's words under a card, for this canvas: why it is here
/// (`Placement.annotation`). A few lines; written when the field loses
/// focus, and the card grows to hold them. The card's own source is not
/// touched. Not offered for an Idea, whose note holds its words.
struct KnowledgeMapAnnotationField: View {
    @Environment(StudioViewModel.self) private var vm

    let ref: String

    @State private var text = ""
    @FocusState private var focused: Bool

    private var stored: String { vm.knowledgeMap.layout.placements[ref]?.annotation ?? "" }

    var body: some View {
        TextField("Why is it on this canvas?", text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...8)
            .zoomedSystemFont(size: 12)
            .focused($focused)
            .onAppear { text = stored }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            // The words written elsewhere (the plane's editor, an assistant)
            // show here, unless they are being typed over.
            .onChange(of: stored) { _, words in
                if !focused { text = words }
            }
            .onDisappear(perform: commit)
            .help("Why this card is on this canvas: written under it, for this canvas only")
            .accessibilityIdentifier("knowledgeMap.selection.annotation")
    }

    private func commit() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != stored else { return }
        vm.setKnowledgeMapAnnotation(ref, text)
        // What the canvas kept: trimmed, and cut to the room a card has.
        text = stored
    }
}

/// **Open in ▸** for a card: beside the Canvas, in another window, and for a
/// source the Reader (where a double-click opens it, over what the pane
/// shows). Menu items, for the inspector's ⋯.
struct KnowledgeMapOpenInMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let ref: String

    var body: some View {
        Menu("Open in") {
            Button("Beside") {
                Task { await vm.openKnowledgeMapItemBeside(ref, in: windowState) }
            }
            .accessibilityIdentifier("knowledgeMap.openIn.beside")
            otherWindow
            if vm.knowledgeMapCardHasReader(ref) {
                Button("Reader") {
                    Task { await vm.openKnowledgeMapItem(ref, in: windowState) }
                }
                .accessibilityIdentifier("knowledgeMap.openIn.reader")
            }
        }
    }

    /// Where Open in Other Window takes it: the same place a click does.
    @ViewBuilder
    private var otherWindow: some View {
        switch vm.knowledgeMapOtherWindowTarget(for: ref) {
        case .source(let id): OtherWindowSourceMenuItem(sourceID: id)
        case .doc(let id): OtherWindowMenuItem(.doc(id))
        case .ideas: OtherWindowMenuItem(.ideas)
        case .canvas(let id): OtherWindowMenuItem(.canvas(id))
        case .chat(let id): OtherWindowMenuItem(.chat(id))
        case nil: EmptyView()
        }
    }
}

/// A selected arrow's style: its route, its stance, its heads, dashed or not,
/// its colour.
/// The label and Delete Arrow stay in the pane's own arrow inspector.
struct KnowledgeMapEdgeStyleControls: View {
    @Environment(StudioViewModel.self) private var vm

    let id: String
    let edge: KnowledgeMapLayout.Edge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Route", selection: Binding(
                get: { edge.route ?? "curve" },
                set: { vm.updateKnowledgeMapArrow(id, route: $0) }
            )) {
                ForEach(KnowledgeMapInspectorChoices.routes, id: \.value) { route in
                    Text(route.title).tag(route.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("How the arrow runs between its cards")
            .accessibilityLabel("Route")
            .accessibilityIdentifier("knowledgeMap.edge.route")
            // For or against the card the arrow points at: drawn green or
            // red. A mind map's branch takes none.
            if !edge.isTree {
                Picker("Stance", selection: Binding(
                    get: { edge.stance ?? "" },
                    set: { vm.setKnowledgeMapArrowStance(id, KnowledgeMapEdgeStance(rawValue: $0)) }
                )) {
                    ForEach(KnowledgeMapInspectorChoices.stances, id: \.value) { stance in
                        Text(stance.title).tag(stance.value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Whether the arrow supports or contradicts the card it points at")
                .accessibilityLabel("Stance")
                .accessibilityIdentifier("knowledgeMap.edge.stance")
            }
            Picker("Heads", selection: Binding(
                get: { edge.heads ?? "end" },
                set: { vm.updateKnowledgeMapArrow(id, heads: $0) }
            )) {
                ForEach(KnowledgeMapInspectorChoices.heads, id: \.value) { heads in
                    Image(systemName: heads.symbol)
                        .help(heads.title)
                        .accessibilityLabel(heads.title)
                        .tag(heads.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Where the arrow has a head")
            .accessibilityLabel("Heads")
            .accessibilityIdentifier("knowledgeMap.edge.heads")
            Toggle("Dashed", isOn: Binding(
                get: { edge.dashed == true },
                set: { vm.updateKnowledgeMapArrow(id, dashed: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .zoomedSystemFont(size: 12)
            .accessibilityIdentifier("knowledgeMap.edge.dashed")
            KnowledgeMapColorRow(selected: edge.color, defaultIsSelected: edge.color == nil) { hex in
                // An empty colour is the default one.
                vm.updateKnowledgeMapArrow(id, color: hex ?? "")
            }
        }
    }
}
