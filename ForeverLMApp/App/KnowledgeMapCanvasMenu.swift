import AppKit
import Foundation

// MARK: - The Canvas's right-click menus
//
// docs/knowledge-map-design.md, "The renderer's design", item 4. The page
// selects what was hit and posts `contextMenu {kind, refs?, id?, x, y, wx, wy}`;
// the canvas shows one of these as a native `NSMenu` at that point. Each item
// calls the model's or the view model's own action, so the menu and the
// inspector share their code.
//
//   plane:  Add Here…, New Idea Here, New Region Here, Paste, Fit All
//   cards:  Open, Open Beside, Edit (an Idea), Ask in Chat, Add to Chat, Ask ▸,
//           Show Page / Show as Card, Next Page, Previous Page, Annotate… /
//           Edit Annotation…, Show as Words / Show as Note, Mark Answered /
//           Mark Open (each only where it applies to every card selected, as
//           `KnowledgeMapCardActions` says), Colour ▸, Fold, Fit to Content,
//           Tidy Up ▸, Align ▸, Copy as Markdown, Copy Link, Move to Canvas ▸,
//           Take Off Canvas, Delete (an Idea)
//   region: Rename, Colour ▸, Fold Up, Fit to Content, Lock, Layout ▸, Turn
//           into Cards and Arrows, Ask in Chat, Delete Region
//   arrow:  Route ▸, Stance ▸, Heads ▸, Dashed, Colour ▸, Edit Label, Delete Arrow

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() { handler() }
}

@MainActor
struct KnowledgeMapCanvasMenu {
    let canvas: KnowledgeMapCanvasView.Coordinator
    let model: KnowledgeMapModel
    let vm: StudioViewModel
    let windowState: StudioWindowState
    /// Where the click was, in the plane's points from its top left.
    let view: CGPoint
    /// Where the click was, in world units.
    let world: (Double, Double)

    /// The eight tints, in `KnowledgeMapModel.regionColors` order, and what they are called.
    private static let colourNames = ["Purple", "Green", "Orange", "Pink", "Gold", "Blue", "Lime", "Gray"]

    func menu(kind: String, refs: [String], id: String?) -> NSMenu? {
        switch kind {
        case "plane": return planeMenu()
        case "cards": return refs.isEmpty ? nil : cardsMenu(refs)
        case "region":
            guard let id, let region = model.layout.regions[id] else { return nil }
            return regionMenu(id, region)
        case "edge":
            guard let id, let edge = model.layout.edges[id] else { return nil }
            return edgeMenu(id, edge)
        default: return nil
        }
    }

    // MARK: Empty space

    private func planeMenu() -> NSMenu {
        let menu = Self.newMenu()
        // The add box at the click, so a card is set down, or an Idea written,
        // exactly where the learner pointed.
        menu.addItem(item("Add Here…") {
            model.addBox = KnowledgeMapAddBoxRequest(view: view, worldX: world.0, worldY: world.1, windowID: windowState.id)
        })
        menu.addItem(item("New Idea Here") {
            canvas.call("newIdea", String(world.0), String(world.1))
        })
        menu.addItem(item("New Region Here") { newRegionHere() })
        menu.addItem(.separator())
        let pasteable = NSPasteboard.general.pasteboardItems?.isEmpty == false
        menu.addItem(item("Paste", enabled: pasteable) {
            (canvas.webView as? KnowledgeMapWebView)?.paste(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item("Fit All") { model.send(.fit) })
        return menu
    }

    /// A region around where the click was, its name asked for on the plane next.
    private func newRegionHere() {
        let id = KnowledgeMapModel.newRegionID()
        model.saveRegion(id: id, name: "", x: world.0 - 240, y: world.1 - 160, w: 480, h: 320, color: model.nextRegionColor())
        model.send(.selectRegion(id))
        let canvas = canvas
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            canvas.sync()
            canvas.call("renameRegion", KnowledgeMapCanvasView.Coordinator.jsString(id))
        }
    }

    // MARK: Cards

    private func cardsMenu(_ refs: [String]) -> NSMenu {
        let menu = Self.newMenu()
        let items = refs.compactMap(KnowledgeMap.ItemRef.init)
        let placed = refs.filter { model.layout.placements[$0] != nil }
        let ideaRefs = items.filter { $0.kind == .idea }.map(\.description)
        let placements = placed.compactMap { model.layout.placements[$0] }

        if refs.count == 1, let ref = refs.first {
            menu.addItem(item("Open") { Task { await vm.openKnowledgeMapItem(ref, in: windowState) } })
            menu.addItem(item("Open Beside") { Task { await vm.openKnowledgeMapItemBeside(ref, in: windowState) } })
            if ideaRefs.count == 1 {
                menu.addItem(item("Edit") {
                    canvas.call("editIdea", KnowledgeMapCanvasView.Coordinator.jsString(ref))
                })
            }
            menu.addItem(.separator())
        }

        menu.addItem(item("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(refs) })
        menu.addItem(item("Add to Chat") { vm.addKnowledgeMapCardsToChat(refs, in: windowState) })
        menu.addItem(submenu("Ask", CanvasAskTool.allCases.map { tool in
            // Connect needs two placed cards, as the inspector's does.
            item(tool.title, enabled: tool == .connect ? placed.count >= 2 : true) { vm.canvasAsk(tool, refs: refs) }
        }))
        menu.addItem(.separator())

        // How the cards are drawn and what is written under them: each item is
        // here only when it applies to every card selected.
        let faceItems = cardFaceItems(vm.knowledgeMapCardActions(for: refs))
        for entry in faceItems { menu.addItem(entry) }
        if !faceItems.isEmpty { menu.addItem(.separator()) }

        menu.addItem(submenu("Colour", colourItems(current: Set(placements.map(\.color)), enabled: !placed.isEmpty) { hex in
            model.setCardColor(placed, hex)
        }))
        let allFolded = !placements.isEmpty && placements.allSatisfy { $0.folded == true }
        menu.addItem(item(allFolded ? "Unfold" : "Fold", enabled: !placed.isEmpty) { model.setCardFolded(placed, !allFolded) })
        menu.addItem(item("Fit to Content", enabled: !placed.isEmpty) { model.fitCardsToContent(placed) })
        menu.addItem(submenu("Tidy Up", [
            item("As a Grid", enabled: placed.count >= 2) { model.tidyUp(placed, as: .grid) },
            item("As a Row", enabled: placed.count >= 2) { model.tidyUp(placed, as: .row) },
            item("As a Column", enabled: placed.count >= 2) { model.tidyUp(placed, as: .column) },
        ]))
        menu.addItem(submenu("Align", [
            item("Left", enabled: placed.count >= 2) { model.align(placed, .left) },
            item("Centre", enabled: placed.count >= 2) { model.align(placed, .centerX) },
            item("Right", enabled: placed.count >= 2) { model.align(placed, .right) },
            .separator(),
            item("Top", enabled: placed.count >= 2) { model.align(placed, .top) },
            item("Middle", enabled: placed.count >= 2) { model.align(placed, .centerY) },
            item("Bottom", enabled: placed.count >= 2) { model.align(placed, .bottom) },
        ]))
        menu.addItem(.separator())

        menu.addItem(item("Copy as Markdown") { vm.copyKnowledgeMapMarkdown(refs) })
        let links = items.compactMap(Self.link(for:))
        menu.addItem(item("Copy Link", enabled: !links.isEmpty) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        })
        let others = vm.listedCanvases.filter { !$0.isTrashed && $0.id != model.mapID }
        menu.addItem(submenu("Move to Canvas", others.isEmpty
            ? [item("No Other Canvases", enabled: false) {}]
            : others.map { other in
                item(other.name, enabled: !placed.isEmpty) {
                    vm.moveKnowledgeMapSelection(refs: placed, toCanvas: other.id)
                }
            }))
        menu.addItem(.separator())
        menu.addItem(item("Take Off Canvas", enabled: !placed.isEmpty) { model.unplace(placed) })
        if !ideaRefs.isEmpty {
            menu.addItem(item(ideaRefs.count == 1 ? "Delete Idea" : "Delete Ideas") {
                Task { await vm.deleteKnowledgeMapItems(ideaRefs) }
            })
        }
        return menu
    }

    /// Show Page / Show as Card, Next Page and Previous Page, Annotate… / Edit
    /// Annotation…, Show as Words / Show as Note and Mark Answered / Mark Open,
    /// for what `actions` says the selection takes.
    private func cardFaceItems(_ actions: KnowledgeMapCardActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch actions.face {
        case .showPage(let refs)?: items.append(item("Show Page") { vm.showKnowledgeMapPages(refs) })
        case .showAsCard(let refs)?: items.append(item("Show as Card") { vm.showKnowledgeMapAsCards(refs) })
        case nil: break
        }
        if let turn = actions.pageTurn {
            items.append(item("Next Page", enabled: turn.canGoForward) { vm.turnKnowledgeMapPage(turn.ref, by: 1) })
            items.append(item("Previous Page", enabled: turn.canGoBack) { vm.turnKnowledgeMapPage(turn.ref, by: -1) })
        }
        if let annotation = actions.annotation {
            items.append(item(annotation.isEdit ? "Edit Annotation…" : "Annotate…") { canvas.editAnnotation(annotation.ref) })
        }
        switch actions.words {
        case .showAsWords(let refs)?: items.append(item("Show as Words") { vm.setKnowledgeMapWords(refs, plain: true) })
        case .showAsNote(let refs)?: items.append(item("Show as Note") { vm.setKnowledgeMapWords(refs, plain: false) })
        case nil: break
        }
        switch actions.answered {
        case .markAnswered(let refs)?: items.append(item("Mark Answered") { vm.setKnowledgeMapAnswered(refs, answered: true) })
        case .markOpen(let refs)?: items.append(item("Mark Open") { vm.setKnowledgeMapAnswered(refs, answered: false) })
        case nil: break
        }
        return items
    }

    /// The address a card has outside the Canvas: a source, a Doc, an Idea or a chat.
    private static func link(for item: KnowledgeMap.ItemRef) -> String? {
        switch item.kind {
        case .source: return "foreverlm://source/" + StudioEntityLink.encode(item.id)
        case .doc: return StudioEntityLink.doc(item.id).markdownDestination
        case .idea: return StudioEntityLink.idea(item.id).markdownDestination
        default: return nil
        }
    }

    // MARK: Regions

    private func regionMenu(_ id: String, _ region: KnowledgeMapLayout.Region) -> NSMenu {
        let menu = Self.newMenu()
        // A notebook's frame is named by its notebook.
        menu.addItem(item("Rename", enabled: region.notebookID == nil) {
            canvas.call("renameRegion", KnowledgeMapCanvasView.Coordinator.jsString(id))
        })
        menu.addItem(submenu("Colour", colourItems(current: [region.color], enabled: true, hasDefault: false) { hex in
            if let hex { model.recolorRegion(id, to: hex) }
        }))
        menu.addItem(item(region.isCollapsed ? "Open" : "Fold Up") { model.setRegionCollapsed(id, !region.isCollapsed) })
        menu.addItem(item("Fit to Content") { model.fitRegionToContent(id) })
        let locked = region.locked == true
        menu.addItem(item(locked ? "Unlock" : "Lock") { model.setRegionLocked(id, !locked) })
        let tree = region.layout == "tree"
        menu.addItem(submenu("Layout", [
            item("Free", checked: !tree) { model.setRegionLayout(id, nil) },
            item("Mind Map", checked: tree) { model.setRegionLayout(id, "tree") },
        ]))
        if tree {
            menu.addItem(item("Turn into Cards and Arrows") { turnTreeIntoArrows(id) })
        }
        menu.addItem(.separator())
        menu.addItem(item("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(model.refsInRegion(id)) })
        menu.addItem(.separator())
        menu.addItem(item("Delete Region") { model.deleteRegion(id) })
        return menu
    }

    /// The page writes the tree's drawn spots first (they are where the cards
    /// are drawn), then the layout and the branches go.
    private func turnTreeIntoArrows(_ id: String) {
        let canvas = canvas, model = model
        canvas.call("commitDrawnSpots", KnowledgeMapCanvasView.Coordinator.jsString(id))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            model.turnTreeIntoArrows(regionID: id)
        }
    }

    // MARK: Arrows

    private func edgeMenu(_ id: String, _ edge: KnowledgeMapLayout.Edge) -> NSMenu {
        let menu = Self.newMenu()
        // A mind map's branch has no route or heads of its own.
        if edge.tree != true {
            let route = edge.route ?? "curve"
            menu.addItem(submenu("Route", [
                item("Curve", checked: route == "curve") { model.updateEdgeStyle(id, route: "curve") },
                item("Straight", checked: route == "straight") { model.updateEdgeStyle(id, route: "straight") },
                item("Elbow", checked: route == "elbow") { model.updateEdgeStyle(id, route: "elbow") },
            ]))
            // For or against the card it points at: drawn green or red.
            let stance = edge.stance
            menu.addItem(submenu("Stance", [
                item("Supports", checked: stance == KnowledgeMapEdgeStance.supports.rawValue) {
                    vm.setKnowledgeMapArrowStance(id, .supports)
                },
                item("Contradicts", checked: stance == KnowledgeMapEdgeStance.contradicts.rawValue) {
                    vm.setKnowledgeMapArrowStance(id, .contradicts)
                },
                .separator(),
                item("None", checked: stance == nil) { vm.setKnowledgeMapArrowStance(id, nil) },
            ]))
            let heads = edge.heads ?? "end"
            menu.addItem(submenu("Heads", [
                item("At the End", checked: heads == "end") { model.updateEdgeStyle(id, heads: "end") },
                item("At Both Ends", checked: heads == "both") { model.updateEdgeStyle(id, heads: "both") },
                item("None", checked: heads == "none") { model.updateEdgeStyle(id, heads: "none") },
            ]))
        }
        let dashed = edge.dashed == true
        menu.addItem(item("Dashed", checked: dashed) { model.updateEdgeStyle(id, dashed: !dashed) })
        menu.addItem(submenu("Colour", colourItems(current: Set([edge.color]), enabled: true) { hex in
            model.updateEdgeStyle(id, color: hex ?? "")
        }))
        menu.addItem(.separator())
        menu.addItem(item("Edit Label") {
            canvas.call("editEdgeLabel", KnowledgeMapCanvasView.Coordinator.jsString(id))
        })
        menu.addItem(item("Delete Arrow") { model.deleteEdge(id) })
        return menu
    }

    // MARK: Pieces

    /// A menu whose items are enabled as they are told: with the default, AppKit
    /// enables any item whose target answers its action, whatever `isEnabled` says.
    private static func newMenu(_ title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        return menu
    }

    private func item(_ title: String, enabled: Bool = true, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = ClosureMenuItem(title: title, handler: action)
        menuItem.isEnabled = enabled
        menuItem.state = checked ? .on : .off
        return menuItem
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = Self.newMenu(title)
        for child in items { menu.addItem(child) }
        parent.submenu = menu
        return parent
    }

    /// The eight tints as a menu's items (a swatch each, the one in use ticked),
    /// and Default after them when the thing has a colour of its own to give up.
    /// `apply` gets the tint, or nil for Default.
    private func colourItems(current: Set<String?>, enabled: Bool, hasDefault: Bool = true, apply: @escaping (String?) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, hex) in KnowledgeMapModel.regionColors.enumerated() {
            let name = index < Self.colourNames.count ? Self.colourNames[index] : hex
            let entry = item(name, enabled: enabled, checked: current.count == 1 && current.contains(hex)) { apply(hex) }
            entry.image = Self.swatch(hex)
            items.append(entry)
        }
        if hasDefault {
            items.append(.separator())
            items.append(item("Default", enabled: enabled, checked: current.count == 1 && current.contains(nil)) { apply(nil) })
        }
        return items
    }

    /// A small round swatch of `#rrggbb`.
    private static func swatch(_ hex: String) -> NSImage {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        let value = UInt32(digits, radix: 16) ?? 0x888780
        let colour = NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
