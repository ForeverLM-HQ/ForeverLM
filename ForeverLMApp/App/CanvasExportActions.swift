#if os(macOS)
import AppKit
import SwiftUI

// MARK: - What the canvas menu does with a canvas
//
// Export as Image…, Copy as Markdown, Save Version…, Versions… and Publish…
// (docs/knowledge-map-design.md, "Versions, export and publishing"). A menu
// cannot hold a sheet, and the menu is drawn in places that have none to offer
// (a row's right-click, the chrome line's), so a name is asked and a sheet
// shown over the window in front, as `PageSpaceNamePrompt` asks for a space's.

extension StudioViewModel {
    /// **Export as Image…**: the open canvas drawn to a PNG at `scale` (2 is
    /// Retina) and saved where the learner chooses, Downloads first, named
    /// for the canvas.
    func exportCanvasImage(canvasID: String, scale: Double) {
        Task {
            do {
                let data = try await exportCanvasImageData(canvasID: canvasID, scale: scale)
                guard let url = await CanvasImageExport.chooseDestination(name: canvasDisplayName(canvasID)) else { return }
                try await PageExport.write(data, to: url)
                showToast("Exported \(url.lastPathComponent)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// **Copy as Markdown**: the open canvas, or `refs` of it, on the
    /// pasteboard as Markdown.
    func copyKnowledgeMapMarkdown(_ refs: [String]) {
        // The canvas of the window it was chosen in, taken before the task
        // starts: the menu's own scope is gone by then.
        task(in: activeWindowState) {
            let text = await self.canvasMarkdown(refs: refs)
            guard !text.isEmpty else {
                self.showToast(refs.isEmpty ? "Nothing on the canvas to copy" : "Nothing to copy")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.showToast("Copied as Markdown")
        }
    }

    /// **Save Version…**: asks for a name over the window in front, then
    /// keeps the canvas as it is now under it; `saved` runs once it is kept
    /// (the Versions list reloads).
    func promptSaveCanvasVersion(canvasID: String, saved: (() -> Void)? = nil) {
        CanvasVersionNamePrompt.ask(canvasName: canvasDisplayName(canvasID)) { [weak self] name in
            guard let self else { return }
            Task {
                do {
                    try await self.saveCanvasVersion(canvasID: canvasID, name: name)
                    saved?()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// **Versions…**: the list of the canvas's versions, as a sheet.
    func showCanvasVersions(canvasID: String) {
        CanvasSheetPresenter.present(self, size: NSSize(width: 520, height: 460)) { close in
            CanvasVersionsSheet(canvasID: canvasID, onClose: close)
        }
    }
}

/// The save panel for Export as Image.
@MainActor
enum CanvasImageExport {
    /// Asks where the picture goes, Downloads first; nil when the learner
    /// cancels.
    static func chooseDestination(name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = CanvasExport.fileName(for: name)
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

/// Save Version…'s one question, asked over the window in front: an alert with
/// one field, as New Space… asks a space's name. A name left empty is the
/// date.
@MainActor
enum CanvasVersionNamePrompt {
    static func ask(canvasName: String, then save: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save Version"
        alert.informativeText = "Keeps ‘\(canvasName)’ as it is now on this Mac, to come back to from Versions…."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Name this version"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            save(field.stringValue)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Shows a SwiftUI view as a sheet over the window in front, closed by the
/// view's own `close`.
@MainActor
enum CanvasSheetPresenter {
    static func present<Content: View>(
        _ vm: StudioViewModel,
        size: NSSize,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let box = SheetBox()
        let close: () -> Void = { [box, weak parent] in
            guard let window = box.window else { return }
            parent?.endSheet(window)
            box.window = nil
        }
        let hosting = NSHostingController(rootView: content(close).environment(vm).frame(width: size.width, height: size.height))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        box.window = window
        parent.beginSheet(window)
    }

    /// Holds the sheet's window until it is closed, so the close closure and
    /// the window do not keep each other alive.
    private final class SheetBox {
        var window: NSWindow?
    }
}
#endif
