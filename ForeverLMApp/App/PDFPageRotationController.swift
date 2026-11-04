import AppKit
import PDFKit
import SwiftUI

/// Turns single pages of the PDF a reader shows, and remembers which.
///
/// The document a reader shows is an in-memory copy (`BookPDFAssembly`) that is
/// never written back, so a turn is only `PDFPage.rotation` on that copy; the
/// file in the library, which iCloud shares, is untouched. What is remembered
/// is the learner's own: one synced preference row per source
/// (`PDFPageRotations`), applied here when the document opens. The row holds
/// the turn on top of the page's own rotation in the file, which is captured
/// before the first change, so a scan stored sideways keeps its correction.
///
/// PDFKit keeps selections, annotations and page bounds in the page's stored
/// orientation whatever its rotation, so highlights, find, citations and
/// reading progress stand unchanged when a page is turned; only what is drawn
/// over the displayed page needs the turn (`ReaderQuestionPageOverlay`).
@MainActor
final class PDFPageRotationController {
    private let document: PDFDocument
    private let owner: PDFPageRotationOwner
    private var rows: [String: PDFPageRotations] = [:]
    /// Each page's own rotation in the file, read before this controller first
    /// changed it.
    private var fileRotation: [Int: Int] = [:]
    /// The view showing the document, for laying it out again after a turn.
    weak var pdfView: PDFView?

    /// `runs` are the sources whose pages the document holds, by the page each
    /// begins on. Reads the stored turns and applies them at once, before the
    /// view first lays the document out.
    init(document: PDFDocument, runs: [PDFPageRotationOwner.Run]) {
        self.document = document
        self.owner = PDFPageRotationOwner(runs: runs)
        for run in owner.runs {
            let key = PDFPageRotations.key(sourceID: run.sourceID)
            let row = PDFPageRotations(storedValue: UserDefaults.standard.object(forKey: key))
            guard !row.isEmpty else { continue }
            rows[run.sourceID] = row
            for (pageInSource, degrees) in row.turns {
                guard let index = owner.page(ofSource: run.sourceID, pageInSource: pageInSource),
                      index >= 0, index < document.pageCount,
                      // A turn filed under a chapter that no longer holds the
                      // page is left alone, not applied to another chapter's.
                      owner.home(ofPage: index)?.sourceID == run.sourceID else { continue }
                apply(degrees, toPageAt: index)
            }
        }
    }

    // MARK: Turning

    /// Turns the page the view is on a quarter turn: 90 clockwise, -90
    /// counterclockwise. The page on screen is the one the position reads.
    func turnCurrentPage(by degrees: Int) {
        guard let pdfView, let page = pdfView.currentPage else { return }
        turn(page, by: degrees)
    }

    func turn(_ page: PDFPage, by degrees: Int) {
        let index = document.index(for: page)
        guard index >= 0, index != NSNotFound, let home = owner.home(ofPage: index) else { return }
        let row = (rows[home.sourceID] ?? PDFPageRotations()).turned(home.pageInSource, by: degrees)
        rows[home.sourceID] = row
        apply(row.degrees(of: home.pageInSource), toPageAt: index)
        // The row's absence is an upright source; the store drops a no-op.
        PreferenceStore.set(row.storedValue, forKey: PDFPageRotations.key(sourceID: home.sourceID))
        relayout(keeping: page)
    }

    private func apply(_ degrees: Int, toPageAt index: Int) {
        guard let page = document.page(at: index) else { return }
        let base = fileRotation[index] ?? page.rotation
        fileRotation[index] = base
        page.rotation = (base + degrees) % 360
    }

    /// PDFKit does not lay a document out again when a page's rotation
    /// changes, so the view is asked to, and the page stays where the learner
    /// was reading it. Marks drawn over the pages are told to place themselves
    /// again: a half turn changes no page's size, so nothing else would.
    private func relayout(keeping page: PDFPage) {
        guard let pdfView else { return }
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
        if let documentView = pdfView.documentView { Self.layOutAgain(documentView) }
    }

    private static func layOutAgain(_ view: NSView) {
        if view is ReaderQuestionPageOverlay { view.needsLayout = true }
        for subview in view.subviews { layOutAgain(subview) }
    }

    // MARK: The page's context menu

    /// Rotate Page Right and Left for the page under a right-click, after the
    /// menu PDFKit already built.
    func addMenuItems(to menu: NSMenu, page: PDFPage?) {
        guard let page else { return }
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        menu.addItem(PDFPageTurnMenuItem(
            title: "Rotate Page Right", symbol: "rotate.right"
        ) { [weak self, weak page] in
            if let page { self?.turn(page, by: 90) }
        })
        menu.addItem(PDFPageTurnMenuItem(
            title: "Rotate Page Left", symbol: "rotate.left"
        ) { [weak self, weak page] in
            if let page { self?.turn(page, by: -90) }
        })
    }
}

/// A menu item that runs a closure, for a menu that is built per press.
private final class PDFPageTurnMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension NSEvent {
    /// ⌘R turns the page on screen a quarter clockwise and ⌘L a quarter back,
    /// as Preview does; nil for any other key.
    var readerPageTurnShortcut: Int? {
        guard modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch charactersIgnoringModifiers?.lowercased() {
        case "r": return 90
        case "l": return -90
        default: return nil
        }
    }
}

/// Rotate Page Right and Left in a reader's ⋯ menu, for the page on screen.
/// The keys are ⌘R and ⌘L while the page has the keyboard
/// (`FindablePDFView.performKeyEquivalent`); the hints are listed here as the
/// Go to Page item lists its own.
struct ReaderRotatePageMenuItems: View {
    @ObservedObject var bridge: ReaderBookNavigationBridge

    var body: some View {
        Button {
            bridge.turnPage(by: 90)
        } label: {
            Label("Rotate Page Right", systemImage: "rotate.right")
        }
        .keyboardShortcut("r", modifiers: .command)
        Button {
            bridge.turnPage(by: -90)
        } label: {
            Label("Rotate Page Left", systemImage: "rotate.left")
        }
        .keyboardShortcut("l", modifiers: .command)
    }
}
