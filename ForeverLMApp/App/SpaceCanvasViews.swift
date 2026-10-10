#if os(macOS)
import SwiftUI

// MARK: - Canvases in the Space
//
// What the Space draws for a canvas (`KnowledgeMapCanvas`,
// docs/knowledge-map-design.md, "Canvases in the Space"): the same menu on
// its row in a list, its card in the grid, its row in the sidebar's Pinned and
// Recents, and the name at the top of the canvas itself, as a page's menu is
// one menu wherever the page is listed.

/// A canvas's ⋯ and right-click: ChatGPT's page menu, for a canvas. In Trash,
/// Restore; Delete Forever is the list's, which asks first.
struct SpaceCanvasMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let canvas: KnowledgeMapCanvas
    /// Opens it here; nil where it is already open (the canvas's own name).
    var onOpen: (() -> Void)?
    let onRename: () -> Void

    var body: some View {
        if canvas.isTrashed {
            Button("Restore", systemImage: "arrow.uturn.backward") { vm.restoreCanvases([canvas.id]) }
        } else {
            if let onOpen {
                Button("Open", action: onOpen)
            }
            OtherWindowMenuItem(.canvas(canvas.id))
            Divider()
            Button("Rename…", systemImage: "pencil", action: onRename)
            let pinned = vm.isPagePinned(canvas.id)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                vm.setPagePinned(canvas.id, pinned: !pinned)
            }
            PageSpaceMenu(itemIDs: [canvas.id])
            // What needs the canvas drawn, or the cards' words: the open one.
            if vm.knowledgeMap.mapID == canvas.id {
                Divider()
                canvasExportItems
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                vm.moveCanvasesToTrash([canvas.id])
            }
        }
    }
}

extension SpaceCanvasMenuItems {
    /// Export as Image…, Copy as Markdown, Save Version…, Versions… and
    /// Publish… (docs/knowledge-map-design.md, "Versions, export and
    /// publishing"): of the canvas open on this Mac, whose picture a Canvas
    /// pane draws and whose cards' words its model holds. ⌥⌘S is Save
    /// Version's, as the View menu's item says.
    @ViewBuilder
    fileprivate var canvasExportItems: some View {
        Menu("Export as Image…", systemImage: "photo") {
            ForEach(CanvasExport.scales, id: \.self) { scale in
                Button(CanvasExport.scaleLabel(scale)) {
                    vm.exportCanvasImage(canvasID: canvas.id, scale: scale)
                }
            }
        }
        Button("Copy as Markdown", systemImage: "doc.plaintext") {
            vm.copyKnowledgeMapMarkdown([])
        }
        Button("Save Version…", systemImage: "clock.badge.checkmark") {
            vm.promptSaveCanvasVersion(canvasID: canvas.id)
        }
        .keyboardShortcut("s", modifiers: [.command, .option])
        Button("Versions…", systemImage: "clock.arrow.circlepath") {
            vm.showCanvasVersions(canvasID: canvas.id)
        }
        Button("Publish…", systemImage: "globe") {
            vm.showCanvasPublish(canvasID: canvas.id)
        }
    }
}

/// The glyph a canvas is drawn by in the sidebar's rows.
struct SpaceCanvasGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: KnowledgeMap.symbolName)
            .zoomedSystemFont(size: size, weight: .regular)
    }
}

/// **Rename Canvas**: the name field over whatever asked, filled with the
/// canvas's name.
private struct CanvasRenameAlert: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Binding var canvas: KnowledgeMapCanvas?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Canvas",
                isPresented: Binding(
                    get: { canvas != nil },
                    set: { if !$0 { canvas = nil } }
                ),
                presenting: canvas
            ) { canvas in
                TextField("Name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { vm.renameCanvas(canvas.id, to: draft) }
                    .disabled(KnowledgeMapCanvases.cleanedName(draft) == nil)
            }
            .onChange(of: canvas?.id, initial: true) { _, _ in
                if let canvas { draft = canvas.name }
            }
    }
}

extension View {
    /// Asks for a new name for `canvas` while it is set.
    func canvasRenameAlert(_ canvas: Binding<KnowledgeMapCanvas?>) -> some View {
        modifier(CanvasRenameAlert(canvas: canvas))
    }
}
#endif
