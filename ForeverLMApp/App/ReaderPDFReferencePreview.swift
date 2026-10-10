import AppKit
import PDFKit
import SwiftUI

/// The popover a citation link shows under the pointer in the PDF reader, and
/// at once when the link is clicked: a click reads the reference where it is
/// cited rather than jumping to the reference list (product owner, 2026-09-25: "those
/// references can be shown inline as a popup; without scrolling all the way
/// down"). A link with no entry to show — one PDFKit cannot place, a page
/// link — still takes the reader to where it lands. Clicking the card opens
/// the cited paper: from the library when it is there, otherwise after adding
/// it (product owner, 2026-09-23: "make clicking the popup open that paper in my
/// library").
@MainActor
final class ReaderPDFReferencePreview {
    /// Long enough that sweeping the pointer across a paragraph opens nothing.
    private static let hoverDelay: Duration = .milliseconds(350)
    /// How long the card outlives the pointer leaving the link, so it can be
    /// reached and clicked.
    private static let leaveGrace: Duration = .milliseconds(300)

    private weak var pdfView: PDFView?
    /// The link under the pointer.
    private weak var hovered: PDFAnnotation?
    /// The link the open card is for.
    private weak var shownFor: PDFAnnotation?
    private var pointerInCard = false
    /// A card opened by a click, or clicked into, stays until a click
    /// elsewhere, Escape, or a scroll that moves its citation. Only a card the
    /// pointer merely passed over closes when it leaves (product owner, 2026-09-25:
    /// "when i click it, it disappears super quickly").
    private var pinned = false
    private var pendingShow: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?
    private var popover: NSPopover?
    /// Closes the popover when the page scrolls or zooms under it: it is
    /// anchored where the link was, and the pointer may not move to say so.
    private var scrollObserver: NSObjectProtocol?
    /// Clears the state above when a pinned card closes itself.
    private var closeObserver: NSObjectProtocol?
    /// The document the entries below were made for, and each file's
    /// entries by path ("" for `documentData`).
    private var entriesDocument: ObjectIdentifier?
    private var entriesByFile: [String: PDFReferenceEntries] = [:]
    /// The bytes behind a document opened from memory; see `source(ofPage:in:)`.
    var documentData: Data?
    /// The chapter files a document assembled in memory was copied from, by
    /// the pages each fills. Every local PDF opens that way, a lone paper as a
    /// book of one chapter, so this is where most papers' links are read.
    var chapterFiles: [BookPDFChapterRange] = []
    /// The library the card looks the cited paper up in and adds it to.
    weak var library: StudioViewModel?
    /// Opens a library source: the Reader's own navigation, or a window of its
    /// own when the PDF is in a Source Reader window.
    var openSource: ((String) -> Void)?
    /// What Crossref said an entry without a DOI names — a DOI address, or
    /// nil for nothing it could vouch for — so hovering it again asks nobody.
    private var identified: [String: String?] = [:]

    /// Created in the PDF coordinator's stored-property initialiser, which is
    /// not on any actor; everything it does afterwards is.
    nonisolated init() {}

    func attach(to pdfView: FindablePDFView) {
        self.pdfView = pdfView
        pdfView.linkHoverChanged = { [weak self] annotation in
            MainActor.assumeIsolated { self?.linkHover(annotation) }
        }
        pdfView.linkClicked = { [weak self] annotation in
            MainActor.assumeIsolated { self?.linkClick(annotation) ?? false }
        }
    }

    func detach() {
        (pdfView as? FindablePDFView)?.linkHoverChanged = nil
        (pdfView as? FindablePDFView)?.linkClicked = nil
        hovered = nil
        pendingShow?.cancel()
        close()
        pdfView = nil
    }

    func documentChanged() {
        hovered = nil
        pendingShow?.cancel()
        close()
        entriesDocument = nil
        entriesByFile = [:]
    }

    // MARK: Showing and closing

    private func linkHover(_ annotation: PDFAnnotation?) {
        guard annotation !== hovered else { return }
        hovered = annotation
        pendingShow?.cancel()
        pendingShow = nil
        guard let annotation else {
            scheduleClose()
            return
        }
        if annotation === shownFor {
            pendingClose?.cancel()
            return
        }
        // On the way to a pinned card the pointer may cross other citations.
        guard !pinned else { return }
        close()
        guard let pdfView, let document = pdfView.document, let page = annotation.page else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound, let source = source(ofPage: pageIndex, in: document) else { return }
        let link = PDFReferenceEntries.Link(pageIndex: pageIndex - source.firstPage, bounds: annotation.bounds)
        pendingShow = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, let self else { return }
            guard let text = await source.entries.entry(for: link), !Task.isCancelled, self.hovered === annotation else { return }
            self.show(text, for: annotation)
        }
    }

    /// A click on a link within the document. Takes every such link, so
    /// PDFKit never jumps first: the card shows without the hover delay, and
    /// a link with nothing to show goes to where it lands. A web link is
    /// left to PDFKit.
    private func linkClick(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.url == nil, !(annotation.action is PDFActionURL),
              annotation.destination != nil || annotation.action is PDFActionGoTo else { return false }
        hovered = annotation
        pendingShow?.cancel()
        pendingShow = nil
        if annotation === shownFor {
            pin()
            return true
        }
        close()
        guard let pdfView, let document = pdfView.document, let page = annotation.page else { return false }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return false }
        let source = source(ofPage: pageIndex, in: document)
        let link = PDFReferenceEntries.Link(pageIndex: pageIndex - (source?.firstPage ?? 0), bounds: annotation.bounds)
        pendingShow = Task { [weak self] in
            if let source, let text = await source.entries.entry(for: link) {
                guard !Task.isCancelled, let self else { return }
                self.show(text, for: annotation)
                self.pin()
                return
            }
            // Read in the file's own page numbering; the document's is further on
            // by the pages of the chapters before it.
            let landing = await source?.entries.landing(for: link).map {
                PDFReferenceEntries.Landing(pageIndex: $0.pageIndex + (source?.firstPage ?? 0), point: $0.point)
            }
            guard !Task.isCancelled, let self else { return }
            self.go(to: landing, orFollow: annotation, in: document)
        }
        return true
    }

    /// Where a link without an entry leads: the landing read from the file,
    /// else the destination PDFKit itself holds for the link.
    private func go(to landing: PDFReferenceEntries.Landing?, orFollow annotation: PDFAnnotation, in document: PDFDocument) {
        guard let pdfView, pdfView.document === document else { return }
        if let landing, let page = document.page(at: landing.pageIndex) {
            pdfView.go(to: PDFDestination(page: page, at: landing.point))
        } else if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination {
            pdfView.go(to: destination)
        }
    }

    private func cardHover(_ inside: Bool) {
        pointerInCard = inside
        if inside {
            pendingClose?.cancel()
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        guard popover != nil, !pinned else { return }
        pendingClose?.cancel()
        pendingClose = Task { [weak self] in
            try? await Task.sleep(for: Self.leaveGrace)
            guard !Task.isCancelled, let self, !self.pinned, !self.pointerInCard, !self.pointerIsOverCard,
                  self.hovered == nil || self.hovered !== self.shownFor else { return }
            self.close()
        }
    }

    /// Where the pointer really is. SwiftUI's hover report from inside the
    /// popover is not enough on its own: the reader's tracking area says the
    /// pointer left as soon as it crosses onto the popover's window, and the
    /// card's own hover may not have arrived by the time the grace runs out.
    private var pointerIsOverCard: Bool {
        guard let window = popover?.contentViewController?.view.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    /// Keeps the open card until a click elsewhere or Escape, which a
    /// transient popover handles itself.
    private func pin() {
        guard let popover else { return }
        pinned = true
        pendingClose?.cancel()
        pendingClose = nil
        popover.behavior = .transient
    }

    private func close() {
        pendingClose?.cancel()
        pendingClose = nil
        popover?.performClose(nil)
        cardClosed()
    }

    private func cardClosed() {
        pendingClose?.cancel()
        pendingClose = nil
        popover = nil
        shownFor = nil
        pointerInCard = false
        pinned = false
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    /// The private copy a page's links are read from, and the document page
    /// that copy's first page is: the document's file when it has one; for a
    /// document assembled from chapter files, the chapter the page came from,
    /// numbered from the chapter's first page; otherwise the bytes the reader
    /// opened the document from. Never the live document's
    /// `dataRepresentation()`, which serialises every page on the main actor.
    /// (product owner, 2026-09-25: a Cell paper's citations showed no card, since
    /// every local PDF is assembled and this once read only a document's file.)
    private func source(ofPage pageIndex: Int, in document: PDFDocument) -> (entries: PDFReferenceEntries, firstPage: Int)? {
        let id = ObjectIdentifier(document)
        if entriesDocument != id {
            entriesDocument = id
            entriesByFile = [:]
        }
        let key: String
        let firstPage: Int
        let origin: PDFReferenceEntries.Origin
        if let url = document.documentURL {
            (key, firstPage, origin) = (url.path, 0, .file(url))
        } else if let chapter = Self.chapter(ofPage: pageIndex, in: chapterFiles, documentPageCount: document.pageCount) {
            (key, firstPage, origin) = (chapter.path, chapter.pageRange.lowerBound, .file(URL(fileURLWithPath: chapter.path)))
        } else if let documentData {
            (key, firstPage, origin) = ("", 0, .bytes(documentData))
        } else {
            return nil
        }
        if let made = entriesByFile[key] { return (made, firstPage) }
        let made = PDFReferenceEntries(origin)
        entriesByFile[key] = made
        return (made, firstPage)
    }

    /// The chapter file a page of an assembled document was copied from; nil
    /// when the chapters do not fill the document, being another document's.
    nonisolated static func chapter(
        ofPage pageIndex: Int,
        in chapterFiles: [BookPDFChapterRange],
        documentPageCount: Int
    ) -> BookPDFChapterRange? {
        guard chapterFiles.last?.pageRange.upperBound == documentPageCount else { return nil }
        return chapterFiles.first { $0.pageRange.contains(pageIndex) }
    }

    private func show(_ text: String, for annotation: PDFAnnotation) {
        guard let pdfView, let page = annotation.page, pdfView.window != nil else { return }
        let anchor = pdfView.convert(annotation.bounds, from: page)
        guard pdfView.visibleRect.intersects(anchor) else { return }
        let card = ReaderReferenceCard(text: text)
        card.activate = { [weak self, weak card] in
            guard let self, let card else { return }
            self.activate(card)
        }
        let content = NSHostingController(rootView: ReaderReferencePreviewCard(card: card) { [weak self] inside in
            self?.cardHover(inside)
        })
        // Sized before it is shown: a popover that learns its height from
        // SwiftUI afterwards grows away from the link it points at. Later
        // changes (the footer arriving) resize it in place.
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = content.view.fittingSize
        popover.contentViewController = content
        popover.show(relativeTo: anchor, of: pdfView, preferredEdge: .maxY)
        self.popover = popover
        shownFor = annotation
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let self, let popover, self.popover === popover else { return }
                self.cardClosed()
            }
        }
        if let clipView = pdfView.enclosedScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            // Only a scroll or zoom that moves the citation: the clip view
            // also reports bounds that did not change.
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak pdfView, weak annotation, weak page] _ in
                MainActor.assumeIsolated {
                    guard let self, let pdfView, let annotation, let page else { return }
                    let now = pdfView.convert(annotation.bounds, from: page)
                    if abs(now.minX - anchor.minX) > 2 || abs(now.minY - anchor.minY) > 2 { self.close() }
                }
            }
        }
        Task { [weak self] in await self?.identify(card) }
    }

    // MARK: The cited paper

    /// Which paper the card's entry is, and whether the library holds it. A
    /// DOI printed in the entry settles it; an entry without one is matched
    /// against the library's titles, and failing that, against Crossref.
    private func identify(_ card: ReaderReferenceCard) async {
        guard let library else {
            card.library = .notAPaper
            return
        }
        let text = card.text
        if let doi = PDFReferenceEntries.doi(inReferenceEntry: text) {
            card.library = await status(ofReference: "https://doi.org/\(doi)", in: library)
            return
        }
        let titles = library.articles.map { (id: $0.id, title: $0.title) }
        let owned = await Task.detached(priority: .userInitiated) {
            titles
                .filter { SlideCitationService.referenceEntry(text, printsTitle: $0.title) }
                .max { $0.title.count < $1.title.count }?
                .id
        }.value
        if let owned {
            card.library = .inLibrary(sourceID: owned)
            return
        }
        let href: String?
        if let known = identified[text] {
            href = known
        } else {
            href = await SlideCitationService.bestMatch(forReferenceEntry: text).map { "https://doi.org/\($0.doi)" }
            identified[text] = href
        }
        guard let href else {
            card.library = .notAPaper
            return
        }
        card.library = await status(ofReference: href, in: library)
    }

    private func status(ofReference href: String, in library: StudioViewModel) async -> ReaderReferenceCard.Library {
        if let id = await library.referenceLibraryStatuses(for: [href])[href]?.sourceID {
            return .inLibrary(sourceID: id)
        }
        return .absent(href: href)
    }

    /// The click: open the paper, adding it first when the library lacks it.
    /// The add carries on if the card closes meanwhile, and opens the paper
    /// when it lands.
    private func activate(_ card: ReaderReferenceCard) {
        pin()
        switch card.library {
        case .inLibrary(let sourceID):
            close()
            openSource?(sourceID)
        case .absent(let href):
            guard let library else { return }
            card.library = .adding
            Task { [weak self] in
                let status = await library.addReferenceToLibrary(href)
                if let sourceID = status.sourceID, status.state == .inLibrary {
                    card.library = .inLibrary(sourceID: sourceID)
                    self?.close()
                    self?.openSource?(sourceID)
                } else {
                    card.library = .failed(status.message ?? "The paper could not be added.")
                }
            }
        case .checking, .notAPaper, .adding, .failed:
            break
        }
    }
}

/// What a citation card shows and can do.
@MainActor
@Observable
final class ReaderReferenceCard {
    enum Library: Equatable {
        /// Still finding out which paper the entry is.
        case checking
        /// Nothing the card can open: an affiliation, a caption, a work no
        /// catalog vouches for.
        case notAPaper
        case inLibrary(sourceID: String)
        /// A paper the library lacks, by its DOI address.
        case absent(href: String)
        case adding
        case failed(String)
    }

    let text: String
    var library: Library = .checking
    @ObservationIgnored var activate: () -> Void = {}

    init(text: String) {
        self.text = text
    }

    var opens: Bool {
        switch library {
        case .inLibrary, .absent: true
        default: false
        }
    }
}

private struct ReaderReferencePreviewCard: View {
    let card: ReaderReferenceCard
    let hoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            if card.opens {
                Button(action: card.activate) { content }
                    .buttonStyle(.hoverWash(cornerRadius: 8, inset: -6))
            } else {
                content
            }
        }
        .textSelection(.disabled)
        .frame(width: 360)
        .padding(12)
        .onHover(perform: hoverChanged)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var footer: some View {
        switch card.library {
        case .checking, .notAPaper:
            EmptyView()
        case .inLibrary:
            Label("Open", systemImage: "arrow.up.right")
        case .absent:
            Label("Add to Library", systemImage: "plus")
        case .adding:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Adding…")
            }
        case .failed(let message):
            Text(message)
        }
    }
}

private struct ReaderOpensCitedSourceKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// How a PDF reader opens the paper a citation card names. Unset, the
    /// Studio's Reader moves to it; a Source Reader window opens another.
    var readerOpensCitedSource: ((String) -> Void)? {
        get { self[ReaderOpensCitedSourceKey.self] }
        set { self[ReaderOpensCitedSourceKey.self] = newValue }
    }
}
