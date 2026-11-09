#if os(macOS)
import AppKit
import PDFKit

/// Figure mentions in a paper's text as links: a click on "Extended Data
/// Fig. 1c–g" or "(Fig. 2a, b)" opens that figure, cropped, in the lightbox a
/// chat picture opens in (product owner, 2026-11-08: "whenever e.g. 'Extended
/// Data Fig. 1c-g' is mentioned in parentheses in a paper; i can just click
/// that and it will open that figure? make that the case for all figures in
/// the library").
///
/// The words are found in each page's text as the page comes into view
/// (`PrintedFigureMentions`) and matched against the paper's figure index; only
/// a mention of a figure the index has becomes a link, so nothing clickable
/// leads nowhere. The links are link annotations on the in-memory pages, like
/// the walkthrough's outline: never written to the file, taken by
/// `FindablePDFView`'s link click ahead of any link the PDF itself prints
/// there (Nature's own "Fig. 1" links only jump to the figure's page).
@MainActor
final class ReaderFigureMentionLinks {
    static let annotationUserName = "foreverlm-figure-mention"

    private struct Target {
        let sourceID: String
        /// The label as the paper's figure index spells it.
        let label: String
    }

    private weak var pdfView: FindablePDFView?
    private weak var vm: StudioViewModel?
    /// The sources the document's pages belong to: the one paper, or a
    /// book's chapters.
    private var sections: () -> [PDFDocumentSection] = { [] }
    private var targets: [ObjectIdentifier: Target] = [:]
    private var linkedPages: Set<Int> = []
    /// Each source's index labels once read; an empty list for a source with
    /// no figures, or one that is not a paper.
    private var labelsBySource: [String: [String]] = [:]
    private var loading: Set<String> = []
    private var resolvers: [String: WalkthroughAnchorResolver] = [:]
    private var visiblePagesObserver: NSObjectProtocol?
    private var opening: Task<Void, Never>?

    /// Created in the PDF coordinator's stored-property initialiser, which is
    /// not on any actor; everything it does afterwards is.
    nonisolated init() {}

    /// Call after `ReaderPDFReferencePreview.attach`: a figure mention's link
    /// is taken here, every other link passed on to the citation card.
    func attach(to pdfView: FindablePDFView, vm: StudioViewModel, sections: @escaping () -> [PDFDocumentSection]) {
        self.pdfView = pdfView
        self.vm = vm
        self.sections = sections
        let clickedElsewhere = pdfView.linkClicked
        pdfView.linkClicked = { [weak self] annotation in
            MainActor.assumeIsolated {
                if let self, let target = self.targets[ObjectIdentifier(annotation)] {
                    self.open(target)
                    return true
                }
                return clickedElsewhere?(annotation) ?? false
            }
        }
        let hoveredElsewhere = pdfView.linkHoverChanged
        pdfView.linkHoverChanged = { [weak self] annotation in
            MainActor.assumeIsolated {
                // A figure mention shows no citation card.
                if let annotation, self?.targets[ObjectIdentifier(annotation)] != nil {
                    hoveredElsewhere?(nil)
                } else {
                    hoveredElsewhere?(annotation)
                }
            }
        }
        visiblePagesObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewVisiblePagesChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.linkVisiblePages() }
        }
        linkVisiblePages()
    }

    func update(sections: @escaping () -> [PDFDocumentSection]) {
        self.sections = sections
    }

    func detach() {
        if let visiblePagesObserver { NotificationCenter.default.removeObserver(visiblePagesObserver) }
        visiblePagesObserver = nil
        opening?.cancel()
        clear()
        pdfView = nil
    }

    /// The document changed under the view: its links went with the old one.
    func documentChanged() {
        clear()
        linkVisiblePages()
    }

    private func clear() {
        for (page, annotation) in added { page.removeAnnotation(annotation) }
        added = []
        targets = [:]
        linkedPages = []
        labelsBySource = [:]
        loading = []
        resolvers = [:]
    }

    private var added: [(page: PDFPage, annotation: PDFAnnotation)] = []

    // MARK: Linking

    private func linkVisiblePages() {
        guard let pdfView, let document = pdfView.document else { return }
        let sections = sections()
        for page in pdfView.visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound, !linkedPages.contains(index),
                  let section = sections.first(where: { $0.pageRange.contains(index) }) else { continue }
            guard let labels = labelsBySource[section.sourceID] else {
                load(section.sourceID)
                continue
            }
            linkedPages.insert(index)
            guard !labels.isEmpty else { continue }
            link(page, sourceID: section.sourceID, labels: labels)
        }
    }

    /// The paper's figure index, read once: as stored when current, else
    /// from the PDF's captions (free: no model).
    private func load(_ sourceID: String) {
        guard !loading.contains(sourceID), let vm else { return }
        loading.insert(sourceID)
        Task { [weak self, weak vm] in
            guard let vm else { return }
            var labels: [String] = []
            var resolver: WalkthroughAnchorResolver?
            if let article = await vm.persistedArticle(forLinkToken: sourceID), article.sourceType == .paper,
               let figures = try? await vm.paperFigureIndexer.figuresForReading(sourceID: sourceID) {
                labels = figures.map(\.figureLabel)
                let path = await Task.detached(priority: .userInitiated) { article.resolvedLocalPath }.value
                resolver = WalkthroughAnchorResolver(figures: figures, pdfPath: path)
            }
            // Not when the document changed while the index was read.
            guard let self, self.loading.contains(sourceID) else { return }
            self.loading.remove(sourceID)
            self.labelsBySource[sourceID] = labels
            self.resolvers[sourceID] = resolver
            self.linkVisiblePages()
        }
    }

    private func link(_ page: PDFPage, sourceID: String, labels: [String]) {
        guard let text = page.string, !text.isEmpty else { return }
        for mention in PrintedFigureMentions.mentions(in: text) {
            guard let label = PrintedFigureMentions.matchingLabel(mention.label, among: labels),
                  let selection = page.selection(for: mention.range) else { continue }
            let target = Target(sourceID: sourceID, label: label)
            // A mention broken across lines is a link on each line.
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                annotation.userName = Self.annotationUserName
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                annotation.shouldPrint = false
                page.addAnnotation(annotation)
                added.append((page, annotation))
                targets[ObjectIdentifier(annotation)] = target
            }
        }
    }

    // MARK: Opening

    /// The figure, cropped from its page, in the lightbox over the Reader's
    /// window, titled by its printed title; the figure's page when the page
    /// yields no crop.
    private func open(_ target: Target) {
        guard let pdfView, let resolver = resolvers[target.sourceID],
              let section = sections().first(where: { $0.sourceID == target.sourceID }) else { return }
        let window = pdfView.window
        let pixelSize = ReaderWalkthroughSpotlight.lightboxLensPixelSize(for: window?.screen)
        let maximumScale = ReaderWalkthroughSpotlight.lightboxLensMaximumScale
        opening?.cancel()
        opening = Task { [weak self] in
            guard let found = await resolver.figureLens(
                labelled: target.label,
                pixelSize: pixelSize,
                maximumScale: maximumScale
            ), !Task.isCancelled, let self, let pdfView = self.pdfView else { return }
            if let image = found.image {
                let title = PaperFigureCaptionTitle.title(from: found.caption)
                ChatImageLightbox.present(
                    ChatSourceImage(data: image, mediaType: "image/png"),
                    title: title.map { "\(target.label): \($0)" } ?? target.label,
                    over: window
                )
            } else if let page = pdfView.document?.page(at: section.pageRange.lowerBound + found.pageIndex) {
                pdfView.go(to: page)
            }
        }
    }
}
#endif
