import PDFKit
import SwiftUI

// The paper reader's primary content, and a PDF book chapter's. It fetches the
// same original PDF the Mac reader opens, caches it through
// MobileSourceFileStore, and renders it directly with PDFKit: for a chapter kept
// as a run of its book's pages, a document of just those pages.
struct MobileSourcePDFView: View {
    let source: MobileCloudSource
    var highlights: [SourceHighlight] = []
    /// Set by a caller that has something to fall back to — a book chapter can be
    /// read as text when its PDF cannot be fetched, so it takes over the failure
    /// instead of leaving the reader on a dead end. Papers have no text-only
    /// rendering worth showing and keep the failure UI below.
    var onUnavailable: (() -> Void)?
    /// A paper's way to the text when the document cannot be had at all (no PDF, kept on the Mac, not
    /// uploaded yet), so the paper is still read; other failures keep the failure screen and Try Again.
    var onNoPDF: (() -> Void)?
    var onCreateHighlight: ((MobileReaderHighlightSelection) -> Void)?
    var onOpenHighlight: ((String) -> Void)?
    /// The reader's find bar, when it has one; the PDF view is its performer
    /// while the document is on screen. See `MobileReaderFind.swift`.
    var find: MobileReaderFindState? = nil
    /// Opens the library paper a citation's card names.
    var onOpenCitedSource: ((MobileCloudSource) -> Void)? = nil

    @State private var state: LoadState = .loading
    @StateObject private var referenceCards = MobileReaderReferenceCards()

    private enum LoadState {
        case loading
        case ready(MobileSourcePDF, PDFDocument)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Downloading PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let file, let document):
                MobilePDFKitView(
                    file: file,
                    document: document,
                    highlights: highlights,
                    find: find,
                    referenceCards: referenceCards,
                    onCreateHighlight: onCreateHighlight,
                    onOpenHighlight: onOpenHighlight
                )
                    // A popover at the citation on iPad; a sheet on iPhone.
                    .popover(
                        item: $referenceCards.card,
                        attachmentAnchor: .rect(.rect(referenceCards.card?.anchor ?? .zero))
                    ) { card in
                        MobileReaderReferenceCardView(card: card) { cited in
                            referenceCards.card = nil
                            onOpenCitedSource?(cited)
                        }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    }
                    .ignoresSafeArea(edges: .bottom)
            case .failed(let message):
                // A source marked paywalled has no document to fetch by
                // definition, so the fetch error is noise: name the actual
                // reason and the one thing that fixes it. Try Again stays —
                // the Mac may have attached the PDF since this row synced.
                ContentUnavailableView {
                    Label(
                        source.isPaywalled ? "Behind a Paywall" : "PDF Unavailable",
                        systemImage: source.isPaywalled ? "lock" : "doc.viewfinder"
                    )
                } description: {
                    Text(
                        source.isPaywalled
                            ? "No PDF synced for this source. Attach one on your Mac to read it here."
                            : message
                    )
                } actions: {
                    Button("Try Again") {
                        state = .loading
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task(id: source.id) { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let file = try await MobileSourceFileStore.shared.fetchPDF(
                sourceID: source.id,
                relativePath: MobileSourceFilePath.relativePDFPath(
                    localFilePath: source.localFilePath,
                    url: source.url
                )
            )
            // Opening reads the file synchronously — cheap for the cached local
            // copy, but kept off the main actor anyway. A chapter whose pages its
            // book does not hold fails here, onto the chapter's text.
            let document = try await Task.detached(priority: .userInitiated) {
                try file.document()
            }.value
            guard !Task.isCancelled else { return }
            state = .ready(file, document)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if let onNoPDF, let fileError = error as? MobileSourceFileError, fileError.leavesOnlyText {
                onNoPDF()
            } else if let onUnavailable {
                onUnavailable()
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

final class MobileHighlightPDFView: PDFView {
    var onCreateHighlight: ((MobileReaderHighlightSelection) -> Void)?
    var onOpenHighlight: ((String) -> Void)?
    /// A tap on a link inside the document — a citation, a figure — for the
    /// reference card; true when it was taken, so PDFKit does not also jump.
    var onTapInternalLink: ((PDFAnnotation) -> Bool)?

    private lazy var linkTapDelegate = LinkTapDelegate(view: self)
    /// When a link tap was taken: PDFKit's own link handling is held off
    /// around it, whichever way it would have jumped.
    private var linkTapTakenAt: Date?
    private var followingLink = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let linkTap = UITapGestureRecognizer(target: self, action: #selector(openLinkAtTap(_:)))
        linkTap.delegate = linkTapDelegate
        addGestureRecognizer(linkTap)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAnnotationAtTap(_:))))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        let action = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.captureSelection()
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [action]), atStartOfMenu: .root)
    }

    private func captureSelection() {
        guard let selection = currentSelection,
              let page = selection.pages.first,
              let document,
              let pageIndex = Optional(document.index(for: page)), pageIndex >= 0 else { return }
        let quote = MobileReaderText.cleanedSelection(selection.string ?? "")
        guard !quote.isEmpty else { return }
        let rects = selection.selectionsByLine()
            .filter { $0.pages.first === page }
            .map { $0.bounds(for: page) }
            .filter { !$0.isEmpty && !$0.isNull }
        guard !rects.isEmpty else { return }
        let pageText = page.string ?? quote
        let range = pageText.range(of: quote)
        let anchor = range.map { ReaderTextAnchor(text: pageText, range: $0) }
            ?? ReaderTextAnchor(exact: quote)
        onCreateHighlight?(MobileReaderHighlightSelection(
            quote: quote,
            anchor: anchor,
            pdfAnchor: ReaderPDFAnchor(pageIndex: pageIndex, rects: rects)
        ))
    }

    /// The link inside the document under a finger. A superscript is a few
    /// points wide at the phone's scale, so a tap close by counts, the
    /// nearest link winning.
    fileprivate func internalLink(at point: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        let slop = 10 / max(scaleFactor, 0.1)
        return page.annotations
            .filter { annotation in
                annotation.type == "Link" && annotation.url == nil && !(annotation.action is PDFActionURL)
                    && (annotation.destination != nil || annotation.action is PDFActionGoTo)
                    && annotation.bounds.insetBy(dx: -slop, dy: -slop).contains(pagePoint)
            }
            .min { hypot($0.bounds.midX - pagePoint.x, $0.bounds.midY - pagePoint.y)
                < hypot($1.bounds.midX - pagePoint.x, $1.bounds.midY - pagePoint.y) }
    }

    @objc private func openLinkAtTap(_ gesture: UITapGestureRecognizer) {
        guard let link = internalLink(at: gesture.location(in: self)) else { return }
        // Held first: PDFKit may jump while the handler is still deciding.
        linkTapTakenAt = Date()
        if onTapInternalLink?(link) != true { linkTapTakenAt = nil }
    }

    /// Goes where a link lands on the card's behalf, past the hold on
    /// PDFKit's own jumps.
    func followLink(to destination: PDFDestination) {
        followingLink = true
        defer { followingLink = false }
        go(to: destination)
    }

    private var holdsLinkJump: Bool {
        guard !followingLink, let linkTapTakenAt else { return false }
        return Date().timeIntervalSince(linkTapTakenAt) < 0.6
    }

    override func go(to destination: PDFDestination) {
        guard !holdsLinkJump else { return }
        super.go(to: destination)
    }

    override func perform(_ action: PDFAction) {
        guard !holdsLinkJump || !(action is PDFActionGoTo) else { return }
        super.perform(action)
    }

    @objc private func openAnnotationAtTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let page = page(for: point, nearest: false) else { return }
        let pagePoint = convert(point, to: page)
        guard let annotation = page.annotations.last(where: {
            $0.bounds.contains(pagePoint) && ($0.userName ?? "").hasPrefix("foreverlm:")
        }), let name = annotation.userName else { return }
        onOpenHighlight?(String(name.dropFirst("foreverlm:".count)))
    }
}

/// Begins the link tap only over a link, and makes the other taps on the PDF
/// view — PDFKit's link following among them — wait for it to fail.
private final class LinkTapDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var view: MobileHighlightPDFView?

    init(view: MobileHighlightPDFView) {
        self.view = view
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, view.onTapInternalLink != nil else { return false }
        return view.internalLink(at: gestureRecognizer.location(in: view)) != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let view, let other = otherGestureRecognizer.view else { return false }
        return otherGestureRecognizer is UITapGestureRecognizer && other.isDescendant(of: view)
    }
}

private struct MobilePDFKitView: UIViewRepresentable {
    let file: MobileSourcePDF
    /// Opened from `file`: for a chapter kept as a run of its book's pages,
    /// only those pages, so every page index here is the chapter's.
    let document: PDFDocument
    let highlights: [SourceHighlight]
    let find: MobileReaderFindState?
    let referenceCards: MobileReaderReferenceCards
    let onCreateHighlight: ((MobileReaderHighlightSelection) -> Void)?
    let onOpenHighlight: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MobileHighlightPDFView {
        let view = MobileHighlightPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        context.coordinator.findPerformer = MobilePDFFindPerformer(pdfView: view)
        referenceCards.attach(to: view)
        return view
    }

    func updateUIView(_ view: MobileHighlightPDFView, context: Context) {
        view.onCreateHighlight = onCreateHighlight
        view.onOpenHighlight = onOpenHighlight
        // Not a published property, so installing it here invalidates nothing.
        if let find, let performer = context.coordinator.findPerformer, find.performer !== performer {
            find.performer = performer
        }
        // The citation cards read the file the document came from.
        referenceCards.file = file
        if view.document !== document {
            view.document = document
        }
        context.coordinator.apply(highlights, to: document)
    }

    final class Coordinator {
        var findPerformer: MobilePDFFindPerformer?
        private var signature = ""
        private weak var paintedDocument: PDFDocument?

        func apply(_ highlights: [SourceHighlight], to document: PDFDocument?) {
            guard let document else { return }
            if paintedDocument !== document {
                paintedDocument = document
                signature = ""
            }
            let next = highlights.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            guard next != signature else { return }
            signature = next
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                for annotation in page.annotations where (annotation.userName ?? "").hasPrefix("foreverlm:") {
                    page.removeAnnotation(annotation)
                }
            }
            for highlight in highlights {
                guard let anchor = highlight.pdfAnchor,
                      let page = document.page(at: anchor.pageIndex) else { continue }
                let rgb = highlight.color.components
                for rect in anchor.rects {
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = UIColor(
                        red: CGFloat(rgb.red),
                        green: CGFloat(rgb.green),
                        blue: CGFloat(rgb.blue),
                        alpha: 0.48
                    )
                    annotation.userName = "foreverlm:\(highlight.id)"
                    page.addAnnotation(annotation)
                }
            }
        }
    }
}
