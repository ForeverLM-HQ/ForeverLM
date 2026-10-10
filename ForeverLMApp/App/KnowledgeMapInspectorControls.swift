import SwiftUI

// MARK: - The inspector's smaller controls (docs/knowledge-map-design.md, "Circling and the inspector")
//
// What `KnowledgeMapPane`'s inspector draws for a card's colour, how a card
// opens, and an arrow's style. Each calls the view model's inspector calls
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

/// A selected arrow's style: its route, its heads, dashed or not, its colour.
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
