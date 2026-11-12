#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Add to Canvas ▸ and On canvases
//
// The two ways a card meets the learner's canvases from outside the Canvas
// (docs/heptabase-canvas-parity.md, "Getting things onto the plane" and
// "Nested whiteboards"; docs/knowledge-map-design.md, "Dropping from the rest
// of the app"): a submenu on every list row and page menu that adds the card
// to a canvas, and a line on the card's own surfaces that says which canvases
// hold it, each name opening that canvas at the card.

/// **Add to Canvas ▸**: the learner's canvases, the open one first and then by
/// last activity, then **New Canvas…**. Choosing one sets the cards on it
/// (`StudioViewModel.addToCanvas`): in the middle of the view when it is the
/// open canvas and showing, else written into its row without opening it and
/// said in a toast with a Show button. Drawn only where canvases are listed
/// (`StudioViewModel.listsCanvases`: the beta, My Library).
struct KnowledgeMapAddToCanvasMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The cards, as item refs: `source:<id>`, `doc:<id>`, `idea:<id>`, `chat:<id>`.
    let refs: [String]

    var body: some View {
        if vm.listsCanvases, !vm.isActiveLibraryReadOnly, !refs.isEmpty {
            let canvases = vm.inWindow(windowState) { vm.canvasesToAddTo }
            let refs = refs
            Menu {
                ForEach(canvases) { canvas in
                    Button(canvas.name) {
                        vm.task(in: windowState) { await vm.addToCanvas(refs: refs, canvasID: canvas.id) }
                    }
                }
                if !canvases.isEmpty { Divider() }
                Button("New Canvas…") {
                    KnowledgeMapCanvasNamePrompt.ask(startingWith: vm.canvasNameSuggestion(forRefs: refs)) { name in
                        vm.task(in: windowState) { await vm.addToNewCanvas(refs: refs, named: name, in: windowState) }
                    }
                }
            } label: {
                Label("Add to Canvas", systemImage: KnowledgeMap.symbolName)
            }
        }
    }
}

/// The name a **New Canvas…** asks for: a name field over the window, filled
/// with the card's title when it is one card.
@MainActor
enum KnowledgeMapCanvasNamePrompt {
    static func ask(startingWith suggestion: String?, then create: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Canvas"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = KnowledgeMap.newCanvasName
        field.stringValue = suggestion ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            create(KnowledgeMapCanvases.cleanedName(field.stringValue) ?? KnowledgeMap.newCanvasName)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// **On Canvases**, for a card's menu (a source row's, the Reader's ⋯, a
/// Doc's): each canvas that holds the card by name, opening that canvas and
/// flying to the card. Beside In Notebooks, which lists the same for
/// notebooks. Nothing at all when no canvas holds it.
struct KnowledgeMapOnCanvasesSection: View {
    @Environment(StudioViewModel.self) private var vm
    /// The card, as an item ref.
    let ref: String
    /// The window the click opens the canvas in; nil for a pop-out Reader,
    /// which belongs to no Studio window, and the canvas then opens where the
    /// learner last was.
    let windowState: StudioWindowState?

    var body: some View {
        let canvases = vm.canvasesHolding(ref: ref)
        if !canvases.isEmpty {
            Section("On Canvases") {
                ForEach(canvases) { canvas in
                    Button(canvas.name, systemImage: KnowledgeMap.symbolName) {
                        vm.task(in: windowState) { await vm.showCardOnCanvas(ref, canvasID: canvas.id, in: windowState) }
                    }
                    .help("Open \(canvas.name) at this card")
                }
            }
        }
    }
}

/// **On canvases: A, B** as a line on a card's own row (an Idea's): each name
/// a button that opens that canvas and flies to the card. Nothing at all when
/// no canvas holds it.
struct KnowledgeMapOnCanvasesLine: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The card, as an item ref.
    let ref: String

    var body: some View {
        let canvases = vm.canvasesHolding(ref: ref)
        if !canvases.isEmpty {
            FlowLayout(spacing: StudioDesign.Spacing.xSmall) {
                Text("On canvases:")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                ForEach(Array(canvases.enumerated()), id: \.element.id) { index, canvas in
                    Button {
                        vm.task(in: windowState) { await vm.showCardOnCanvas(ref, canvasID: canvas.id, in: windowState) }
                    } label: {
                        Text(index < canvases.count - 1 ? canvas.name + "," : canvas.name)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .buttonStyle(.hoverWash)
                    .help("Open \(canvas.name) at this card")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvases.onCanvasesLine")
        }
    }
}
#endif
