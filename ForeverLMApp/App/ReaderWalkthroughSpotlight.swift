#if os(macOS)
import AppKit
import PDFKit

/// Paints what a walkthrough step points at onto the PDF and scrolls to it.
///
/// A figure gets a square annotation in the accent colour around its
/// rectangle; a passage gets a standing highlighted selection, the citation
/// flash's colour without the fade. Both are PDFKit's own marks, so they ride
/// the page through scrolling, zooming and Dark Mode's inversion the way saved
/// highlights do, and neither is ever written to the document on disk. One
/// spotlight per PDF view; a new focus replaces the last, and nil clears it.
@MainActor
final class ReaderWalkthroughSpotlight {
    static let annotationUserName = "foreverlm-walkthrough"
    /// The shade and veil (a Predict card's): marks of the spotlight's own, but not the
    /// outline, so the pointer over them is not the outline's zoom cursor.
    static let shadeUserName = "foreverlm-walkthrough-shade"
    static let outlineWidth: CGFloat = 2.5
    /// Points of page around the figure the outline stands off it.
    static let outlineInset: CGFloat = 6

    /// What the outline is drawn around: the page in the document, the
    /// rectangle as measured on the upright page, and the caption a title is
    /// read from.
    struct PaintedFigure: Equatable, Sendable {
        let pageIndex: Int
        let rect: PaperFigureRect
        let caption: String
    }

    private weak var pdfView: PDFView?
    private var annotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var selection: PDFSelection?
    private var appliedRevision: UInt?
    /// The figure the outline stands around and the annotation that is the
    /// outline, so a click on it can show the figure enlarged.
    private(set) var paintedFigure: PaintedFigure?
    private var outlineAnnotation: PDFAnnotation?
    private var lensCache: (figure: PaintedFigure, pixelSize: CGFloat, data: Data)?
    private var lensRenderInFlight = false

    /// Created in the PDF coordinator's stored-property initialiser, which is
    /// not on any actor; everything it does afterwards is.
    nonisolated init() {}

    /// Applies `focus` when it is new; `pageRange` is the source's pages within
    /// the document (the whole document for a paper on its own, a chapter's
    /// span in a book read as one document). A passage is searched within it,
    /// so a sentence a chapter shares with another chapter is found in the
    /// chapter the step belongs to.
    func apply(_ focus: ReaderWalkthroughFocus, in pdfView: PDFView, pageRange: Range<Int>) {
        guard focus.revision != appliedRevision else { return }
        appliedRevision = focus.revision
        clearMarks()
        self.pdfView = pdfView
        guard let document = pdfView.document else { return }
        let pageBase = pageRange.lowerBound

        switch focus.target {
        case .figure(let pageIndex, let rect, let caption, _):
            let index = pageBase + pageIndex
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
            if let rect, let pageRect = Self.pageRect(for: rect, on: page), !focus.pickablePanels.isEmpty {
                // A Find it card: no outline to click (it would open the
                // lightbox), but each panel a click target of its own.
                let outline = pageRect.insetBy(dx: -Self.outlineInset, dy: -Self.outlineInset)
                dim(page, around: outline)
                for panel in focus.pickablePanels {
                    guard let panelRect = Self.pageRect(for: panel.rect, on: page) else { continue }
                    addPanelZone(panelRect, label: panel.label, sourceID: focus.sourceID, on: page)
                }
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in
                    Self.scroll(pdfView, to: outline, on: page)
                }
            } else if let rect, let pageRect = Self.pageRect(for: rect, on: page) {
                let outline = pageRect.insetBy(dx: -Self.outlineInset, dy: -Self.outlineInset)
                let annotation = PDFAnnotation(bounds: outline, forType: .square, withProperties: nil)
                annotation.userName = Self.annotationUserName
                annotation.color = Self.outlineColor
                annotation.interiorColor = nil
                let border = PDFBorder()
                border.lineWidth = Self.outlineWidth
                border.style = .solid
                annotation.border = border
                annotation.shouldPrint = false
                page.addAnnotation(annotation)
                annotations.append((page, annotation))
                outlineAnnotation = annotation
                paintedFigure = PaintedFigure(pageIndex: index, rect: rect, caption: caption)
                if focus.emphasis != .outline {
                    dim(page, around: outline)
                }
                if focus.emphasis == .veiled {
                    veil(pageRect, on: page)
                }
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in
                    Self.scroll(pdfView, to: outline, on: page)
                }
            } else {
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in
                    pdfView.go(to: page)
                }
            }

        case .passage(let passage, let pageHint):
            let range = pageRange.clamped(to: 0..<document.pageCount)
            if let (page, found) = ReaderPassageFlash.selection(for: passage, in: document, pageRange: range) {
                found.color = ReaderPassageFlash.color()
                pdfView.highlightedSelections = (pdfView.highlightedSelections ?? []) + [found]
                selection = found
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in
                    let bounds = found.bounds(for: page)
                    if bounds.isNull || bounds.isEmpty {
                        pdfView.go(to: found)
                    } else {
                        Self.scroll(pdfView, to: bounds, on: page)
                    }
                }
            } else if let pageHint {
                let index = pageBase + pageHint
                guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
                ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in pdfView.go(to: page) }
            }

        case .page(let pageIndex):
            let index = pageBase + pageIndex
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { return }
            ReaderPassageFlash.whenLaidOut(pdfView) { pdfView in pdfView.go(to: page) }
        }
    }

    /// Takes every mark down. Safe to call when nothing is painted.
    func clear() {
        guard appliedRevision != nil || !annotations.isEmpty || selection != nil else { return }
        appliedRevision = nil
        clearMarks()
    }

    /// The document changed under the view: the marks belonged to the old one.
    func reset() {
        annotations = []
        selection = nil
        appliedRevision = nil
        outlineAnnotation = nil
        paintedFigure = nil
        lensCache = nil
    }

    // MARK: The outline as a control

    /// The figure behind `annotation` when it is this spotlight's outline;
    /// nil for any other mark on the page.
    func figure(outlinedBy annotation: PDFAnnotation) -> PaintedFigure? {
        guard let outlineAnnotation, annotation === outlineAnnotation else { return nil }
        return paintedFigure
    }

    /// Whether `annotation` is a walkthrough outline: what the pointer asks
    /// on hover, before any click.
    nonisolated static func isOutline(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName == annotationUserName
    }

    /// The pointer over the outline: a click enlarges what it stands around.
    static var outlineCursor: NSCursor {
        if #available(macOS 15, *) {
            return .zoomIn
        }
        return .pointingHand
    }

    /// Pixels on the longer side of the lens the lightbox shows: the screen's
    /// longer side in device pixels, doubled so a click to zoom stays sharp,
    /// never below the chat row's lens size and never past six thousand. The
    /// lightbox draws one pixel a point and fits the picture to the window, so
    /// a lens at the row's 1,400 px was upscaled on a Retina screen and read
    /// blurry beside the sharp page (product owner, 2026-09-20).
    static func lightboxLensPixelSize(for screen: NSScreen?) -> CGFloat {
        guard let screen = screen ?? NSScreen.main else { return WalkthroughAnchorResolver.lensPixelSize * 2 }
        let longer = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        return min(max(longer * 2, WalkthroughAnchorResolver.lensPixelSize), 6_000)
    }

    /// A small panel may be blown up further for the lightbox than for the
    /// row, since the learner asked to look at it closely.
    static let lightboxLensMaximumScale: CGFloat = 16

    /// The outlined figure drawn alone at `pixelSize` on its longer side
    /// (PNG, so nothing softens it), rendered from the document's file off the
    /// main actor the way the resolver renders a step's panel, and kept for
    /// the next click at that size. A document with no file behind it is
    /// drawn from its live page. Nil while a render is already under way, so a
    /// double-click opens one lightbox, not two.
    func lens(
        for figure: PaintedFigure,
        in document: PDFDocument,
        pixelSize: CGFloat = WalkthroughAnchorResolver.lensPixelSize
    ) async -> Data? {
        if let lensCache, lensCache.figure == figure, lensCache.pixelSize == pixelSize { return lensCache.data }
        guard !lensRenderInFlight else { return nil }
        lensRenderInFlight = true
        defer { lensRenderInFlight = false }
        let maximumScale = Self.lightboxLensMaximumScale
        let data: Data?
        if let url = document.documentURL {
            let rect = figure.rect
            let pageIndex = figure.pageIndex
            data = await Task.detached(priority: .userInitiated) {
                guard let copy = PDFDocument(url: url), let page = copy.page(at: pageIndex) else { return nil }
                return WalkthroughAnchorResolver.renderLens(rect, on: page, pixelSize: pixelSize, maximumScale: maximumScale, lossless: true)
            }.value
        } else if let page = document.page(at: figure.pageIndex) {
            data = WalkthroughAnchorResolver.renderLens(figure.rect, on: page, pixelSize: pixelSize, maximumScale: maximumScale, lossless: true)
        } else {
            data = nil
        }
        if let data { lensCache = (figure, pixelSize, data) }
        return data
    }

    // MARK: Emphasis: the shade and the veil

    /// Shade over the page outside `kept`, so the figure the turn is about is
    /// the one lit thing on it (walkthrough-design.md: "the page dims around
    /// what the turn is about").
    private func dim(_ page: PDFPage, around kept: CGRect) {
        let box = page.bounds(for: .mediaBox)
        let kept = kept.intersection(box)
        guard !kept.isNull else { return }
        let bands = [
            CGRect(x: box.minX, y: kept.maxY, width: box.width, height: box.maxY - kept.maxY),
            CGRect(x: box.minX, y: box.minY, width: box.width, height: kept.minY - box.minY),
            CGRect(x: box.minX, y: kept.minY, width: kept.minX - box.minX, height: kept.height),
            CGRect(x: kept.maxX, y: kept.minY, width: box.maxX - kept.maxX, height: kept.height),
        ]
        for band in bands where band.width > 0.5 && band.height > 0.5 {
            addShade(band, color: Self.dimColor, on: page)
        }
    }

    /// Covers the figure's data until the learner has made their guess, with
    /// a line that says why.
    private func veil(_ rect: CGRect, on page: PDFPage) {
        addShade(rect, color: Self.veilColor, on: page)
        let labelHeight: CGFloat = 22
        let label = PDFAnnotation(
            bounds: CGRect(x: rect.minX, y: rect.midY - labelHeight / 2, width: rect.width, height: labelHeight),
            forType: .freeText,
            withProperties: nil
        )
        label.userName = Self.shadeUserName
        label.contents = "Hidden until you answer"
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontColor = NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.29, alpha: 1)
        label.alignment = .center
        label.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        label.border = border
        label.shouldPrint = false
        page.addAnnotation(label)
        annotations.append((page, label))
    }

    private func addShade(_ rect: CGRect, color: NSColor, on page: PDFPage) {
        let shade = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        shade.userName = Self.shadeUserName
        shade.color = .clear
        shade.interiorColor = color
        let border = PDFBorder()
        border.lineWidth = 0
        shade.border = border
        shade.shouldPrint = false
        page.addAnnotation(shade)
        annotations.append((page, shade))
    }

    /// A Find it panel as a click target: a faint dashed box the pointer
    /// turns into a hand over, named for its source and letter so a click
    /// can say which was picked.
    private func addPanelZone(_ rect: CGRect, label: String, sourceID: String, on page: PDFPage) {
        let zone = PDFAnnotation(bounds: rect.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
        zone.userName = Self.panelZonePrefix + sourceID + "|" + label
        zone.color = Self.outlineColor.withAlphaComponent(0.55)
        zone.interiorColor = Self.outlineColor.withAlphaComponent(0.05)
        let border = PDFBorder()
        border.lineWidth = 1.2
        border.style = .dashed
        border.dashPattern = [4, 3]
        zone.border = border
        zone.shouldPrint = false
        page.addAnnotation(zone)
        annotations.append((page, zone))
    }

    static let panelZonePrefix = "foreverlm-walkthrough-panel|"

    /// The source and panel letter a Find it zone stands for; nil for any
    /// other annotation.
    nonisolated static func pickedPanel(_ annotation: PDFAnnotation) -> (sourceID: String, panel: String)? {
        guard let name = annotation.userName, name.hasPrefix(panelZonePrefix) else { return nil }
        let rest = name.dropFirst(panelZonePrefix.count)
        guard let bar = rest.lastIndex(of: "|") else { return nil }
        let sourceID = String(rest[..<bar])
        let panel = String(rest[rest.index(after: bar)...])
        guard !sourceID.isEmpty, !panel.isEmpty else { return nil }
        return (sourceID, panel)
    }

    private static let dimColor = NSColor(calibratedWhite: 0.05, alpha: 0.30)
    private static let veilColor = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 0.97)

    private func clearMarks() {
        for (page, annotation) in annotations {
            page.removeAnnotation(annotation)
        }
        annotations = []
        outlineAnnotation = nil
        paintedFigure = nil
        if let selection, let pdfView {
            let remaining = (pdfView.highlightedSelections ?? []).filter { $0 !== selection }
            pdfView.highlightedSelections = remaining.isEmpty ? nil : remaining
        }
        selection = nil
    }

    private static var outlineColor: NSColor {
        (NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue).withAlphaComponent(0.95)
    }

    /// A figure rectangle — normalized, top-left origin, as measured on the
    /// page rendered upright — in the page's own coordinates. Nil for a page
    /// displayed rotated, whose rendered axes are not the page's; such a step
    /// still scrolls to its page.
    static func pageRect(for rect: PaperFigureRect, on page: PDFPage) -> CGRect? {
        guard rect.isValid, page.rotation % 360 == 0 else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        return CGRect(
            x: box.minX + rect.x * box.width,
            y: box.minY + (1 - rect.y - rect.height) * box.height,
            width: rect.width * box.width,
            height: rect.height * box.height
        )
    }

    /// Brings the rectangle to the middle of the view rather than its edge,
    /// the way a cited passage is shown.
    private static func scroll(_ pdfView: PDFView, to bounds: CGRect, on page: PDFPage) {
        let scale = max(pdfView.scaleFactor, 0.01)
        let visibleHeight = pdfView.bounds.height / scale
        let margin = max(0, (visibleHeight - bounds.height) / 2)
        pdfView.go(to: bounds.insetBy(dx: 0, dy: -margin), on: page)
    }
}
#endif
