#if os(macOS)
import AppKit
import Foundation
import PDFKit

/// What one step's anchor resolves to: where the PDF points, which panels the
/// figure offers, and the panel the step is about rendered on its own.
struct WalkthroughResolvedAnchor: Equatable, Sendable {
    var target: ReaderWalkthroughFocus.Target
    /// The figure's panels as the learner reads them
    /// (`PaperWalkthroughValidation.panelDisplayName`) — from its vision
    /// analysis or its text layer: letters upper case in alphabetical order,
    /// or, for a figure with named panels ("ALL OF BIOLOGY", "DESIGN"), the
    /// names in the order the analysis lists them. Empty for a figure whose
    /// panels cannot be placed, and for a passage or page.
    var panelLabels: [String] = []
    /// The panel the target is cropped to, one of `panelLabels`, when one
    /// was placed.
    var panel: String?
    /// The panel drawn alone at readable size (JPEG), when `panel` is set:
    /// what the panel shows enlarged beside the paper.
    var lensImage: Data?
}

/// Turns a step's anchor into what the PDF view paints, using the paper's
/// figure index where it can and the page's own ink and text where it has to
/// — and remembers every answer.
///
/// Before this, every Back and Next reopened the PDF, rasterised the page and
/// searched the whole document's text for the caption: 1.3 s a step on a
/// 60-page preprint (2026-09-19, "clicking back and next here is too slow").
/// One resolver lives as long as the panel does, keeps the document open,
/// caches the ink mask a page, the crop and the panel rectangles a figure, the
/// rendered panel a lens, and the resolved answer an anchor, and the panel
/// asks it for the neighbouring steps ahead of time. A step visited once
/// costs nothing the second time; a step visited first costs the page's mask
/// and text, tens of milliseconds.
///
/// An actor so nothing here runs on the main actor: opening the document and
/// reading a page's ink are both file-backed.
actor WalkthroughAnchorResolver {
    private let figures: [PaperFigureRecord]
    private let pdfPath: String?
    private var document: PDFDocument?
    private var openedDocument = false
    private var masks: [Int: PaperFigureRectRefiner.PageInkMask] = [:]
    /// By figure id; a figure whose crop the page will not yield is cached as nil.
    private var figureCrops: [String: PaperFigureRect?] = [:]
    /// By figure id: the figure's placed panels.
    private var panelRects: [String: FigurePanels] = [:]
    private var lenses: [String: Data] = [:]
    private var resolved: [Key: WalkthroughResolvedAnchor?] = [:]
    /// How many times the document was opened and a page's ink read; what
    /// the caching claims, in numbers a test can hold it to.
    private(set) var documentOpens = 0
    private(set) var maskRenders = 0

    private struct Key: Hashable {
        let anchor: PaperWalkthroughAnchor
        let panel: String?
    }

    /// One figure's panels: each rectangle by the panel's identity
    /// (`PaperWalkthroughValidation.panelKey` — "B" for a lettered panel,
    /// "design" for a named one), and the panels as shown, in order.
    struct FigurePanels: Equatable, Sendable {
        var rects: [String: PaperFigureRect] = [:]
        /// Key → the label as the learner reads it ("B", "DESIGN").
        var shown: [String: String] = [:]
        /// Keys: alphabetical when every panel is a letter, as they always
        /// were; otherwise the analysis's own order, left to right.
        var order: [String] = []

        var labels: [String] { order.compactMap { rects[$0] == nil ? nil : shown[$0] } }
    }

    /// The longer side of a rendered lens, in pixels: crisp at the panel's
    /// width on a Retina display and with room to enlarge.
    static let lensPixelSize: CGFloat = 1_400
    /// A tiny panel is not blown up past this many times its printed size.
    static let lensMaximumScale: CGFloat = 8

    /// Whether the Reader shows the source as pages a step can be outlined on:
    /// a local PDF (a paper, a chapter split from a PDF book) or a paper's
    /// remote PDF. Anything else — an article's page or archive, an EPUB
    /// chapter's text, a paper read from its extracted text — is text, and the
    /// panel sends a passage step down the citation flash route instead of
    /// asking this resolver for geometry.
    nonisolated static func readerShowsPDF(_ article: StudioArticle) -> Bool {
        if article.isPDF { return true }
        return article.sourceType == .paper && article.cachedHasRemotePDFURL
    }

    init(figures: [PaperFigureRecord], pdfPath: String?) {
        self.figures = figures
        self.pdfPath = pdfPath
    }

    /// Whether this resolver was built for the same index and file.
    nonisolated func matches(figures: [PaperFigureRecord], pdfPath: String?) -> Bool {
        self.figures == figures && self.pdfPath == pdfPath
    }

    // MARK: Resolving

    /// The step's anchor resolved, with `panel` (a letter in any case, or a
    /// panel's name) standing in for the anchor's own panel when the learner
    /// picked one.
    func resolve(_ anchor: PaperWalkthroughAnchor?, panel override: String? = nil) -> WalkthroughResolvedAnchor? {
        guard let anchor else { return nil }
        let panelKey = (override ?? anchor.panelLabel).flatMap(PaperWalkthroughValidation.panelKey)
        let key = Key(anchor: anchor, panel: panelKey)
        if let cached = resolved[key] { return cached }
        let answer = resolveUncached(anchor, panelKey: panelKey)
        resolved[key] = answer
        return answer
    }

    /// Resolves ahead of need; the answers wait in the cache.
    func prefetch(_ anchors: [PaperWalkthroughAnchor?]) {
        for anchor in anchors {
            _ = resolve(anchor)
        }
    }

    private func resolveUncached(_ anchor: PaperWalkthroughAnchor, panelKey: String?) -> WalkthroughResolvedAnchor? {
        if let label = anchor.figureLabel, !label.isEmpty,
           let record = Self.figureRecord(labelled: label, in: figures) {
            return resolveFigure(record, panelKey: panelKey)
        }
        if let passage = anchor.passage?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty {
            return WalkthroughResolvedAnchor(target: .passage(passage, pageHint: anchor.pageNumber.map { $0 - 1 }))
        }
        if let page = anchor.pageNumber, page > 0 {
            return WalkthroughResolvedAnchor(target: .page(pageIndex: page - 1))
        }
        return nil
    }

    private func resolveFigure(_ record: PaperFigureRecord, panelKey: String?) -> WalkthroughResolvedAnchor {
        let labelsOnPage = Set(figures.filter { $0.pageIndex == record.pageIndex }.map { $0.figureLabel.lowercased() })
        let shares = labelsOnPage.count > 1
        let crop = figureCrop(for: record, sharesPage: shares)
        let panels = panelRects(for: record, crop: crop)

        var rect = crop
        var panel: String?
        var lens: Data?
        if let panelKey, let panelRect = panels.rects[panelKey] {
            rect = panelRect
            panel = panels.shown[panelKey] ?? panelKey
            lens = lensImage(for: record, panel: panelKey, rect: panelRect)
        }
        return WalkthroughResolvedAnchor(
            target: .figure(
                pageIndex: record.pageIndex,
                rect: rect,
                caption: record.caption,
                sharesPageWithOtherFigures: shares
            ),
            panelLabels: panels.labels,
            panel: panel,
            lensImage: lens
        )
    }

    /// The figures on one page as the Reader's Clip tool matches and snaps a
    /// box to them: each figure's crop and its panels', from the same cached
    /// reads a walkthrough step makes. Empty for a page with no indexed figure,
    /// or a figure the page yields no crop for.
    func clipRegions(onPage pageIndex: Int) -> [ReaderClipFigureRegion] {
        let onPage = figures.filter { $0.pageIndex == pageIndex }
        let shares = Set(onPage.map { $0.figureLabel.lowercased() }).count > 1
        return onPage.compactMap { record in
            guard let crop = figureCrop(for: record, sharesPage: shares) else { return nil }
            let panels = panelRects(for: record, crop: crop)
            return ReaderClipFigureRegion(
                figureLabel: record.figureLabel,
                caption: record.caption,
                rect: crop,
                panels: panels.order.compactMap { key in
                    panels.rects[key].map { ReaderClipFigureRegion.Panel(name: panels.shown[key] ?? key, rect: $0) }
                }
            )
        }
    }

    // MARK: Geometry, cached

    private func page(at index: Int) -> PDFPage? {
        if !openedDocument {
            openedDocument = true
            // A book chapter's path names its pages of the book's file (`SourcePDFPages`).
            if let pdfPath, let location = SourcePDFPages(stored: pdfPath).resolved() {
                document = location.document()
                documentOpens += 1
            }
        }
        return document?.page(at: index)
    }

    private func mask(for pageIndex: Int) -> PaperFigureRectRefiner.PageInkMask? {
        if let cached = masks[pageIndex] { return cached }
        guard let page = page(at: pageIndex), let mask = PaperFigureRectRefiner.mask(for: page) else { return nil }
        maskRenders += 1
        masks[pageIndex] = mask
        return mask
    }

    /// The crop the page yields around the caption; the analysed rectangle
    /// only when the page will not give one, and nil when neither exists. The
    /// vision pass's rectangle is read by eye and was often wrong for the whole
    /// figure (`PaperFigureRectRefiner.displayedFigureCrop`).
    private func figureCrop(for record: PaperFigureRecord, sharesPage: Bool) -> PaperFigureRect? {
        if let cached = figureCrops[record.id] { return cached }
        var crop: PaperFigureRect?
        if let page = page(at: record.pageIndex) {
            crop = PaperFigureRectRefiner.displayedFigureCrop(
                forCaption: record.caption,
                measured: record.analysis?.figureRect,
                on: page,
                mask: mask(for: record.pageIndex),
                sharesPageWithOtherFigures: sharesPage
            )
        } else if let stored = record.analysis?.figureRect, stored.isValid {
            crop = stored
        }
        figureCrops[record.id] = .some(crop)
        return crop
    }

    /// The figure's panels: the vision analysis's rectangles where it
    /// measured them, else the text layer's letters.
    private func panelRects(for record: PaperFigureRecord, crop: PaperFigureRect?) -> FigurePanels {
        if let cached = panelRects[record.id] { return cached }
        var panels = FigurePanels()
        if let analysis = record.analysis {
            panels = Self.analysedPanels(analysis.panels)
            // Read by eye, a panel's edge can stop inside its own plot
            // (Figure 2h of the cardiac-sodium paper lost its last group of
            // bars); each edge on ink grows onto it, never into a neighbour.
            if !panels.rects.isEmpty, let crop, let mask = mask(for: record.pageIndex) {
                panels.rects = PaperFigureRectRefiner.extendedPanelRects(panels.rects, within: crop, with: mask).panels
            }
        }
        if panels.rects.isEmpty, let crop, let page = page(at: record.pageIndex) {
            // The text layer finds printed letters only, already upper case,
            // which is what a letter's key is.
            let rects = PaperFigurePanelLocator.panelRects(in: crop, on: page, mask: mask(for: record.pageIndex))
            panels = FigurePanels(
                rects: rects,
                shown: Dictionary(uniqueKeysWithValues: rects.keys.map { ($0, $0) }),
                order: rects.keys.sorted()
            )
        }
        panelRects[record.id] = panels
        return panels
    }

    /// The analysis's panels that carry a rectangle, keyed by identity. Two
    /// panels are one only when their labels are: "DESIGN" and "VALIDATION"
    /// are two panels, where a key of their last letter made both "N" and
    /// kept one rectangle. A label listed twice keeps its first place and
    /// its last rectangle, as a letter listed twice always did.
    nonisolated static func analysedPanels(_ analysed: [PaperFigurePanel]) -> FigurePanels {
        var panels = FigurePanels()
        for panel in analysed {
            guard let rect = panel.rect, rect.isValid,
                  let key = PaperWalkthroughValidation.panelKey(panel.label) else { continue }
            if panels.rects[key] == nil { panels.order.append(key) }
            panels.rects[key] = rect
            panels.shown[key] = PaperWalkthroughValidation.panelDisplayName(panel.label)
        }
        if panels.order.allSatisfy({ PaperWalkthroughValidation.panelLetter($0) != nil }) {
            panels.order.sort()
        }
        return panels
    }

    private func lensImage(for record: PaperFigureRecord, panel: String, rect: PaperFigureRect) -> Data? {
        let key = "\(record.id)/\(panel)"
        if let cached = lenses[key] { return cached }
        guard let page = page(at: record.pageIndex), let data = Self.renderLens(rect, on: page) else { return nil }
        lenses[key] = data
        return data
    }

    /// The rectangle drawn alone on white, at `pixelSize` on its longer side
    /// (`lensPixelSize` for the chat row's lens; the screen's size for the
    /// lightbox, `ReaderWalkthroughSpotlight.lightboxLensPixelSize`), blown up
    /// at most `maximumScale` times its printed size. JPEG by default; PNG
    /// when `lossless`, for a picture the learner will look at closely.
    /// Normalized top-left in, PDF's bottom-left out: flipped once here.
    static func renderLens(
        _ rect: PaperFigureRect,
        on page: PDFPage,
        pixelSize: CGFloat = lensPixelSize,
        maximumScale: CGFloat = lensMaximumScale,
        lossless: Bool = false
    ) -> Data? {
        guard rect.isValid, page.rotation % 360 == 0 else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let region = CGRect(
            x: box.minX + rect.x * box.width,
            y: box.minY + (1 - rect.y - rect.height) * box.height,
            width: rect.width * box.width,
            height: rect.height * box.height
        )
        guard region.width > 1, region.height > 1 else { return nil }
        let scale = min(pixelSize / max(region.width, region.height), maximumScale)
        let width = Int((region.width * scale).rounded())
        let height = Int((region.height * scale).rounded())
        guard width > 1, height > 1,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.drawMediaBox(region, to: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return lossless
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    // MARK: Index lookup

    /// The figure a label names, by the tools' match first and the validator's
    /// looser one ("Figure 2a" → Figure 2) second.
    nonisolated static func figureRecord(labelled label: String, in figures: [PaperFigureRecord]) -> PaperFigureRecord? {
        PaperWalkthroughGeneratorService.figureRecord(labelled: label, in: figures)
    }
}
#endif
