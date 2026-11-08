import AppKit
import PDFKit
import SwiftUI

/// The popover a citation link shows under the pointer in the PDF reader, and
/// at once when the link is clicked: a click reads the reference where it is
/// cited rather than jumping to the reference list (product owner, 2026-09-25: "those
/// references can be shown inline as a popup; without scrolling all the way
/// down"). A link with no entry to show — one PDFKit cannot place, a page
/// link — still takes the reader to where it lands. The card's "Open" opens
/// the cited paper: from the library when it is there, otherwise after adding
/// it (product owner, 2026-09-23: "make clicking the popup open that paper in my
/// library"); a click on the entry's words selects them instead, so they can
/// be highlighted (product owner, 2026-11-04: "please give me the ability to
/// highlight the text of a reference in a popup"). A citation of a range or a
/// list ("5–7") shows every entry it names, one after another (product owner,
/// 2026-11-04: "when i click 5-7, it should show 5 6 and 7; not just 5 and 7").
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
    /// Saves the words selected on the card as a highlight of the same words
    /// on the PDF's page: the reader that owns this view makes it exactly as
    /// it makes a highlight of a selection (`configureHighlighting`). Nil
    /// leaves the card's words selectable but not highlightable.
    var saveHighlight: (@MainActor (PDFSelection, SourceHighlightColor) -> Void)?
    /// The source a page of the document belongs to, for a link seam that
    /// keeps its links by source. A book is one document of many sources.
    var sourceIDOfPage: ((Int) -> String?)?
    /// The seam through which a reference entry's stored record reaches the
    /// card: the entry of the paper's reference list read when the paper was
    /// added (`PaperReferenceLinkService`), one entry a reference, with its
    /// own link, title and authors. The card shows its link first, and its
    /// first author, year and title in place of the words the PDF prints;
    /// with nothing stored, the DOI or address the entry prints, then the
    /// paper Crossref matches it to.
    var referenceForEntry: (@MainActor (ReaderReferenceEntryRef) async -> PaperReference?)?
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
            let cited = await source.entries.entries(for: link)
            guard !cited.isEmpty, !Task.isCancelled, self.hovered === annotation else { return }
            self.show(cited, firstPage: source.firstPage, for: annotation)
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
            if let source {
                let cited = await source.entries.entries(for: link)
                if !cited.isEmpty {
                    guard !Task.isCancelled, let self else { return }
                    self.show(cited, firstPage: source.firstPage, for: annotation)
                    self.pin()
                    return
                }
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


    private func show(_ cited: [PDFReferenceEntries.CitedEntry], firstPage: Int, for annotation: PDFAnnotation) {
        guard !cited.isEmpty, let pdfView, let page = annotation.page, pdfView.window != nil else { return }
        let anchor = pdfView.convert(annotation.bounds, from: page)
        guard pdfView.visibleRect.intersects(anchor) else { return }
        let items = cited.map { makeItem($0, firstPage: firstPage, in: pdfView.document) }
        let card = ReaderReferenceCard(items: items)
        card.activate = { [weak self] item in self?.activate(item) }
        card.highlight = { [weak self] item, range, color in self?.highlight(range, of: item, color: color) }
        card.pressed = { [weak self] in self?.pin() }
        card.openLink = { url in NSWorkspace.shared.open(url) }
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
        for item in items {
            Task { [weak self] in await self?.identify(item) }
        }
    }

    // MARK: The entry's words

    /// One entry of the card: its words, where on the file's pages they are
    /// read from, and the highlights already on them.
    private func makeItem(
        _ cited: PDFReferenceEntries.CitedEntry,
        firstPage: Int,
        in document: PDFDocument?
    ) -> ReaderReferenceEntryItem {
        let sourceID = cited.pieces.first.flatMap { sourceIDOfPage?(firstPage + $0.pageIndex) }
        let item = ReaderReferenceEntryItem(
            number: cited.number,
            text: cited.text,
            firstPage: firstPage,
            sourceID: sourceID
        )
        item.link = ReaderReferenceLink.printed(inReferenceEntry: cited.text)
        // The short form at once from the words; the stored entry refines it (`identify`).
        item.summary = PaperReferenceSummary(entryText: cited.text, stored: nil)
        guard let document, !cited.pieces.isEmpty else { return item }
        // The words as the page's own text reads them, to line the card's up with.
        let pieces = cited.pieces.compactMap { piece -> (pageIndex: Int, range: NSRange, text: String)? in
            guard let text = document.page(at: firstPage + piece.pageIndex)?.string as NSString?,
                  piece.range.location >= 0, NSMaxRange(piece.range) <= text.length else { return nil }
            return (piece.pageIndex, piece.range, text.substring(with: piece.range))
        }
        let map = ReferenceTextMap(display: cited.text, pieces: pieces)
        guard map.isPlaced else { return item }
        item.map = map
        item.canHighlight = saveHighlight != nil
        item.marks = paintedMarks(on: item, map: map, pages: Set(pieces.map(\.pageIndex)), in: document)
        return item
    }

    /// The highlights painted on the pages the entry is read from, as the card
    /// shows them: a highlight made on the page's reference list shows on the
    /// card, and one made on the card is the page's.
    private func paintedMarks(
        on item: ReaderReferenceEntryItem,
        map: ReferenceTextMap,
        pages: Set<Int>,
        in document: PDFDocument
    ) -> [ReaderReferenceMark] {
        var painted: [(pageIndex: Int, range: NSRange, value: NSColor)] = []
        for pageIndex in pages {
            guard let page = document.page(at: item.firstPage + pageIndex) else { continue }
            for annotation in page.annotations
            where ReaderPDFHighlightSupport.isNoteAnnotation(annotation) && (annotation.type ?? "").lowercased().contains("highlight") {
                // The middle of the line box: one drawn a little tall reaches
                // into the lines above and below.
                let rect = annotation.bounds
                guard let selection = page.selection(for: rect.insetBy(dx: 0, dy: rect.height * 0.25)) else { continue }
                for index in 0..<selection.numberOfTextRanges(on: page) {
                    painted.append((pageIndex, selection.range(at: index, on: page), annotation.color))
                }
            }
        }
        return map.displayRanges(marking: painted, in: item.text).map {
            ReaderReferenceMark(range: $0.range, color: $0.value.withAlphaComponent(Self.markOpacity))
        }
    }

    /// How strongly a highlight tints the words, over the card's own ground.
    private static let markOpacity: CGFloat = 0.55

    /// Highlights the words selected on the card: the same words on the page,
    /// saved as the reader saves a selection, in the colour pressed.
    private func highlight(_ range: NSRange, of item: ReaderReferenceEntryItem, color: SourceHighlightColor) {
        guard let map = item.map, let saveHighlight, let document = pdfView?.document else { return }
        var selection: PDFSelection?
        for run in map.pageRuns(forDisplayRange: range) {
            guard let page = document.page(at: item.firstPage + run.pageIndex), let part = page.selection(for: run.range) else { continue }
            if let selection { selection.add(part) } else { selection = part }
        }
        guard let selection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saveHighlight(selection, color)
        // Painted on the page once the highlight is stored; the card shows
        // it now.
        item.marks.append(ReaderReferenceMark(
            range: range,
            color: ReaderPDFHighlightSupport.color(for: color).withAlphaComponent(Self.markOpacity)
        ))
        item.selection = nil
        item.textHandle.clearSelection()
    }

    // MARK: The cited paper

    /// Which paper the card's entry is, and whether the library holds it. A
    /// DOI printed in the entry settles it; an entry without one is matched
    /// against the library's titles, and failing that, against Crossref.
    private func identify(_ item: ReaderReferenceEntryItem) async {
        let stored = await referenceForEntry?(ReaderReferenceEntryRef(sourceID: item.sourceID, number: item.number, text: item.text))
        // The stored entry is one reference, split from the list as the paper prints it, with
        // the link of that reference alone: it wins over an address read off the PDF's words.
        if let url = stored?.linkURL { item.link = url }
        item.summary = PaperReferenceSummary(entryText: stored?.text ?? item.text, stored: stored)
        guard let library else {
            item.library = .notAPaper
            return
        }
        if let href = stored?.linkURL?.absoluteString {
            item.library = await status(ofReference: href, in: library)
            return
        }
        let text = item.text
        if let doi = PDFReferenceEntries.doi(inReferenceEntry: text) {
            item.library = await status(ofReference: "https://doi.org/\(doi)", in: library)
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
            item.library = .inLibrary(sourceID: owned)
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
            item.library = .notAPaper
            return
        }
        // A paper Crossref matched is a link for an entry that prints none.
        if item.link == nil { item.link = URL(string: href) }
        item.library = await status(ofReference: href, in: library)
    }

    private func status(ofReference href: String, in library: StudioViewModel) async -> ReaderReferenceEntryItem.Library {
        if let id = await library.referenceLibraryStatuses(for: [href])[href]?.sourceID {
            return .inLibrary(sourceID: id)
        }
        return .absent(href: href)
    }

    /// "Open": the paper, adding it first when the library lacks it. The add
    /// carries on if the card closes meanwhile, and opens the paper when it
    /// lands.
    private func activate(_ item: ReaderReferenceEntryItem) {
        pin()
        switch item.library {
        case .inLibrary(let sourceID):
            close()
            openSource?(sourceID)
        case .absent(let href):
            guard let library else { return }
            item.library = .adding
            Task { [weak self] in
                let status = await library.addReferenceToLibrary(href)
                if let sourceID = status.sourceID, status.state == .inLibrary {
                    item.library = .inLibrary(sourceID: sourceID)
                    self?.close()
                    self?.openSource?(sourceID)
                } else {
                    item.library = .failed(status.message ?? "The paper could not be added.")
                }
            }
        case .checking, .notAPaper, .adding, .failed:
            break
        }
    }
}

/// A reference entry, as the seam (`ReaderPDFReferencePreview.referenceForEntry`)
/// is asked about it: the source it was read from, when the reader knows it,
/// its number in the reference list when it is numbered, and its text.
struct ReaderReferenceEntryRef: Sendable, Equatable {
    let sourceID: String?
    let number: Int?
    let text: String
}

/// What a citation card shows and can do: the entries a citation names.
@MainActor
final class ReaderReferenceCard {
    let items: [ReaderReferenceEntryItem]
    var activate: (ReaderReferenceEntryItem) -> Void = { _ in }
    var highlight: (ReaderReferenceEntryItem, NSRange, SourceHighlightColor) -> Void = { _, _, _ in }
    /// A press on an entry's words: the card is being used, so it stays.
    var pressed: () -> Void = {}
    var openLink: (URL) -> Void = { _ in }

    init(items: [ReaderReferenceEntryItem]) {
        self.items = items
    }
}

/// One entry of a card.
@MainActor
@Observable
final class ReaderReferenceEntryItem: Identifiable {
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

    let id = UUID()
    let number: Int?
    let text: String
    /// The document page the file's first page is.
    let firstPage: Int
    let sourceID: String?
    var library: Library = .checking
    /// The entry's own address: the DOI or link it prints, what the stored
    /// entry holds, or the paper Crossref matched it to.
    var link: URL?
    /// The entry in a few words: first author, year, title. Read from the words
    /// when the card opens and from the stored entry once it is looked up; with
    /// no title to show, the card shows the words.
    var summary: PaperReferenceSummary?
    /// The highlights on its words.
    var marks: [ReaderReferenceMark] = []
    /// The words selected, with the box they fill.
    var selection: (range: NSRange, rect: CGRect)?
    /// Whether the words are placed on the page, so a highlight of them can be saved.
    var canHighlight = false
    @ObservationIgnored var map: ReferenceTextMap?
    @ObservationIgnored let textHandle = ReaderReferenceTextHandle()

    /// Whether there is anything under the words: an open or add, a state,
    /// or a link.
    var hasFooter: Bool {
        if link != nil { return true }
        switch library {
        case .checking, .notAPaper: return false
        default: return true
        }
    }

    init(number: Int?, text: String, firstPage: Int, sourceID: String?) {
        self.number = number
        self.text = text
        self.firstPage = firstPage
        self.sourceID = sourceID
    }
}

/// Reading an address off a reference entry, and saying it in a few words.
enum ReaderReferenceLink {
    /// The address an entry prints: its DOI, else the first web address in it.
    static func printed(inReferenceEntry text: String) -> URL? {
        if let doi = PDFReferenceEntries.doi(inReferenceEntry: text) {
            return URL(string: "https://doi.org/\(doi)")
        }
        guard let range = text.range(of: #"https?://[^\s<>"]+"#, options: .regularExpression) else { return nil }
        var address = String(text[range])
        // The sentence's closing punctuation, and a parenthesis the address did
        // not open, are not the address's.
        while let last = address.last {
            if ".,;:".contains(last) {
                address.removeLast()
            } else if last == ")", address.filter({ $0 == ")" }).count > address.filter({ $0 == "(" }).count {
                address.removeLast()
            } else {
                break
            }
        }
        return URL(string: address)
    }

    /// The address without its scheme: "doi.org/10.1016/j.cell.2020.01.001".
    static func displayText(for url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

private struct ReaderReferencePreviewCard: View {
    let card: ReaderReferenceCard
    let hoverChanged: (Bool) -> Void

    /// Past this many entries (a long range) the card scrolls instead of
    /// growing off the screen.
    private static let tallest: CGFloat = 400

    var body: some View {
        Group {
            if card.items.count > 3 {
                ScrollView { entries }
                    .frame(height: Self.tallest)
            } else {
                entries
            }
        }
        .frame(width: 360)
        .padding(12)
        .onHover(perform: hoverChanged)
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(card.items) { item in
                ReaderReferenceEntryView(item: item, card: card)
            }
        }
    }
}

private struct ReaderReferenceEntryView: View {
    let item: ReaderReferenceEntryItem
    let card: ReaderReferenceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = item.summary, let title = summary.title {
                VStack(alignment: .leading, spacing: 3) {
                    if let byline = summary.byline {
                        Text(byline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    titleText(title)
                }
            } else {
                words(in: NSRange(location: 0, length: (item.text as NSString).length))
            }
            if item.hasFooter {
                footer
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
        }
    }

    /// The title: the entry's own words on the page when it prints them, so they
    /// can be highlighted as before; a catalog's title it does not print, as text.
    @ViewBuilder
    private func titleText(_ title: String) -> some View {
        let printed = (item.text as NSString).range(of: title, options: [.caseInsensitive, .diacriticInsensitive])
        if printed.location != NSNotFound {
            words(in: printed)
        } else {
            Text(title)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The entry's words in `range` of its text, selectable and highlightable: a
    /// selection and the marks are kept in the whole text's numbering.
    private func words(in range: NSRange) -> some View {
        let shown = (item.text as NSString).substring(with: range)
        let marks = item.marks.compactMap { mark -> ReaderReferenceMark? in
            let overlap = NSIntersectionRange(mark.range, range)
            guard overlap.length > 0 else { return nil }
            return ReaderReferenceMark(range: NSRange(location: overlap.location - range.location, length: overlap.length), color: mark.color)
        }
        return ZStack(alignment: .topLeading) {
            ReaderReferenceText(
                text: shown,
                marks: marks,
                selectionChanged: { selected in
                    item.selection = selected.map {
                        (range: NSRange(location: $0.0.location + range.location, length: $0.0.length), rect: $0.1)
                    }
                },
                pressed: card.pressed,
                handle: item.textHandle
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.canHighlight, let selection = item.selection {
                ReaderReferenceHighlightBar { color in
                    card.highlight(item, selection.range, color)
                }
                .offset(barOffset(over: selection.rect))
            }
        }
    }

    /// Over the selected words, or under them when they are the card's first
    /// line and there is no room above; kept inside the card's width.
    private func barOffset(over rect: CGRect) -> CGSize {
        let x = min(max(rect.midX - ReaderReferenceHighlightBar.width / 2, 0), 360 - ReaderReferenceHighlightBar.width)
        let above = rect.minY - ReaderReferenceHighlightBar.height - 4
        return CGSize(width: x, height: above >= -8 ? above : rect.maxY + 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            action
            Spacer(minLength: 0)
            if let link = item.link {
                Button { card.openLink(link) } label: {
                    Label(ReaderReferenceLink.displayText(for: link), systemImage: "link")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                .help("Open \(link.absoluteString)")
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch item.library {
        case .checking, .notAPaper:
            EmptyView()
        case .inLibrary:
            Button { card.activate(item) } label: { Label("Open", systemImage: "arrow.up.right") }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                .fixedSize()
        case .absent:
            Button { card.activate(item) } label: { Label("Add to Library", systemImage: "plus") }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                .fixedSize()
        case .adding:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Adding…")
            }
            .fixedSize()
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
