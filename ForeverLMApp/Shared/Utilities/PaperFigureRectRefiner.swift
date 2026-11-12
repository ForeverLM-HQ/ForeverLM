#if canImport(PDFKit)
#if os(macOS)
import AppKit
/// The font a PDF selection's attributed string carries on this platform.
typealias PaperFigurePlatformFont = NSFont
#else
import UIKit
typealias PaperFigurePlatformFont = UIFont
#endif
import CoreGraphics
import Foundation
import PDFKit

/// Snaps a figure rectangle onto the ink that is actually on the page.
///
/// A vision model asked for `{x,y,width,height}` is estimating, and it shows:
/// the rectangles it returns cluster on round numbers and repeat across
/// unrelated figures, because a generic "content block" is the best guess
/// available when there is nothing to measure. Two failure shapes follow — a
/// box with whitespace slack around the figure, and a box that slices the
/// figure off at an edge — and the page itself can settle both, because it says
/// where the marks are.
///
/// Two things are read off the page, in order of how much they are trusted.
///
/// **The caption.** It is the one landmark that certainly belongs to this
/// figure, and a figure is the block of ink on one side of its caption — above
/// it almost always, below it for the occasional table. Whichever side holds
/// more ink is the band the figure lives in, and nothing outside that band can
/// reach the crop. That alone excludes the body text, the running head and the
/// folio, none of which a rectangle-guessing model reliably excludes.
///
/// **The ink.** Inside the band an edge grows outward only while that edge line
/// *itself* still lands on ink — ink crossing the boundary is the signature of a
/// figure cut in half, and the moment the boundary is clean the growth stops. It
/// never crosses a gap, so it cannot wander into a neighbour. Afterwards the box
/// is trimmed back to the ink bounding box inside it, which removes the slack.
///
/// Growth stopping at the first clean edge is right for a figure with
/// neighbours and wrong for a full-page figure whose panel rows are separated by
/// real gutters — there it halts inside the figure. So when the page holds only
/// one figure and the result has left most of the band's ink outside itself, the
/// band's own ink bounds are used instead: with one figure in the band, that is
/// the figure. When the page holds several, the model's rectangle is the only
/// thing saying which one is meant, and it is kept.
///
/// Everything is measured in the mask's pixels with a top-left origin, the same
/// frame `PaperFigureRect` uses, so no coordinate flip is needed on the way out.
enum PaperFigureRectRefiner {

    /// A rendered page reduced to "is there a mark here". Build it once per
    /// page: several figures routinely share one, and rasterizing is the
    /// expensive half.
    struct PageInkMask {
        let width: Int
        let height: Int
        fileprivate var dark: [Bool]
        /// Pixels darker than `strongInkThreshold`: a figure's lines, marks
        /// and text, where a watermark or a tint is only ever pale.
        fileprivate var strong: [Bool]
    }

    /// Rendering resolution. Enough to separate a figure from its caption and
    /// from a neighbouring column; far below what the crop is finally rendered
    /// at, because this only ever answers a yes/no question per pixel.
    private static let inkDPI: CGFloat = 110

    /// Below this the pixel is a mark rather than paper. Journal PDFs put light
    /// grey panel backgrounds behind plots, so the threshold has to sit high
    /// enough to treat those as ink and low enough to ignore JPEG mottling in a
    /// white margin.
    private static let inkThreshold: UInt8 = 235

    /// Below this the mark is a figure's own, not a watermark's. The
    /// "ARTICLE IN PRESS" set diagonally across every page of Nature's
    /// accepted manuscripts is drawn at 210 to 219; a figure draws its lines,
    /// markers and letters far darker.
    static let strongInkThreshold: UInt8 = 200

    /// A row or column counts as blank below this share of dark pixels. One
    /// stray speck — a scan artifact, an antialiased hairline — must not keep an
    /// edge growing across an empty margin.
    fileprivate static let blankFraction = 0.002

    /// Hard stop on how far one edge may travel, as a share of that page
    /// dimension. Reached only by a figure sitting on a full-bleed background,
    /// where growing is exactly wrong.
    private static let maximumGrowth = 0.18

    /// Breathing room left around the trimmed figure, as a share of the page's
    /// longer side.
    private static let padding = 0.006

    /// A crop of this much of the page is not a crop, so the caller may as well
    /// render the page.
    private static let maximumUsefulArea = 0.97

    /// A sole figure keeping less of its band's ink than this is not a crop of
    /// that figure — it is a slice through it.
    private static let minimumInkShareOfSoleFigure = 0.86

    // MARK: - Mask

    static func mask(for page: PDFPage) -> PageInkMask? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = inkDPI / 72
        let width = Int((box.width * scale).rounded())
        let height = Int((box.height * scale).rounded())
        guard width > 2, height > 2 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.drawMediaBox(to: context)
        context.restoreGState()
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var dark = [Bool](repeating: false, count: width * height)
        var strong = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            dark[index] = pixels[index] < inkThreshold
            strong[index] = pixels[index] < strongInkThreshold
        }
        return PageInkMask(width: width, height: height, dark: dark, strong: strong)
    }

    // MARK: - Caption anchor

    /// Where a printed caption line sits on the page, in PDF page coordinates.
    ///
    /// This goes through `PDFSelection` rather than `characterBounds(at:)`.
    /// The character API is indexed against something that is *not*
    /// `page.string` — on a two-column Nature page the two agree on length and
    /// still disagree on position, which put the anchor a line low and silently
    /// dragged the caption into the crop. A selection carries its own geometry
    /// and cannot drift that way.
    ///
    /// Only the caption's first line is measured: the anchor wanted is the edge
    /// the figure stops at, and the rest of a caption paragraph only pushes that
    /// edge further from the figure. The needle shortens on a miss because a
    /// caption line recovered from extracted text does not always survive a
    /// literal search at full length.
    static func captionBounds(of caption: String, on page: PDFPage) -> CGRect? {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        // The page's own text first. `findString` on the document extracts
        // the text of every page before it answers — 1.3 s on a 60-page
        // preprint, paid again each time the document is reopened — while
        // the page's string is one page and a selection over a range of it
        // carries the same geometry (0.3 ms on the same page).
        if let text = page.string {
            for length in [60, 30, 14] {
                let needle = String(trimmed.prefix(length))
                guard needle.count >= 8, let range = text.range(of: needle),
                      let bounds = firstLineBounds(of: range, in: text, on: page) else { continue }
                return bounds
            }
        }
        guard let document = page.document else { return nil }
        for length in [60, 30, 14] {
            let needle = String(trimmed.prefix(length))
            guard needle.count >= 8 else { continue }
            for selection in document.findString(needle, withOptions: [.literal]) {
                guard selection.pages.contains(page),
                      let line = selection.selectionsByLine().first else { continue }
                let bounds = line.bounds(for: page)
                if bounds.width > 0, bounds.height > 0 { return bounds }
            }
        }
        return nil
    }

    /// Where the figure's caption stands on the figure's page, in PDF page
    /// coordinates: the caption's own first line, or — when the index took
    /// the caption's words from another page — the line of this page that
    /// prints the figure's label. EMBO sets a figure's legend on the page
    /// before or after the figure and prints only "Figure 1." under the
    /// figure itself; Nature prints "Fig. 3 | See next page for caption."
    /// Nil when the page prints neither.
    static func captionAnchor(of caption: String, on page: PDFPage) -> CGRect? {
        if let bounds = captionBounds(of: caption, on: page) { return bounds }
        let opening = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        guard let label = PaperFigureCaptionTitle.label(openingLine: opening)?.lowercased(),
              let text = page.string else { return nil }
        var anchor: CGRect?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, range, _, stop in
            guard let line,
                  let start = PaperFigureCaptionTitle.captionStart(in: line),
                  PaperFigureCaptionTitle.label(openingLine: String(line[start...]))?.lowercased() == label else { return }
            let offset = line.distance(from: line.startIndex, to: start)
            let lineRange = text.index(range.lowerBound, offsetBy: offset)..<range.upperBound
            anchor = firstLineBounds(of: lineRange, in: text, on: page)
            stop = anchor != nil
        }
        return anchor
    }

    /// The lines of text in `selection`, less the placeholder PDFKit reads
    /// for an embedded picture: in the Biophysical Journal's PDFs each
    /// figure is one "line" holding only U+FFFC, as large as the figure.
    /// Taken for text, it made the figure prose to
    /// `figureSide` and blank to `pageInk`.
    static func textLines(of selection: PDFSelection) -> [PDFSelection] {
        selection.selectionsByLine().filter { $0.string?.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    /// Whether a line's box, in page coordinates, is one line of text: not
    /// taller than a line (`writtenLineMaximumHeightShare`) and wide as well.
    /// PDFKit boxes text set on a slant upright — the "ARTICLE IN PRESS"
    /// across every page of a Nature accepted manuscript is a box 0.4 of
    /// the page wide and 0.3 tall — and can join a plot's labels into one
    /// box as tall as the plot. Either box holds a figure's ink, which is no
    /// text; a rotated axis title's box is narrow and holds only its words.
    static func isTextLineBox(_ bounds: CGRect, on pageBounds: CGRect) -> Bool {
        bounds.height <= pageBounds.height * writtenLineMaximumHeightShare || bounds.width <= pageBounds.width * 0.1
    }

    /// Whether a line's box, in page coordinates, printing `characters`
    /// that are not whitespace, is written text: one line across the page,
    /// not up it or down a plot, and dense enough
    /// (`proseLineMinimumDensity`). A rotated axis title's box is tall and
    /// narrow, and a plot's labels joined into one box are as tall as the
    /// plot; either reads as dense as any line.
    static func isWrittenLine(_ bounds: CGRect, characters: Int, on pageBounds: CGRect) -> Bool {
        bounds.width >= bounds.height * 2
            && bounds.height <= pageBounds.height * writtenLineMaximumHeightShare
            && CGFloat(characters) / (bounds.width / bounds.height) >= proseLineMinimumDensity
    }

    /// The box of the first printed line of `range` of the page's text.
    private static func firstLineBounds(of range: Range<String.Index>, in text: String, on page: PDFPage) -> CGRect? {
        guard let selection = page.selection(for: NSRange(range, in: text)),
              let line = selection.selectionsByLine().first else { return nil }
        let bounds = line.bounds(for: page)
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
    }

    /// The crop a figure is outlined, shown and read with, wherever that is:
    /// what the page itself yields around the caption, and the vision pass's
    /// rectangle only for a page that yields nothing.
    ///
    /// The vision model reads rectangles off the page by eye and gets whole
    /// figures wrong: a full-width box over a one-column figure (Nature,
    /// Fig. 1 of the mtDNA-in-blood paper), a strip over the
    /// running head, a box that takes in the paragraph above. Over the 79
    /// stored rectangles in the library, 29 overlapped the caption's crop by
    /// less than 0.7 (IoU), and in the sheet of the worst 16 it was the
    /// stored one that was wrong; over 333 caption crops, Docling's figure
    /// boxes agree with them at a median IoU of 0.92. Every place that picks
    /// a figure's crop calls this, so none of them can prefer the stored
    /// rectangle.
    static func displayedFigureCrop(
        forCaption caption: String,
        measured: PaperFigureRect?,
        on page: PDFPage,
        mask: PageInkMask? = nil,
        sharesPageWithOtherFigures: Bool = false
    ) -> PaperFigureRect? {
        if let crop = figureCrop(
            forCaption: caption,
            on: page,
            mask: mask,
            sharesPageWithOtherFigures: sharesPageWithOtherFigures
        ) {
            return crop
        }
        guard let measured, measured.isValid else { return nil }
        return measured
    }

    /// The crop for a figure nobody has paid to explain.
    ///
    /// Everything this needs is printed on the page — the caption says where the
    /// figure stops, the ink says how far it reaches — so a figure is croppable
    /// long before, and whether or not, a vision model ever looks at it. A
    /// learner signed out, out of credits, or simply not asking for an
    /// explanation still gets the figure rather than the page it sits on.
    /// The crop is the ink of the figure's region (`figureRegion`); a page
    /// whose text layer places no figure by its caption falls back to the
    /// band on the caption's side. `mask`, when the caller already has the
    /// page's, saves rendering it again.
    static func figureCrop(
        forCaption caption: String,
        on page: PDFPage,
        mask: PageInkMask? = nil,
        sharesPageWithOtherFigures: Bool = false
    ) -> PaperFigureRect? {
        guard let mask = mask ?? self.mask(for: page) else { return nil }
        let anchor = captionAnchor(of: caption, on: page)
        let fallbackBand = anchor == nil ? uncaptionedFigureBand(on: page, mask: mask) : nil
        if let region = figureRegion(captionAnchor: anchor, fallbackBand: fallbackBand, on: page, mask: mask) {
            return refined(nil, with: mask, region: region)
        }
        // The rules and bars beside the running head come off here too, as
        // `ErasedPage` takes them off a region: Nature Reviews' red bar at
        // the page's edge otherwise held the crop out to it.
        let box = page.bounds(for: .mediaBox)
        let head = runningHead(on: page, mask: mask)
        var ink = mask
        for band in head?.sideBands ?? [] {
            if let pixels = PixelBox(pdfRect: band, pageBounds: box, in: mask) { ink.erase(pixels) }
        }
        return refined(
            nil,
            captionBounds: anchor,
            pageBounds: box,
            with: ink,
            sharesPageWithOtherFigures: sharesPageWithOtherFigures,
            figureSide: anchor.flatMap { figureSide(captionBounds: $0, on: page) },
            runningHead: head?.bounds,
            fallbackBand: fallbackBand
        )
    }

    /// The region of the figure whose caption is anchored at `anchor`
    /// (`captionAnchor`), or, with no anchor, of the figure filling
    /// `fallbackBand` (`uncaptionedFigureBand`); nil when neither is given or
    /// the page shows no figure there.
    static func figureRegion(
        captionAnchor anchor: CGRect?,
        fallbackBand: CGRect?,
        on page: PDFPage,
        mask: PageInkMask
    ) -> FigureRegion? {
        if let anchor { return figureRegion(captionAnchor: anchor, on: page, mask: mask) }
        return fallbackBand.flatMap { figureRegion(band: $0, on: page, mask: mask) }
    }

    // MARK: - A caption printed on another page

    /// Nature sets a figure that fills its page with no caption under it: the
    /// caption opens the next page, under the running head, and the figure's
    /// own page has nothing printed to say where the figure stops except the
    /// body text that shares the page with it. Fig. 6 of the cardiac-sodium
    /// paper was indexed to its caption's page, whose only ink
    /// above the caption is the running head: the crop was the head, and the
    /// vision pass reported that the figure was not on the page.
    ///
    /// Such a page is read in horizontal strips, each credited with the
    /// characters of every text line whose bounds cross it. Body text fills a
    /// strip — two Nature columns put well over a hundred characters in a
    /// line's height, a preprint's single column ninety — while a figure's
    /// row of tick labels and condition names puts a few dozen at most,
    /// however wide the row is. Width is no help here: `selectionsByLine`
    /// joins the labels of side-by-side panels into one page-wide line. A run
    /// of full strips is a block of prose; a lone full strip is a figure's
    /// densest row of labels and stays in the figure. The strips are filled
    /// from the page's lines rather than by selecting each strip's rectangle:
    /// a rectangle selection credits a line to one strip only, so the strips
    /// of a paragraph alternate full and empty and never form a run.

    /// The horizontal strips a page is read in.
    static let proseStripCount = 100

    /// A strip holding at least this many characters of text is a line of
    /// prose.
    static let proseStripMinimumCharacters = 60

    /// This many prose strips in a row are a block of body text; fewer are a
    /// figure's row of labels.
    static let proseBlockMinimumStrips = 3

    /// Text within this share of the page's bottom is the folio, not a figure.
    static let footDepth: CGFloat = 0.05

    /// A caption whose line starts within this share of the page's top, with
    /// nothing printed above it but the running head, opens the page.
    static let leadingCaptionDepth: CGFloat = 0.25

    /// A band shorter than this share of the page is not a figure that
    /// filled its page.
    static let uncaptionedFigureMinimumHeightShare: CGFloat = 0.35

    /// A band with fewer than this share of its pixels inked is white space —
    /// the foot of a title page — and not a figure.
    static let uncaptionedFigureMinimumInkShare = 0.01

    /// True when `caption` is the first thing printed on `page` below its
    /// running head: the caption of a figure that filled the page before.
    static func captionLeadsPage(_ caption: String, on page: PDFPage) -> Bool {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0,
              let captionBounds = captionBounds(of: caption, on: page),
              captionBounds.maxY >= box.maxY - box.height * leadingCaptionDepth,
              let selection = page.selection(for: box) else { return false }
        let headTop = box.maxY - box.height * runningHeadDepth
        for line in textLines(of: selection) {
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0,
                  bounds.minY >= captionBounds.maxY - 1,
                  bounds.minY < headTop,
                  let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return false
        }
        return true
    }

    /// The tallest span of the page holding no block of body text, running
    /// head or folio, in PDF page coordinates; nil when the page is prose
    /// from head to foot.
    static func proseFreeBand(on page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0 else { return nil }
        let stripHeight = box.height / CGFloat(proseStripCount)
        let headBottom = runningHeadBounds(on: page)?.minY ?? box.maxY
        let footTop = box.minY + box.height * footDepth
        var characters = [Int](repeating: 0, count: proseStripCount)
        for line in page.selection(for: box).map(textLines) ?? [] {
            let bounds = line.bounds(for: page)
            let count = (line.string ?? "").filter { !$0.isWhitespace }.count
            guard bounds.height > 0, bounds.width > 0, count > 0 else { continue }
            let first = Int(((box.maxY - bounds.maxY) / box.height * CGFloat(proseStripCount)).rounded(.down))
            let last = Int(((box.maxY - bounds.minY) / box.height * CGFloat(proseStripCount)).rounded(.up)) - 1
            let lower = max(0, first)
            let upper = min(proseStripCount - 1, max(first, last))
            guard lower <= upper else { continue }
            for strip in lower...upper { characters[strip] += count }
        }
        var prose = [Bool](repeating: false, count: proseStripCount)
        var blocked = [Bool](repeating: false, count: proseStripCount)
        for index in 0..<proseStripCount {
            let stripTop = box.maxY - stripHeight * CGFloat(index)
            let stripBottom = stripTop - stripHeight
            if stripTop > headBottom {
                blocked[index] = true
                continue
            }
            if stripBottom < footTop {
                blocked[index] = characters[index] > 0
                continue
            }
            prose[index] = characters[index] >= proseStripMinimumCharacters
        }
        var bodyText = [Bool](repeating: false, count: proseStripCount)
        var index = 0
        while index < proseStripCount {
            guard prose[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < proseStripCount, prose[end + 1] { end += 1 }
            if end - index + 1 >= proseBlockMinimumStrips {
                for strip in index...end {
                    blocked[strip] = true
                    bodyText[strip] = true
                }
            }
            index = end + 1
        }
        var best: Range<Int>?
        index = 0
        while index < proseStripCount {
            guard !blocked[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < proseStripCount, !blocked[end + 1] { end += 1 }
            if best.map({ end - index + 1 > $0.count }) ?? true {
                best = index..<(end + 1)
            }
            index = end + 1
        }
        guard let best else { return nil }
        // A line of text registers in the strip holding most of its glyphs,
        // and its ascenders reach into the strip above: the band would end on
        // a sliver of the first line of body text (page 8 of the
        // cardiac-sodium paper). Give a strip back on each side
        // that meets body text; a figure and its neighbouring paragraph are
        // always further apart than that. The bounds are trimmed as plain
        // integers: a one- or two-strip gap between paragraphs trims past
        // itself, and building that Range traps.
        var lower = best.lowerBound
        var upper = best.upperBound
        if lower > 0, bodyText[lower - 1] { lower += 1 }
        if upper < proseStripCount, bodyText[upper] { upper -= 1 }
        guard lower < upper else { return nil }
        let span = lower..<upper
        return CGRect(
            x: box.minX,
            y: box.maxY - stripHeight * CGFloat(span.upperBound),
            width: box.width,
            height: stripHeight * CGFloat(span.count)
        )
    }

    /// The band a figure occupies on a page that prints no caption for it:
    /// the page's prose-free span when it is tall enough to be a figure that
    /// filled the page and holds ink. A page of prose, and a title page whose
    /// lower half is white, yield nil.
    static func uncaptionedFigureBand(on page: PDFPage, mask: PageInkMask? = nil) -> CGRect? {
        guard let band = proseFreeBand(on: page) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard band.height >= box.height * uncaptionedFigureMinimumHeightShare,
              let mask = mask ?? self.mask(for: page),
              let pixels = PixelBox(pdfRect: band, pageBounds: box, in: mask) else { return nil }
        let inkShare = Double(mask.inkCount(within: pixels)) / Double(pixels.width * pixels.height)
        return inkShare >= uncaptionedFigureMinimumInkShare ? band : nil
    }

    // MARK: - Whether a page shows a figure

    /// A page inked outside its lines of text over less than this share of
    /// its body shows no figure. Measured: pages of prose and
    /// caption boxes stay at or under 0.003 (the EMBO cristae paper's at
    /// 0.0000, an Advanced Science paper's with their rules and margin
    /// bands at 0.0016–0.0024), a figure page reaches 0.05 and up, and the
    /// sparsest figure met, the Biophysical Journal's two thin line plots
    /// (Fig. 2 of "How and when to measure mitochondrial inner membrane
    /// potentials"), 0.009.
    static let figureInkMinimumShare = 0.005

    /// A page's body — below the running head, above the foot — by where
    /// its ink falls: outside every line of its text (`figure`) or inside
    /// one (`text`), each a share of the body's area.
    struct PageInk: Equatable, Sendable {
        let figure: Double
        let text: Double
        /// The share of the body inked outside the text darker than
        /// `strongInkThreshold`.
        let darkFigure: Double
        /// `darkFigure` less the rows drawn dark across most of the page's
        /// width: a table's rules, or an image as wide, which reads as a
        /// figure without it.
        let darkFigureOffRules: Double

        /// The page shows a figure somewhere on it.
        var showsFigure: Bool { figure >= PaperFigureRectRefiner.figureInkMinimumShare }

        /// A figure is what the page is: it shows one, and more of its ink
        /// falls outside its text than inside. A page of prose, or a table —
        /// its rules and shading are ink outside the text too, but its cells
        /// outweigh them — is not, whatever it also shows. The pages a legend
        /// printed elsewhere is paired with must be figure pages: a
        /// supplementary table overleaf a legend was taken for its figure.
        /// Some of that ink is dark: a Nature accepted
        /// manuscript sets "ARTICLE IN PRESS" across every page in a pale
        /// grey, and its page of one sentence was taken for a figure's. A
        /// page drawn dark, off any rules, over half as much as its text
        /// inks is a figure however many labels it prints, where a table's
        /// dark marks are its rules: the same manuscript's scatter plots,
        /// their points named gene by gene, were left out, and its legends
        /// were paired with the figures after theirs.
        var isFigurePage: Bool {
            showsFigure && darkFigure >= PaperFigureRectRefiner.figureInkMinimumShare
                && (figure > text || darkFigureOffRules * 2 >= text)
        }
    }

    /// The page's ink, split by its lines of text; nil for a page this
    /// cannot read. Prose, captions, tables' cells, running heads and folios
    /// keep their ink inside their own lines; a figure's image, plot lines,
    /// bars and axes fall outside them, while the words it prints are text
    /// like any other. So a page of text alone measures close to no figure
    /// ink, however many labels a figure prints — where `proseFreeBand`
    /// counts the characters of a line and can take a figure's densest row
    /// of labels for a paragraph.
    static func pageInk(on page: PDFPage, mask: PageInkMask? = nil) -> PageInk? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0,
              let mask = mask ?? self.mask(for: page) else { return nil }
        var text = [Bool](repeating: false, count: mask.width * mask.height)
        for line in page.selection(for: box).map(textLines) ?? [] {
            let bounds = line.bounds(for: page)
            // A pixel's margin around the line takes its antialiasing.
            guard isTextLineBox(bounds, on: box),
                  let pixels = PixelBox(pdfRect: bounds.insetBy(dx: -1, dy: -1), pageBounds: box, in: mask)
            else { continue }
            for row in pixels.top...pixels.bottom {
                let offset = row * mask.width
                for column in pixels.left...pixels.right { text[offset + column] = true }
            }
        }
        // The body starts under the head the page's text and white place. A
        // head found only because it runs is left in it, with its rule: the
        // shares that tell a figure page were measured with them in, and
        // without its rule under "Article" the page of Extended Data Fig. 10
        // of 10.1038/s41586-025-09969-x, a few thin structures over their
        // legend, fell under `figureInkMinimumShare`, and the legend was
        // paired with the Reporting Summary after it.
        let headBottom = runningHead(on: page, mask: mask, includingHeadsThatRun: false).flatMap {
            PixelBox(pdfRect: $0.bounds, pageBounds: box, in: mask)?.bottom
        } ?? -1
        let top = headBottom + 1
        let bottom = Int((Double(mask.height) * (1 - Double(footDepth))).rounded()) - 1
        guard top < bottom else { return nil }
        let body = PixelBox(left: 0, top: top, right: mask.width - 1, bottom: bottom)
        let area = Double(body.width * body.height)
        let figure = mask.inkCount(within: body, excluding: text)
        // A table's rule runs dark across most of the page's width.
        var dark = 0
        var offRules = 0
        for row in body.top...body.bottom {
            let inRow = mask.strongInkCount(within: PixelBox(left: 0, top: row, right: mask.width - 1, bottom: row), excluding: text)
            dark += inRow
            if inRow * 5 < mask.width * 2 { offRules += inRow }
        }
        return PageInk(
            figure: Double(figure) / area,
            text: Double(mask.inkCount(within: body) - figure) / area,
            darkFigure: Double(dark) / area,
            darkFigureOffRules: Double(offRules) / area
        )
    }

    /// True when the page shows a figure anywhere on it (`PageInk.showsFigure`).
    static func showsFigure(_ page: PDFPage, mask: PageInkMask? = nil) -> Bool {
        pageInk(on: page, mask: mask)?.showsFigure ?? false
    }

    // MARK: - Running head

    /// The share of the page, from its top, a running head may occupy.
    static let runningHeadDepth: CGFloat = 0.12

    /// A text line at least this wide, as a share of the page, is a line of
    /// prose rather than a label inside a figure.
    static let runningHeadMinimumWidthShare: CGFloat = 0.45

    /// How far under the row above, as a share of its own height, the next
    /// row of a banner may start: set at their line pitch, a banner's lines
    /// leave about half a line between them, a figure's rows of labels a whole
    /// one. A gap of a full row height let Nature's "Brief Communication"
    /// head take in Figure 1's three top rows (panel letters, panel titles,
    /// legends), 68 pt in all, and the crop started under them.
    /// Over the 2,979 figure pages of the library, 0.6 changed the head of 65
    /// pages, every one a head that had taken in figure rows or body text, and
    /// left the one head set 0.52 of a row under a badge line (RSC's "View
    /// Article Online") as it was, which 0.5 lost.
    static let bannerLinePitchShare: CGFloat = 0.6

    /// A row of the page's top no wider than this share of the page that is
    /// not written text is a mark (a journal's logo, a lone panel letter) the
    /// head's search passes over. A figure's row of panel titles is wider.
    /// Over the 21,808 pages of the library's first 40 pages a paper, this
    /// and the written-text rule changed the head of 15 pages, every one a
    /// head that was a figure's or a table's row.
    static let runningHeadMarkMaximumWidthShare: CGFloat = 0.1

    /// A row of the page's top this short, holding a digit, is its folio: a
    /// page number ("38", "e1234", "Page 4") set alone over the running head.
    static let folioMaximumCharacters = 6

    /// How far under its running head, as a share of the page's height, a
    /// journal sets the rule that closes the head off from the page.
    static let headRuleReach: CGFloat = 0.02

    /// A rule under a running head is at most this share of the page's
    /// height thick; a band any thicker is drawn, not ruled.
    static let headRuleMaximumHeightShare: CGFloat = 0.004

    /// How many pages either side of a page its running head is looked for
    /// again (`runs(_:on:among:)`): the next page, and the next on the same
    /// side of the spread.
    static let runningHeadRecurrenceReach = 2

    /// A row of the page's top printing fewer letters than this is no head
    /// that runs, however alike the pages: a panel letter set at the same
    /// place on page after page of Extended Data figures.
    static let runningHeadMinimumLetters = 4

    /// A rule or bar set down the margin beside a running head is at most
    /// this share of the page wide: Nature's hairline, Nature Reviews' red
    /// bar at the page's edge. A figure's ink beside the head is wider.
    static let sideBandMaximumWidthShare = 0.05

    /// A page's running head, in PDF page coordinates: the head and the
    /// rule under it, and the rules and bars a journal sets down the margin
    /// beside it (`sideBands(beside:reach:in:)`), which are no figure's
    /// either.
    struct RunningHead: Equatable, Sendable {
        let bounds: CGRect
        let sideBands: [CGRect]
    }

    /// The lines of prose across the top of the page — a preprint server's
    /// banner, a journal's running head — in PDF page coordinates, or nil when
    /// there are none. A full-page figure's crop otherwise starts at them:
    /// they are ink in the figure's band, and nothing in the ink says they are
    /// not the figure. Their shape does: text spanning the page at the very
    /// top, which no figure prints.
    ///
    /// Read as rows, from the top. The head is the first row whose pieces
    /// together span the page — EMBO sets the author at the left and the
    /// journal at the right, two short lines on one baseline — and the rows
    /// set close under it, a banner's second and third lines. Rows set at
    /// their line pitch over it are passed over, as Nature's "Article" over
    /// the head is. A row with a margin's gap above it is the page's body,
    /// and the search ends there: only a folio set alone over the head
    /// (`folioMaximumCharacters`) is passed over across a margin. The head is
    /// not simply any single line half the page wide in the top
    /// eighth: EMBO's split head is not one, and Figure 1's row of panel
    /// titles under it is, so the cristae paper's figures would lose their top
    /// row of titles. Nor is every row too narrow to be the head passed
    /// over, margin or not: a head set short at one side would lead
    /// the search into the page's body (on 1,862 pages of the library the
    /// head would be the body's first lines, and on the white paper "Engineered
    /// human resilience and durability" it would be Figure 2's panel letter
    /// joined to the other column's second line of text, and on another page
    /// Figure 3's row of stage titles, each cut off the top of its figure).
    ///
    /// With `mask`, the page's ink, a head set short is found as well: the
    /// page's topmost line, when it is written text with white under it at
    /// least its own height before anything else is inked (JBC and the
    /// Biophysical Journal set a title or the authors alone in a corner, the
    /// white paper its title and date at the right). And the rule a journal
    /// sets under its head goes with the head (`headRule(under:in:)`).
    ///
    /// A head set short with little white under it is found when it runs
    /// (`runningHeadThatRuns(rows:on:mask:)`): Nature's "Article", ruled off
    /// a few points over the figure's panel letters, the boxed "LETTER |
    /// RESEARCH", Nature Reviews' "REVIEWS" beside its red bar, "SCIENCE
    /// ADVANCES | RESEARCH ARTICLE", a Springer Nature journal's authors
    /// over their rule and folio. Each counts as a head, or a crop
    /// that reached the top of its page takes the journal's head in with its
    /// figure. And a hairline running off the page's edge with nothing over
    /// it is a head too (`bareHeadRule(in:)`): Nature rules a left-hand page
    /// so, with no label.
    static func runningHeadBounds(on page: PDFPage, mask: PageInkMask? = nil) -> CGRect? {
        runningHead(on: page, mask: mask)?.bounds
    }

    /// The running head (`runningHeadBounds(on:mask:)`) and the rules and
    /// bars beside it. `includingHeadsThatRun: false` leaves out a head found
    /// only because it runs and a bare rule, and finds what the page's text
    /// and white place alone (`pageInk(on:mask:)` says why).
    static func runningHead(on page: PDFPage, mask: PageInkMask? = nil, includingHeadsThatRun: Bool = true) -> RunningHead? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0 else { return nil }
        let (headRegion, lines, rows) = headRows(on: page)
        var head: CGRect?
        var above: CGRect?
        var onlyFolios = true
        let bodyText = rows.isEmpty ? [] : bodyTextLines(on: page)
        for row in rows {
            if let above, above.minY - row.bounds.maxY > row.bounds.height * bannerLinePitchShare {
                // A banner's next line is set at its line pitch, a fraction of
                // a line under the one above (`bannerLinePitchShare`); the
                // body starts after a margin, however wide its first row: a
                // column's line beside a figure's panel letter, a figure's
                // titles set across it.
                guard head == nil, onlyFolios else { break }
            }
            // The head stops where the body begins: the first lines of
            // Nature's left column, joined with the rotated axis title of the
            // plot beside them into one wide row, were read as a head and wiped
            // the top third of that plot out of the crop (Fig. 1 of the
            // mtDNA-in-blood paper). What is above them stays.
            if bodyText.contains(where: { $0.intersects(row.bounds) }) { break }
            above = row.bounds
            guard row.bounds.width >= box.width * runningHeadMinimumWidthShare else {
                if head != nil { break }
                // A banner's short line is written text, a folio or a mark (the
                // "ll" over Cell Press's head). A figure's row of panel letters
                // and titles is none of them: passing it over let the row of
                // tick labels under it become the head, and Fig. 5 of the
                // mtDNA-in-blood paper was cropped from under its top panels.
                guard isFolio(row.text)
                    || row.bounds.width <= box.width * runningHeadMarkMaximumWidthShare
                    || isWrittenLine(row.bounds, characters: row.text.filter { !$0.isWhitespace }.count, on: box) else { break }
                onlyFolios = onlyFolios && isFolio(row.text)
                continue
            }
            head = head.map { $0.union(row.bounds) } ?? row.bounds
        }
        guard let mask else { return head.map { RunningHead(bounds: $0, sideBands: []) } }
        let last = mask.height - 1
        func blank(_ row: Int) -> Bool { !mask.rowHasInk(row, from: 0, through: mask.width - 1) }
        /// The last row of the short head's own ink.
        var shortHeadBottom: Int?
        if head == nil,
           let first = lines.first(where: { isTextLineBox($0.bounds, on: box) }),
           first.bounds.minY >= headRegion.minY,
           isWrittenLine(first.bounds, characters: first.text.filter { !$0.isWhitespace }.count, on: box),
           let line = PixelBox(pdfRect: first.bounds, pageBounds: box, in: mask) {
            // White under it, or under the rule set under it, for its own
            // height. Its ink may reach a line's height under its box first:
            // its descenders, the frame JASN draws round "BASIC RESEARCH"
            // at the page's other side.
            let from = (headRule(under: line, in: mask)?.bottom ?? line.bottom) + 1
            if from + line.height <= last, let clear = (from...(from + line.height)).first(where: { row in
                (row...min(last, row + line.height - 1)).allSatisfy(blank)
            }) {
                head = first.bounds
                shortHeadBottom = clear - 1
            }
        }
        guard let found = head else {
            guard includingHeadsThatRun else { return nil }
            if let running = runningHeadThatRuns(rows: rows, on: page, mask: mask) { return running }
            return bareHeadRule(in: mask).map { RunningHead(bounds: $0.pdfRect(in: box, mask: mask), sideBands: []) }
        }
        guard var headBox = PixelBox(pdfRect: found, pageBounds: box, in: mask) else {
            return RunningHead(bounds: found, sideBands: [])
        }
        let textBottom = headBox.bottom
        headBox.bottom = max(headBox.bottom, shortHeadBottom ?? headBox.bottom)
        if let rule = headRule(under: headBox, in: mask) { headBox = headBox.union(rule) }
        guard headBox.bottom > textBottom else { return RunningHead(bounds: found, sideBands: []) }
        return RunningHead(bounds: found.union(headBox.pdfRect(in: box, mask: mask)), sideBands: [])
    }

    /// The lines of the page's body paragraphs that run on under their first
    /// line: three or more lines of one block of written text
    /// (`PageText.paragraphs`), set one under another. A running head is set
    /// apart from the body by a margin and is never one of them.
    private static func bodyTextLines(on page: PDFPage) -> [CGRect] {
        let box = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: box) else { return [] }
        let lines: [PageText.Line] = textLines(of: selection).compactMap { line in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0, isTextLineBox(bounds, on: box) else { return nil }
            let characters = (line.string ?? "").filter { !$0.isWhitespace }.count
            return PageText.Line(
                bounds: bounds,
                isWritten: isWrittenLine(bounds, characters: characters, on: box),
                captionLabel: nil,
                isLabelAlone: false,
                endsSentence: false,
                pageHeight: box.height,
                opensCaption: false
            )
        }
        return PageText.paragraphs(of: lines, pageWidth: box.width)
            .filter { !$0.isCaption && $0.lines.count >= 3 }
            .flatMap(\.lines)
    }

    /// The page's text across its top (`runningHeadDepth`), top first, in PDF
    /// page coordinates: that band, its lines, and the rows they make —
    /// lines that share a stretch of height with a row's first line.
    private static func headRows(on page: PDFPage) -> (
        region: CGRect,
        lines: [(bounds: CGRect, text: String)],
        rows: [(bounds: CGRect, text: String)]
    ) {
        let box = page.bounds(for: .mediaBox)
        let headRegion = CGRect(
            x: box.minX,
            y: box.maxY - box.height * runningHeadDepth,
            width: box.width,
            height: box.height * runningHeadDepth
        )
        guard let selection = page.selection(for: headRegion) else { return (headRegion, [], []) }
        let lines = textLines(of: selection)
            .map { (bounds: $0.bounds(for: page), text: $0.string ?? "") }
            .filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.bounds.maxY > $1.bounds.maxY }
        var rows: [(bounds: CGRect, text: String)] = []
        var rowTop: CGRect?
        for line in lines where line.bounds.minY >= headRegion.minY {
            if let first = rowTop, line.bounds.maxY > first.minY, let row = rows.last {
                rows[rows.count - 1] = (row.bounds.union(line.bounds), row.text + " " + line.text)
            } else {
                rowTop = line.bounds
                rows.append(line)
            }
        }
        return (headRegion, lines, rows)
    }

    /// The page's running head when it is set short with little white under
    /// it, found because it runs: the page's topmost row, written text, that
    /// a page near it prints as well (`runs(_:on:among:)`), with the rows set
    /// at its pitch under it that run too — a two-line running title and its
    /// authors, a folio — and the rule under it. Nil when anything else is
    /// inked above it or level with it, bar the rules and bars set down the
    /// margin beside it (`sideBands(beside:reach:in:)`); when its ink runs
    /// on under it more than a line's height, so that it is set on the
    /// figure; or when less white than a crop leaves under a head
    /// (`regionGap(in:)`) parts it from what follows.
    ///
    /// White under a head its own height is the test a single page allows,
    /// and Nature fails it: "Article" is ruled off a few points over the
    /// figure's panel letters, and a hairline down the margin inks every row
    /// beside it. A figure's title set at the top of its page, which that
    /// test keeps out, is its own: no other page prints it there.
    private static func runningHeadThatRuns(
        rows: [(bounds: CGRect, text: String)],
        on page: PDFPage,
        mask: PageInkMask
    ) -> RunningHead? {
        let box = page.bounds(for: .mediaBox)
        guard let first = rows.first,
              isWrittenLine(first.bounds, characters: first.text.filter { !$0.isWhitespace }.count, on: box),
              mayRun(first),
              let line = PixelBox(pdfRect: first.bounds, pageBounds: box, in: mask) else { return nil }
        let nearby = nearbyHeadRows(of: page)
        guard runs(first, on: page, among: nearby) else { return nil }
        var block = first.bounds
        for row in rows.dropFirst() {
            guard block.minY - row.bounds.maxY <= row.bounds.height,
                  isFolio(row.text)
                    || isWrittenLine(row.bounds, characters: row.text.filter { !$0.isWhitespace }.count, on: box),
                  runs(row, on: page, among: nearby) else { break }
            block = block.union(row.bounds)
        }
        guard var head = PixelBox(pdfRect: block, pageBounds: box, in: mask) else { return nil }
        let reach = line.height
        let last = mask.width - 1
        let span = max(0, head.left - reach)...min(last, head.right + reach)
        let bands = sideBands(beside: head, reach: reach, in: mask)
        func inked(_ row: Int, from first: Int = 0, through end: Int = last) -> Bool {
            mask.rowHasInk(row, from: first, through: end, apartFrom: bands)
        }
        // Nothing but the head, above it and level with it, down to its
        // descenders, which may reach the rule under it: anything inked
        // beside it lower than that goes on under it, where the white is
        // read.
        guard !(0...max(head.top, head.bottom - reach / 4)).contains(where: {
            inked($0, through: span.lowerBound - 1) || inked($0, from: span.upperBound + 1)
        }) else { return nil }
        // Its own ink under its box: the frame round "LETTER | RESEARCH".
        var bottom = head.bottom
        while bottom < mask.height - 1, bottom - head.bottom < reach,
              inked(bottom + 1, from: span.lowerBound, through: span.upperBound) { bottom += 1 }
        guard bottom - head.bottom < reach else { return nil }
        head.bottom = bottom
        if let rule = headRule(under: head, in: mask, apartFrom: bands, whiteUnderBleed: 2) { head = head.union(rule) }
        let gap = regionGap(in: mask)
        guard head.bottom + gap < mask.height, !(head.bottom + 1...head.bottom + gap).contains(where: { inked($0) }) else { return nil }
        return RunningHead(
            bounds: block.union(head.pdfRect(in: box, mask: mask)),
            sideBands: bands.map { $0.pdfRect(in: box, mask: mask) }
        )
    }

    /// Whether a page within `runningHeadRecurrenceReach` of `page`
    /// (`nearbyHeadRows(of:)`) prints `row` at its height: the same words,
    /// or a folio when `row` is one. A journal sets its label, a running
    /// title or the authors on every page alike, on a left-hand page often
    /// mirrored ("LETTER | RESEARCH" at the right, "RESEARCH | LETTER" at
    /// the left), where a figure's titles are its own. Letters are compared
    /// and nothing else, so a folio set in the same row does not count; a
    /// row that may not run (`mayRun`) never does.
    private static func runs(
        _ row: (bounds: CGRect, text: String),
        on page: PDFPage,
        among nearby: [(depth: CGFloat, height: CGFloat, text: String)]
    ) -> Bool {
        guard mayRun(row) else { return false }
        let folio = isFolio(row.text)
        let printed = headWords(row.text)
        let depth = page.bounds(for: .mediaBox).maxY - row.bounds.maxY
        return nearby.contains { candidate in
            abs(candidate.depth - depth) <= max(1, row.bounds.height / 4)
                && abs(candidate.height - row.bounds.height) <= row.bounds.height / 5
                && (folio ? isFolio(candidate.text) : headWords(candidate.text) == printed)
        }
    }

    /// Whether `row` could be a head that runs: a folio, or a row of at
    /// least `runningHeadMinimumLetters` letters that opens no caption. A
    /// caption's label runs from page to page when figures follow one
    /// another ("FIGURE 3" over one page's figure, "FIGURE 4" over the
    /// next's), and so does a panel's letter.
    private static func mayRun(_ row: (bounds: CGRect, text: String)) -> Bool {
        if isFolio(row.text) { return true }
        let opening = PaperFigureCaptionTitle.captionStart(in: row.text).map { String(row.text[$0...]) }
        return headWords(row.text).joined().count >= runningHeadMinimumLetters
            && opening.flatMap(PaperFigureCaptionTitle.label(openingLine:)) == nil
    }

    /// A row's words, letters only, lower-cased and sorted: what stays the
    /// same of a head from page to page.
    private static func headWords(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted()
    }

    /// The rows across the tops of the pages within
    /// `runningHeadRecurrenceReach` of `page` (`headRows(on:)`), each with
    /// how far under its page's top it is set.
    private static func nearbyHeadRows(of page: PDFPage) -> [(depth: CGFloat, height: CGFloat, text: String)] {
        guard let document = page.document else { return [] }
        let index = document.index(for: page)
        guard index != NSNotFound else { return [] }
        let others = (1...runningHeadRecurrenceReach).flatMap { [index - $0, index + $0] }
            .filter { $0 >= 0 && $0 < document.pageCount && $0 != index }
        return others.compactMap { document.page(at: $0) }.flatMap { neighbour in
            let top = neighbour.bounds(for: .mediaBox).maxY
            return headRows(on: neighbour).rows.map { (depth: top - $0.bounds.maxY, height: $0.bounds.height, text: $0.text) }
        }
    }

    /// The rules and bars a journal sets down the margin beside its running
    /// head, in the mask's pixels: runs of columns clear of the head's own,
    /// each at most `sideBandMaximumWidthShare` of the page wide, inked on
    /// three rows in four from the head's first row of ink to `reach` under
    /// its last, and as tall as they stay inked. Nature rules the margin of
    /// an article's pages from its "Article" label to the foot; Nature
    /// Reviews sets a red bar at the page's edge beside "REVIEWS". Either
    /// inks every row, so no white is ever under the head beside it, and
    /// left on the page the bar is a figure's to the crop.
    fileprivate static func sideBands(beside head: PixelBox, reach: Int, in mask: PageInkMask) -> [PixelBox] {
        guard let ink = inkBounds(within: head, in: mask) else { return [] }
        let rows = ink.top...min(mask.height - 1, ink.bottom + reach)
        let clearance = glyphOverhang(in: mask)
        let widest = Int(Double(mask.width) * sideBandMaximumWidthShare)
        func through(_ column: Int) -> Bool {
            guard column < head.left - clearance || column > head.right + clearance else { return false }
            return rows.filter { mask.isInked(row: $0, column: column) }.count * 4 >= rows.count * 3
        }
        var bands: [PixelBox] = []
        var column = 0
        while column < mask.width {
            guard through(column) else {
                column += 1
                continue
            }
            let left = column
            while column + 1 < mask.width, through(column + 1) { column += 1 }
            if column - left + 1 <= widest {
                var band = PixelBox(left: left, top: rows.lowerBound, right: column, bottom: rows.upperBound)
                while band.top > 0, mask.rowHasInk(band.top - 1, from: band.left, through: band.right) { band.top -= 1 }
                while band.bottom < mask.height - 1, mask.rowHasInk(band.bottom + 1, from: band.left, through: band.right) { band.bottom += 1 }
                bands.append(band)
            }
            column += 1
        }
        return bands
    }

    /// A hairline across the top of the page, with nothing inked above it,
    /// running off the page's edge, and white under it
    /// (`regionGap(in:)`), in the mask's pixels: a running head with no
    /// words, as Nature rules a left-hand page of an article. Nil when the
    /// page's topmost ink is anything else. A figure's line stops inside the
    /// margins; left on the page, this one was the crop's top edge, and took
    /// the crop out to the page's edge with it.
    fileprivate static func bareHeadRule(in mask: PageInkMask) -> PixelBox? {
        let last = mask.width - 1
        let depth = Int(Double(mask.height) * Double(runningHeadDepth))
        let thickest = max(2, Int(Double(mask.height) * Double(headRuleMaximumHeightShare)))
        var row = 0
        while row <= depth, !mask.rowHasInk(row, from: 0, through: last) { row += 1 }
        guard row <= depth else { return nil }
        let top = row
        while row - top < thickest, mask.rowHasInk(row, from: 0, through: last) { row += 1 }
        let bottom = row - 1
        let gap = regionGap(in: mask)
        guard !(bottom + 1...bottom + gap).contains(where: { mask.rowHasInk($0, from: 0, through: last) }),
              let rule = inkBounds(within: PixelBox(left: 0, top: top, right: last, bottom: bottom), in: mask),
              rule.left == 0 || rule.right == last,
              rule.width * 2 >= mask.width,
              (rule.left...rule.right).filter({ mask.columnHasInk($0, from: top, through: bottom) }).count * 10 >= rule.width * 9
        else { return nil }
        return rule
    }

    /// The white a figure's region leaves between itself and the text or
    /// running head that bounds it, in the mask's rows.
    fileprivate static func regionGap(in mask: PageInkMask) -> Int {
        max(1, Int(Double(mask.height) * 0.004))
    }

    /// How far, in the mask's rows, glyphs hang past their line's box: a
    /// descender, a bar, antialiasing.
    fileprivate static func glyphOverhang(in mask: PageInkMask) -> Int {
        max(1, Int((Double(mask.height) * 0.0025).rounded()))
    }

    /// Whether a row of the page's top is its folio alone.
    private static func isFolio(_ text: String) -> Bool {
        let printed = text.filter { !$0.isWhitespace }
        return printed.count <= folioMaximumCharacters && printed.contains { $0.isNumber }
    }

    /// The rule set under a running head, in the mask's pixels: a line of
    /// ink at most a hairline thick (`headRuleMaximumHeightShare`) within
    /// `headRuleReach` under the head, solid across at least the head's
    /// width and a quarter of the page, with white under it. The white
    /// paper rules its head off from the page, and the rule, left as ink, was
    /// the crop's top edge across both columns; a figure's frame is no rule,
    /// because its sides go on down from its top edge.
    ///
    /// The white is half the head's height, or `whiteUnderBleed` rows under
    /// a rule that runs off the page's edge, as no figure's line does:
    /// Nature sets the figure's panel letters four pixels under the rule
    /// under "Article". `bands`, the rules and bars down the margin beside
    /// the head (`sideBands(beside:reach:in:)`), are not read as ink.
    fileprivate static func headRule(
        under head: PixelBox,
        in mask: PageInkMask,
        apartFrom bands: [PixelBox] = [],
        whiteUnderBleed: Int? = nil
    ) -> PixelBox? {
        let last = mask.width - 1
        func inked(_ row: Int) -> Bool { mask.rowHasInk(row, from: 0, through: last, apartFrom: bands) }
        let reach = head.bottom + Int(Double(mask.height) * Double(headRuleReach))
        let thickest = max(2, Int(Double(mask.height) * Double(headRuleMaximumHeightShare)))
        var row = head.bottom + 1 + glyphOverhang(in: mask)
        while row < mask.height, row <= reach, !inked(row) { row += 1 }
        guard row < mask.height, row <= reach else { return nil }
        let top = row
        while row < mask.height, row - top < thickest, inked(row) { row += 1 }
        let bottom = row - 1
        guard let rule = inkBounds(within: PixelBox(left: 0, top: top, right: last, bottom: bottom), in: mask),
              rule.width >= max(head.width, Int(Double(mask.width) * Double(proseLineMinimumWidthShare))),
              (rule.left...rule.right).filter({ mask.columnHasInk($0, from: top, through: bottom) }).count * 10 >= rule.width * 9
        else { return nil }
        let bleeds = rule.left == 0 || rule.right == last
        let white = bleeds ? (whiteUnderBleed ?? max(1, head.height / 2)) : max(1, head.height / 2)
        let clearance = min(mask.height - 1, bottom + white)
        guard bottom < clearance, !(bottom + 1...clearance).contains(where: inked) else { return nil }
        return rule
    }

    // MARK: - Which side of the caption

    /// Which side of its caption a figure is on.
    enum FigureSide: Equatable, Sendable {
        case above
        case below
        /// The figure is left of its caption, the caption set beside it.
        case left
        case right
    }

    /// A band whose area is covered by prose lines beyond this share is prose
    /// — a legend, the running text — and not the figure.
    static let proseCoverage = 0.2

    /// A text line at least this wide, as a share of the page, is a line of
    /// prose. A column of running text or a legend runs the column's width —
    /// two-column journals set columns at 0.4 of the page and up — while a
    /// figure's labels, ticks and legend keys are a few words each.
    ///
    /// Width, not size, is what tells them apart. A floor of 9 pt for prose
    /// holds for preprints but misses Nature Communications, whose columns are
    /// 8.2 pt: no line on the page would count as body text, the side check
    /// would abstain, and the ink vote would crop Fig. 1 of the cardiac-sodium
    /// paper to the two columns of Results under its caption. Measuring the
    /// body size off the page instead loses the legends set smaller than the
    /// body — a 12 pt book
    /// with 10 pt legends, Science at 8.5 pt with 7.5 pt legends — and those
    /// are prose too. A figure's own text, whatever its size, is short.
    static let proseLineMinimumWidthShare: CGFloat = 0.25

    /// The side of the caption the figure is on, read off the text layer:
    /// the side that is prose is not it.
    ///
    /// The ink vote in `band` counts marks, and a long legend under a caption
    /// carries more marks than a sparse figure above it — Fig. 3 of the
    /// lysosome-aging preprint cropped to its own legend that
    /// way. Prose is easy to tell from a figure without counting ink: it is
    /// column-wide lines (`proseLineMinimumWidthShare`) covering most of
    /// their band, while a figure's text is short and sparse. When exactly one
    /// side reads as prose, the figure is on the other; when both or neither
    /// do, nil, and the ink vote stands.
    ///
    /// The running head is left out, as it is from the crop: a preprint's
    /// three-line banner is column-wide prose, and above a caption printed
    /// near the top of the page it is the whole band.
    static func figureSide(captionBounds: CGRect, on page: PDFPage) -> FigureSide? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, page.rotation % 360 == 0,
              let selection = page.selection(for: box) else { return nil }
        let top = runningHeadBounds(on: page)?.minY ?? box.maxY
        var aboveText: CGFloat = 0
        var belowText: CGFloat = 0
        for line in textLines(of: selection) {
            let bounds = line.bounds(for: page)
            guard bounds.width >= box.width * proseLineMinimumWidthShare, bounds.height > 0,
                  bounds.minY < top else { continue }
            if bounds.minY >= captionBounds.maxY {
                aboveText += bounds.width * bounds.height
            } else if bounds.maxY <= captionBounds.minY {
                belowText += bounds.width * bounds.height
            }
        }
        let aboveArea = max(0, top - captionBounds.maxY) * box.width
        let belowArea = max(0, captionBounds.minY - box.minY) * box.width
        let aboveIsProse = aboveArea > 0 && Double(aboveText / aboveArea) > proseCoverage
        let belowIsProse = belowArea > 0 && Double(belowText / belowArea) > proseCoverage
        switch (aboveIsProse, belowIsProse) {
        case (true, false): return .below
        case (false, true): return .above
        default: return nil
        }
    }

    /// The font of a selection's first glyph that is not whitespace.
    static func leadingFont(of selection: PDFSelection) -> PaperFigurePlatformFont? {
        guard let attributed = selection.attributedString, attributed.length > 0 else { return nil }
        let string = attributed.string as NSString
        var index = 0
        while index < string.length,
              let scalar = Unicode.Scalar(string.character(at: index)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            index += 1
        }
        guard index < string.length else { return nil }
        return attributed.attribute(.font, at: index, effectiveRange: nil) as? PaperFigurePlatformFont
    }

    // MARK: - Refinement

    /// The refined rectangle, or nil when there is nothing worth cropping to and
    /// the caller should render the whole page.
    ///
    /// - Parameters:
    ///   - rect: what the vision pass returned, or nil when it declined to place
    ///     the figure. Either way the page decides the final geometry.
    ///   - captionBounds: the caption's line, in PDF page coordinates —
    ///     `captionBounds(of:on:)` produces it. Without it the whole page is the
    ///     band, which still trims margins but cannot exclude body text.
    ///   - pageBounds: the page's media box, the frame `captionBounds` is in.
    ///   - sharesPageWithOtherFigures: true when another labelled figure is
    ///     printed on this page. It is what stops the sole-figure fallback from
    ///     discarding a rectangle that was doing the real work of choosing
    ///     between neighbours.
    ///   - allowsGrowth: false trims only. A panel of a figure is refined this
    ///     way: trimming slack cannot go wrong, while growing a panel could
    ///     reach into the one beside it, and the wrong panel is worse than a
    ///     loose crop of the right one.
    ///   - figureSide: which side of the caption the figure is on when the
    ///     text layer says (`figureSide(captionBounds:on:)`); nil lets the
    ///     ink decide.
    ///   - fallbackBand: the band to search when the page prints neither
    ///     the caption nor the figure's label — `uncaptionedFigureBand` — in
    ///     PDF page coordinates. Ignored when `captionBounds` is given.
    ///   - region: the figure's region (`figureRegion`). When given it is the
    ///     band, its mask is the ink, and the caption, side, head and
    ///     fallback band are not read.
    static func refined(
        _ rect: PaperFigureRect?,
        captionBounds: CGRect? = nil,
        pageBounds: CGRect? = nil,
        with mask: PageInkMask,
        sharesPageWithOtherFigures: Bool = false,
        allowsGrowth: Bool = true,
        figureSide: FigureSide? = nil,
        runningHead: CGRect? = nil,
        fallbackBand: CGRect? = nil,
        region: FigureRegion? = nil
    ) -> PaperFigureRect? {
        let mask = region?.mask ?? mask
        guard mask.width > 2, mask.height > 2 else { return nil }
        let wholePage = PixelBox(left: 0, top: 0, right: mask.width - 1, bottom: mask.height - 1)
        let anchored = region == nil
            ? band(captionBounds: captionBounds, pageBounds: pageBounds, in: mask, figureSide: figureSide)
            : nil
        let fallback: PixelBox? = captionBounds == nil
            ? fallbackBand.flatMap { rect in pageBounds.flatMap { PixelBox(pdfRect: rect, pageBounds: $0, in: mask) } }
            : nil
        var band = region?.box ?? anchored ?? fallback ?? wholePage
        if region == nil, let runningHead, let pageBounds, pageBounds.height > 0 {
            // The band starts under the running head, never at it.
            let headBottom = Int(((pageBounds.maxY - runningHead.minY) / pageBounds.height
                * Double(mask.height)).rounded())
            let gap = max(1, Int(Double(mask.height) * 0.004))
            band.top = max(band.top, min(band.bottom, headBottom + gap))
        }
        guard band.isValid else { return nil }

        var start = band
        if let rect, rect.isValid,
           let clamped = PixelBox(normalized: rect, in: mask).intersection(band) {
            start = clamped
        }
        guard var box = settled(start, boundedBy: band, in: mask, allowsGrowth: allowsGrowth)
        else { return nil }

        if !sharesPageWithOtherFigures {
            let bandInk = mask.inkCount(within: band)
            if bandInk > 0,
               Double(mask.inkCount(within: box)) / Double(bandInk) < minimumInkShareOfSoleFigure,
               let whole = settled(band, boundedBy: band, in: mask, allowsGrowth: allowsGrowth) {
                box = whole
            }
        }

        let area = Double(box.width * box.height) / Double(mask.width * mask.height)
        guard area < maximumUsefulArea else { return nil }
        let refined = box.normalized(in: mask)
        return refined.isValid ? refined : nil
    }

    /// The side of the caption the figure is on: whichever holds more ink. A
    /// figure sits above its caption almost always and below it for the
    /// occasional table, and measuring is cheaper than believing either rule.
    private static func band(
        captionBounds: CGRect?,
        pageBounds: CGRect?,
        in mask: PageInkMask,
        figureSide: FigureSide? = nil
    ) -> PixelBox? {
        guard let captionBounds, let pageBounds,
              pageBounds.width > 0, pageBounds.height > 0 else { return nil }
        // PDF pages measure up from the bottom, the mask measures down from the
        // top. This is the only place the two frames meet.
        let topEdge = Int(((pageBounds.maxY - captionBounds.maxY) / pageBounds.height
            * Double(mask.height)).rounded())
        let bottomEdge = Int(((pageBounds.maxY - captionBounds.minY) / pageBounds.height
            * Double(mask.height)).rounded())
        let gap = max(1, Int(Double(mask.height) * 0.004))

        let above = PixelBox(left: 0, top: 0, right: mask.width - 1, bottom: topEdge - gap)
        let below = PixelBox(left: 0, top: bottomEdge + gap, right: mask.width - 1, bottom: mask.height - 1)
        let aboveInk = above.isValid ? mask.inkCount(within: above) : 0
        let belowInk = below.isValid ? mask.inkCount(within: below) : 0
        guard max(aboveInk, belowInk) > 0 else { return nil }
        // The text layer's word wins when it has one and the side it names
        // holds ink at all; otherwise the marks decide.
        switch figureSide {
        case .above? where above.isValid && aboveInk > 0: return above
        case .below? where below.isValid && belowInk > 0: return below
        default: return aboveInk >= belowInk ? above : below
        }
    }

    private static func settled(
        _ box: PixelBox,
        boundedBy band: PixelBox,
        in mask: PageInkMask,
        allowsGrowth: Bool
    ) -> PixelBox? {
        let start = allowsGrowth ? grown(box, boundedBy: band, in: mask) : box
        guard let trimmed = inkBounds(within: start, in: mask) else { return nil }
        return padded(trimmed, boundedBy: band, in: mask)
    }

    // MARK: - Panels

    /// A blank run between two panels shorter than this many mask rows or
    /// columns is the space between two lines of one panel's text, not a
    /// gutter.
    static let minimumGutterPixels = 2

    /// The vision pass's panel rectangles with every overlap split at the
    /// white gutter between the two panels.
    ///
    /// Read by eye, neighbouring panels' rectangles overlap: on Figure 1 of
    /// the MitoSpace paper (Cell) panel A ran 0.023 of the page
    /// into panel B, which put B's heading, "Fragmented-to-Fused Phenotype",
    /// cut in half along the foot of A's card. No
    /// growing or trimming can take that out: the heading is ink inside A's
    /// rectangle, and it touches A's bottom edge. The page says where the two
    /// panels part — a run of white rows (or columns, for panels side by side)
    /// across the full width of both rectangles, since the line cuts both —
    /// and each rectangle stops at the middle of it. Of several runs between the two panels' centres, the
    /// one crossing the overlap wins, and of those, the one nearest its
    /// middle. Panels are split along whichever axis they overlap least on,
    /// which is one above the other for A and B and side by side for B and D.
    /// A pair with no white run between them is left as it was: nothing on
    /// the page says where one ends. Coordinates are normalized, top-left.
    static func separatedPanelRects(
        _ panels: [String: PaperFigureRect],
        with mask: PageInkMask
    ) -> [String: PaperFigureRect] {
        var boxes = panels.compactMapValues { rect -> PixelBox? in
            rect.isValid ? PixelBox(normalized: rect, in: mask) : nil
        }
        let labels = boxes.keys.sorted()
        var changed = Set<String>()
        for (index, first) in labels.enumerated() {
            for second in labels[(index + 1)...] {
                guard let p = boxes[first], let q = boxes[second], let overlap = p.intersection(q) else { continue }
                let rowShare = Double(overlap.height) / Double(min(p.height, q.height))
                let columnShare = Double(overlap.width) / Double(min(p.width, q.width))
                if rowShare <= columnShare {
                    let (upperLabel, lowerLabel) = p.top + p.bottom <= q.top + q.bottom ? (first, second) : (second, first)
                    guard var upper = boxes[upperLabel], var lower = boxes[lowerLabel],
                          let cut = gutter(
                            from: (upper.top + upper.bottom) / 2,
                            through: (lower.top + lower.bottom) / 2,
                            crossing: overlap.top...overlap.bottom,
                            isBlank: { !mask.rowHasInk($0, from: min(p.left, q.left), through: max(p.right, q.right)) }
                          ),
                          cut > upper.top, cut < lower.bottom else { continue }
                    upper.bottom = min(upper.bottom, cut - 1)
                    lower.top = max(lower.top, cut + 1)
                    boxes[upperLabel] = upper
                    boxes[lowerLabel] = lower
                    changed.formUnion([upperLabel, lowerLabel])
                } else {
                    let (leftLabel, rightLabel) = p.left + p.right <= q.left + q.right ? (first, second) : (second, first)
                    guard var left = boxes[leftLabel], var right = boxes[rightLabel],
                          let cut = gutter(
                            from: (left.left + left.right) / 2,
                            through: (right.left + right.right) / 2,
                            crossing: overlap.left...overlap.right,
                            isBlank: { !mask.columnHasInk($0, from: min(p.top, q.top), through: max(p.bottom, q.bottom)) }
                          ),
                          cut > left.left, cut < right.right else { continue }
                    left.right = min(left.right, cut - 1)
                    right.left = max(right.left, cut + 1)
                    boxes[leftLabel] = left
                    boxes[rightLabel] = right
                    changed.formUnion([leftLabel, rightLabel])
                }
            }
        }
        var result = panels
        for label in changed {
            if let box = boxes[label], box.isValid { result[label] = box.normalized(in: mask) }
        }
        return result
    }

    /// The middle of the white run between `start` and `end` (mask rows or
    /// columns) that parts two panels: of the runs at least
    /// `minimumGutterPixels` long, one crossing `overlap` if any does, and
    /// the one nearest the overlap's middle. Nil when there is none.
    private static func gutter(
        from start: Int,
        through end: Int,
        crossing overlap: ClosedRange<Int>,
        isBlank: (Int) -> Bool
    ) -> Int? {
        guard start < end else { return nil }
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for line in start...end {
            if isBlank(line) {
                if runStart == nil { runStart = line }
            } else if let open = runStart {
                runs.append(open...(line - 1))
                runStart = nil
            }
        }
        if let open = runStart { runs.append(open...end) }
        runs = runs.filter { $0.count >= minimumGutterPixels }
        let crossing = runs.filter { $0.overlaps(overlap) }
        let middle = (overlap.lowerBound + overlap.upperBound) / 2
        let best = (crossing.isEmpty ? runs : crossing).min { lhs, rhs in
            abs((lhs.lowerBound + lhs.upperBound) / 2 - middle) < abs((rhs.lowerBound + rhs.upperBound) / 2 - middle)
        }
        return best.map { ($0.lowerBound + $0.upperBound) / 2 }
    }

    /// A figure's rectangle and its panels' rectangles from the vision pass,
    /// overlaps split at their gutters (`separatedPanelRects`) and each grown
    /// onto the ink its edges cut through.
    ///
    /// The vision model reads rectangles off the page by eye, and the edge it
    /// gets wrong most is the one that slices ink: Figure 2h of the
    /// cardiac-sodium paper stopped a group of bars short of the
    /// panel's right edge, and the figure's own rectangle stopped short of
    /// the same labels, so the crop cut "ouab+CGP" in half. An edge that lands
    /// on ink moves outward until it lands on white, as `grown` does for a
    /// figure — the figure first, inside the page, then each panel inside the
    /// grown figure. A panel's edge never grows into another panel's
    /// rectangle: panels sit a gutter apart, and an edge that has reached a
    /// neighbour is on the neighbour's ink, not its own. An edge on white is
    /// left where it is, and nothing is trimmed: the model's slack around a
    /// panel is its letter and its axis title as often as it is paper.
    /// Coordinates are normalized, top-left.
    static func extendedPanelRects(
        _ panels: [String: PaperFigureRect],
        within figure: PaperFigureRect,
        with mask: PageInkMask
    ) -> (figure: PaperFigureRect, panels: [String: PaperFigureRect]) {
        guard figure.isValid else { return (figure, panels) }
        let wholePage = PixelBox(left: 0, top: 0, right: mask.width - 1, bottom: mask.height - 1)
        let figureBox = grown(PixelBox(normalized: figure, in: mask), boundedBy: wholePage, in: mask)
        let grownFigure = figureBox.normalized(in: mask)
        let separated = separatedPanelRects(panels, with: mask)
        let boxes = separated.compactMapValues { rect -> PixelBox? in
            rect.isValid ? PixelBox(normalized: rect, in: mask).intersection(figureBox) : nil
        }
        var result = separated
        for (label, box) in boxes {
            let others = boxes.filter { $0.key != label }.map(\.value)
            let extended = grown(box, boundedBy: figureBox, in: mask) { strip in
                !others.contains { $0.intersection(strip) != nil }
            }
            if extended.left != box.left || extended.top != box.top
                || extended.right != box.right || extended.bottom != box.bottom {
                result[label] = extended.normalized(in: mask)
            }
        }
        return (grownFigure.isValid ? grownFigure : figure, result)
    }

    // MARK: - The figure's region

    /// A line that prints at least this many characters for each
    /// line-height of its width is written text. A paragraph's lines print
    /// 1.5 to 2.5; a figure's row of panel letters or tick labels, which
    /// `selectionsByLine` joins across side-by-side panels into one
    /// page-wide line, 0.1 to 0.8.
    static let proseLineMinimumDensity: CGFloat = 1.2

    /// A line of text taller than this share of the page is not one line: a
    /// display title, or the labels of a plot that `selectionsByLine` joined
    /// into one box (Nature Aging).
    static let writtenLineMaximumHeightShare: CGFloat = 0.035

    /// Three lines justified to one measure at least this share of the page
    /// wide are a column of text, however narrow the column.
    static let justifiedLineMinimumWidthShare: CGFloat = 0.12

    /// How far a figure's text may sit from the rest of it, as a share of
    /// the page's height: a tick label from its axis, an axis title from its
    /// ticks, a panel letter set over its panel. A line of text further off
    /// is not the figure's.
    static let labelReach: CGFloat = 0.03

    /// A caption narrower than this share of the page may be set beside its
    /// figure; a wider one leaves no room there.
    static let sideCaptionMaximumWidthShare: CGFloat = 0.55

    /// How close to its caption, as a share of the page's height, a figure
    /// set above or below the caption comes. A side caption has nothing of
    /// its figure within this reach in its own column.
    static let captionClearance: CGFloat = 0.03

    /// A white run of columns at least this share of the page wide parts two
    /// figures, or two panels, set side by side.
    static let figureGutterShare = 0.012

    /// A region with less drawn ink than this share of the page holds no
    /// figure: what is left of a page's specks once its text is taken away.
    static let regionMinimumFigureShare = 0.001

    /// A region whose drawn ink stands on fewer rows than this share of the
    /// page's height holds no figure either: a journal's rule over a legend,
    /// as long as the column is wide, is a line one or two pixels high.
    static let regionMinimumFigureHeight = 0.02

    /// Where a figure is on its page, in the mask's pixels, and the page's
    /// ink less everything that is not the figure: the prose around it, the
    /// other figures' captions and ink, the running head, the folio. `refined`
    /// crops to the ink it leaves.
    struct FigureRegion {
        fileprivate let box: PixelBox
        let mask: PageInkMask
        /// Which side of its caption the figure is on; nil for a figure with
        /// no caption on its page.
        let side: FigureSide?

        /// The region, normalized with a top-left origin.
        var rect: PaperFigureRect { box.normalized(in: mask) }
    }

    /// What a crop has to know of the page's text, read once: every line,
    /// the paragraphs among them, and the lines that open a caption.
    struct PageText {
        struct Line {
            /// PDF page coordinates.
            var bounds: CGRect
            /// Set across the page and dense enough to be written text
            /// (`proseLineMinimumDensity`).
            let isWritten: Bool
            /// The figure label the line opens a caption with, lower-cased.
            let captionLabel: String?
            /// The line prints a caption's label and nothing after it, the
            /// title set apart in a face of its own.
            let isLabelAlone: Bool
            /// The line ends a sentence.
            let endsSentence: Bool
            /// The height of the page the line is on.
            let pageHeight: CGFloat
            /// The line opens a caption: it prints the label, or it carries
            /// on the row a label was set on in a face of its own — "FIGURE
            /// 5" in bold, then the title, two lines to PDFKit.
            var opensCaption: Bool
        }

        /// A paragraph's box and its lines' boxes, in PDF page coordinates.
        struct Paragraph {
            var bounds: CGRect
            var lines: [CGRect]
            /// The paragraph is a caption: it opens with a caption's label,
            /// or carries a caption on into the next column.
            var isCaption = false
            /// Its last line ends a sentence.
            var endsSentence = true

            /// Each line widened to the paragraph's measure, the median of
            /// its lines' left and right edges.
            var measuredLines: [CGRect] {
                let left = lines.map(\.minX).sorted()[lines.count / 2]
                let right = lines.map(\.maxX).sorted()[lines.count / 2]
                return lines.map { $0.union(CGRect(x: left, y: $0.minY, width: max(0, right - left), height: $0.height)) }
            }
        }

        let pageBounds: CGRect
        private(set) var lines: [Line]
        /// The page's paragraphs (`paragraphs(of:pageWidth:)`).
        let paragraphs: [Paragraph]
        let runningHead: CGRect?
        /// The rules and bars set down the margin beside the running head
        /// (`RunningHead.sideBands`).
        let runningHeadSideBands: [CGRect]

        /// `mask`, the page's ink, places the running head and the rules and
        /// bars beside it (`runningHead(on:mask:)`).
        init?(page: PDFPage, mask: PageInkMask) {
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0, page.rotation % 360 == 0,
                  let selection = page.selection(for: box) else { return nil }
            pageBounds = box
            lines = PaperFigureRectRefiner.textLines(of: selection).compactMap { line in
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0,
                      PaperFigureRectRefiner.isTextLineBox(bounds, on: box) else { return nil }
                let text = line.string ?? ""
                // From the label on, past any arrow set before it.
                let opening = PaperFigureCaptionTitle.captionStart(in: text).map { String(text[$0...]) }
                let label = opening.flatMap { PaperFigureCaptionTitle.label(openingLine: $0)?.lowercased() }
                return Line(
                    bounds: bounds,
                    isWritten: PaperFigureRectRefiner.isWrittenLine(
                        bounds,
                        characters: text.filter { !$0.isWhitespace }.count,
                        on: box
                    ),
                    captionLabel: label,
                    isLabelAlone: label != nil && opening.flatMap(PaperFigureCaptionTitle.title(from:)) == nil,
                    endsSentence: text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?:".contains($0) } ?? false,
                    pageHeight: box.height,
                    opensCaption: label != nil
                )
            }
            // The rest of a label's row starts the caption with it, and
            // starts where the label does: the lines under it are set from
            // the label's left edge. Only a label printed alone is one; a
            // caption's whole first line beside a column of text is not.
            let labels = lines.filter(\.isLabelAlone).map(\.bounds)
            for index in lines.indices where lines[index].captionLabel == nil {
                let bounds = lines[index].bounds
                guard let label = labels.first(where: { label in
                    min(label.maxY, bounds.maxY) - max(label.minY, bounds.minY) >= min(label.height, bounds.height) / 2
                        && label.maxX <= bounds.minX + 2 && bounds.minX - label.maxX <= box.width * 0.03
                }) else { continue }
                lines[index].opensCaption = true
                lines[index].bounds = bounds.union(label)
            }
            paragraphs = Self.paragraphs(of: lines, pageWidth: box.width)
            let head = PaperFigureRectRefiner.runningHead(on: page, mask: mask)
            runningHead = head?.bounds
            runningHeadSideBands = head?.sideBands ?? []
        }

        /// The page's paragraphs. Lines of written text are read top to
        /// bottom, and one set directly under a block's last line continues
        /// it when it is no wider than a paragraph's next line grows, or
        /// starts level with the block: a paragraph narrows only at its last
        /// line, and the next paragraph of its column starts where it did.
        /// So a figure's axis title over its caption starts a block of its
        /// own, while a reference list in a narrow column is one block. A
        /// caption starts a block too, even set a line under the legend
        /// before it, unless the line above breaks off mid-sentence.
        ///
        /// A block is prose when two of its lines are column-wide
        /// (`proseLineMinimumWidthShare`) and a third follows; when it opens
        /// a caption and runs on to a second line, as a legend set beside its
        /// figure in a column a sixth of the page wide does (Evolutionary
        /// Biology); or when three of its lines are justified to one measure
        /// (`justifiedLineMinimumWidthShare`), as JBC's column a fifth of the
        /// page wide beside a figure is. A figure's panel of text is ragged
        /// and has one wide line at most, and a title set on two centred
        /// lines over a panel is two lines alone (Nature Methods).
        ///
        /// A short line that is not written text, under a paragraph and
        /// level with its left edge, is its last line all the same, when it
        /// is one line of text: a rotated axis title level with a column, its
        /// box as tall as the plot, joined the paragraph over the plot and
        /// took the plot with it (Nature Aging).
        static func paragraphs(of lines: [Line], pageWidth: CGFloat) -> [Paragraph] {
            let order = lines.indices.sorted { lines[$0].bounds.maxY > lines[$1].bounds.maxY }
            let alignment = pageWidth * 0.025
            var blocks: [Paragraph] = []
            for index in order where lines[index].isWritten {
                let line = lines[index]
                let bounds = line.bounds
                if let block = blocks.lastIndex(where: {
                    let last = $0.lines[$0.lines.count - 1]
                    // A caption opens a paragraph of its own, unless the
                    // line above breaks off mid-sentence across the same
                    // measure: then its label is a reference in the text
                    // ("… as exemplified in / Fig. 5. The measured …").
                    guard !line.opensCaption || (!$0.endsSentence && last.width >= bounds.width * 0.9) else { return false }
                    return continues(bounds, under: last)
                        && (bounds.width * 0.85 <= last.width || abs(bounds.minX - $0.bounds.minX) <= alignment)
                }) {
                    blocks[block].bounds = blocks[block].bounds.union(bounds)
                    blocks[block].lines.append(bounds)
                    blocks[block].endsSentence = line.endsSentence
                } else {
                    blocks.append(Paragraph(bounds: bounds, lines: [bounds], isCaption: line.opensCaption, endsSentence: line.endsSentence))
                }
            }
            blocks.removeAll { block in
                let widths = block.lines.map(\.width)
                let wide = widths.filter { $0 >= pageWidth * PaperFigureRectRefiner.proseLineMinimumWidthShare }.count
                let measure = widths.sorted()[widths.count / 2]
                let justified = widths.filter {
                    abs($0 - measure) <= pageWidth * 0.01 && $0 >= pageWidth * PaperFigureRectRefiner.justifiedLineMinimumWidthShare
                }.count
                let paragraph = (wide >= 2 && block.lines.count >= 3) || (block.isCaption && block.lines.count >= 2)
                return !paragraph && justified < 3
            }
            for index in order where !lines[index].isWritten {
                let bounds = lines[index].bounds
                // A line of text still: set across the page, one line tall.
                guard bounds.width >= bounds.height * 2,
                      bounds.height <= lines[index].pageHeight * PaperFigureRectRefiner.writtenLineMaximumHeightShare,
                      let block = blocks.firstIndex(where: {
                    continues(bounds, under: $0.lines[$0.lines.count - 1]) && abs(bounds.minX - $0.bounds.minX) <= alignment
                        && bounds.maxX <= $0.bounds.maxX + alignment
                }) else { continue }
                blocks[block].bounds = blocks[block].bounds.union(bounds)
                blocks[block].lines.append(bounds)
                blocks[block].endsSentence = lines[index].endsSentence
            }
            // A legend set across two columns goes on in the second, level
            // with its first line and with no label of its own (Nature
            // Communications); that half is the caption's as well.
            let captions = blocks.filter(\.isCaption).map { $0.lines[0] }
            for index in blocks.indices where !blocks[index].isCaption {
                let first = blocks[index].lines[0]
                blocks[index].isCaption = captions.contains { caption in
                    abs(caption.maxY - first.maxY) <= min(caption.height, first.height) / 2 && caption.maxX < first.minX
                }
            }
            return blocks
        }

        /// `line` is set directly under `above`, as a paragraph's next line is.
        static func continues(_ line: CGRect, under above: CGRect) -> Bool {
            let height = max(line.height, above.height)
            let gap = above.minY - line.maxY
            guard gap > -height / 2, gap <= height else { return false }
            let overlap = min(line.maxX, above.maxX) - max(line.minX, above.minX)
            return overlap >= min(line.width, above.width) / 2
        }
    }

    /// The page's ink with its text that is no figure's taken off it.
    private struct ErasedPage {
        /// The ink, less paragraphs (with a legend's grey box around one),
        /// captions other than the one kept, the folio, and the running head
        /// with the rules and bars beside it.
        var mask: PageInkMask
        /// What was taken off, in the mask's pixels.
        let obstacles: [PixelBox]
        /// The lines of the paragraphs that are no caption: the running text.
        let runningText: [PixelBox]
        /// Every line of text on the page, a flag a pixel: what is inked
        /// outside them is drawn — an image, a plot's lines, an axis.
        let text: [Bool]
        /// The lines no obstacle holds: a figure's labels, and stray lines.
        let labels: [PixelBox]
        /// The first row under the running head.
        let top: Int
        /// The white left between a region and what bounds it.
        let gap: Int

        init(_ page: PageText, mask: PageInkMask, keeping caption: PixelBox?) {
            let box = page.pageBounds
            func pixels(_ rect: CGRect) -> PixelBox? { PixelBox(pdfRect: rect, pageBounds: box, in: mask) }
            let wholePage = PixelBox(left: 0, top: 0, right: mask.width - 1, bottom: mask.height - 1)
            let gap = PaperFigureRectRefiner.regionGap(in: mask)
            // The running head, set across the page or short in a corner,
            // with the rule under it (`runningHead(on:mask:)`).
            let head = page.runningHead.flatMap(pixels)
            self.gap = gap
            top = head.map { min(wholePage.bottom, $0.bottom + 1 + gap) } ?? 0
            let footTop = Int((Double(mask.height) * (1 - Double(PaperFigureRectRefiner.footDepth))).rounded())

            // A legend's grey box goes with its paragraph, and glyphs
            // overhang their line's box by a pixel or two: a column of text
            // left behind as specks is still ink to the crop.
            let growth = Int(Double(max(mask.width, mask.height)) * 0.02)
            let overhang = PaperFigureRectRefiner.glyphOverhang(in: mask)
            func obstacle(_ rect: CGRect) -> PixelBox? {
                pixels(rect).map { mask.filledSurround(of: $0, limit: growth).expanded(by: overhang, within: wholePage) }
            }
            // A paragraph line by line, each across the paragraph's measure:
            // a glyph PDFKit reads into no line (a symbol font's μ) is left
            // past a short line's end, while a running head set over a
            // narrow column beside a figure is wider than the column, and
            // the box around them all would take the figure's edge.
            let runningText = page.paragraphs.filter { !$0.isCaption }.flatMap(\.measuredLines).compactMap(obstacle)
            var obstacles = page.paragraphs.filter(\.isCaption).flatMap(\.measuredLines).compactMap(obstacle) + runningText
            for line in page.lines {
                guard let lineBox = pixels(line.bounds) else { continue }
                let isOtherCaption = line.captionLabel != nil && caption.map { lineBox.intersection($0) == nil } ?? true
                if lineBox.top >= footTop || isOtherCaption, let taken = obstacle(line.bounds) { obstacles.append(taken) }
            }
            self.obstacles = obstacles
            self.runningText = runningText
            var erased = mask
            for obstacle in obstacles { erased.erase(obstacle) }
            if let head { erased.erase(PixelBox(left: 0, top: 0, right: wholePage.right, bottom: min(wholePage.bottom, head.bottom + 1))) }
            for band in page.runningHeadSideBands.compactMap(pixels) { erased.erase(band) }
            self.mask = erased

            var text = [Bool](repeating: false, count: mask.width * mask.height)
            var labels: [PixelBox] = []
            for line in page.lines {
                guard let lineBox = pixels(line.bounds.insetBy(dx: -1, dy: -1)) else { continue }
                for row in lineBox.top...lineBox.bottom {
                    let offset = row * mask.width
                    for column in lineBox.left...lineBox.right { text[offset + column] = true }
                }
                if !obstacles.contains(where: { $0.contains(lineBox) }) { labels.append(lineBox) }
            }
            self.text = text
            self.labels = labels
        }

        /// The ink in `region` outside every line of text.
        func drawnInk(within region: PixelBox) -> Int {
            mask.inkCount(within: region, excluding: text)
        }

        /// Whether `region` holds a figure's worth of drawn ink
        /// (`regionMinimumFigureShare`, `regionMinimumFigureHeight`), some
        /// of it dark: a pale watermark across a page of legends is no figure.
        func holdsFigure(_ region: PixelBox) -> Bool {
            let minimum = Int(Double(mask.width * mask.height) * PaperFigureRectRefiner.regionMinimumFigureShare)
            return region.isValid
                && drawnInk(within: region) >= minimum
                && mask.strongInkCount(within: region, excluding: text) * 4 >= minimum
                && mask.inkedRows(within: region, excluding: text) >= Int(Double(mask.height) * PaperFigureRectRefiner.regionMinimumFigureHeight)
        }

        /// The first row under `edge` clear of the nearest obstacle above it
        /// that crosses `span`, or the first row under the running head.
        func stop(above edge: Int, across span: ClosedRange<Int>) -> Int {
            obstacles.filter { $0.bottom < edge && $0.crosses(span) }.map { $0.bottom + 1 + gap }.max().map { max(top, $0) } ?? top
        }

        func stop(below edge: Int, across span: ClosedRange<Int>) -> Int {
            obstacles.filter { $0.top > edge && $0.crosses(span) }.map { $0.top - 1 - gap }.min() ?? mask.height - 1
        }

        func stop(leftOf edge: Int, over rows: ClosedRange<Int>) -> Int {
            obstacles.filter { $0.right < edge && $0.top <= rows.upperBound && $0.bottom >= rows.lowerBound }
                .map { $0.right + 1 + gap }.max() ?? 0
        }

        func stop(rightOf edge: Int, over rows: ClosedRange<Int>) -> Int {
            obstacles.filter { $0.left > edge && $0.top <= rows.upperBound && $0.bottom >= rows.lowerBound }
                .map { $0.left - 1 - gap }.min() ?? mask.width - 1
        }

        /// Whether the ink at `ink` is set between two paragraphs of the
        /// running text, each within `reach` of it, neither of them
        /// `caption`'s. A caption is no running text: a figure between
        /// the text above it and its legend below it is a figure.
        func isInRunningText(_ ink: PixelBox, apartFrom caption: PixelBox, within reach: Int) -> Bool {
            let columns = ink.left...ink.right
            let paragraphs = runningText.filter { $0.intersection(caption) == nil && $0.crosses(columns) }
            return paragraphs.contains { $0.bottom < ink.top && $0.bottom >= ink.top - reach }
                && paragraphs.contains { $0.top > ink.bottom && $0.top <= ink.bottom + reach }
        }

        /// Takes off the lines of text in `region` that are not the figure's:
        /// a line is its when it comes within `reach` of the figure's drawn
        /// ink, or of a line already taken as its. A figure drawn entirely in
        /// text keeps them all.
        mutating func keepLabels(within region: PixelBox, reach: Int) {
            guard var figure = mask.inkBounds(within: region, excluding: text) else { return }
            let wholePage = PixelBox(left: 0, top: 0, right: mask.width - 1, bottom: mask.height - 1)
            var pending = labels.compactMap { $0.intersection(region) }
            var grew = true
            while grew {
                grew = false
                pending.removeAll { label in
                    guard label.expanded(by: reach, within: wholePage).intersection(figure) != nil else { return false }
                    figure = figure.union(label)
                    grew = true
                    return true
                }
            }
            for label in pending { mask.erase(label) }
        }
    }

    /// Where the figure captioned at `anchor` is on its page, and the ink
    /// that is its own; nil when no figure lies beside the caption — a
    /// legend printed away from its figure, on a page that shows another.
    ///
    /// The band a figure is looked for in is not the half of the page on its
    /// side of the caption, where everything inked would be cropped in: the
    /// legend of the figure above it, the column of
    /// text beside it, the figures sharing its page. The text layer says what
    /// those are. A paragraph — two or more column-wide lines of written
    /// text, one under the other (`PageText.paragraphs`) — is never a figure:
    /// its ink comes off the page with a legend's grey box around it, and so
    /// do the folio, the running head and every other caption
    /// (`ErasedPage`). The region runs from the caption outward to the first
    /// paragraph or caption across the caption's width, where a figure above
    /// a caption starts; beside it the erased text leaves only the figure's
    /// own ink. Ink over another caption's column is that caption's figure,
    /// and a line of text still in the region is the figure's only when it
    /// reaches the figure (`labelReach`).
    ///
    /// The side is where that ink is. A caption narrow enough to stand beside
    /// its figure, with nothing drawn just above or below it in its own
    /// column and the figure's ink level with it, is set beside the figure,
    /// as the Biophysical Journal sets one. Otherwise the figure is above the
    /// caption when anything drawn is, as it is almost always, and below it
    /// when not, unless what is below stands over another caption.
    static func figureRegion(captionAnchor anchor: CGRect, on page: PDFPage, mask: PageInkMask) -> FigureRegion? {
        guard let text = PageText(page: page, mask: mask) else { return nil }
        return figureRegion(captionAnchor: anchor, text: text, mask: mask)
    }

    static func figureRegion(captionAnchor anchor: CGRect, text: PageText, mask: PageInkMask) -> FigureRegion? {
        func pixels(_ rect: CGRect) -> PixelBox? { PixelBox(pdfRect: rect, pageBounds: text.pageBounds, in: mask) }
        guard let anchorBox = pixels(anchor) else { return nil }
        // The caption's own paragraph, when it prints more than a line.
        let caption = text.paragraphs.map(\.bounds).compactMap(pixels)
            .first { $0.intersection(anchorBox).map { $0.height * 2 >= anchorBox.height } ?? false }
            .map { $0.union(anchorBox) } ?? anchorBox
        var page = ErasedPage(text, mask: mask, keeping: anchorBox)
        let gap = page.gap
        let span = caption.left...caption.right

        var sides: [(side: FigureSide, region: PixelBox)] = []
        // Beside: a narrow caption with its own column clear of drawn ink
        // just above and below it, and drawn ink level with it. A hairline
        // is no figure there: Nature rules one over and under a legend set
        // at the foot of a column, its figure down the column beside it.
        let clearance = Int(Double(mask.height) * Double(captionClearance))
        let inset = caption.width / 10
        let columnClear = page.mask.inkedRows(within: PixelBox(
            left: caption.left + inset, top: max(page.top, caption.top - clearance),
            right: caption.right - inset, bottom: caption.top - 1
        ), excluding: page.text) < gap && page.mask.inkedRows(within: PixelBox(
            left: caption.left + inset, top: caption.bottom + 1,
            right: caption.right - inset, bottom: min(mask.height - 1, caption.bottom + clearance)
        ), excluding: page.text) < gap
        if columnClear, Double(caption.width) <= Double(mask.width) * Double(sideCaptionMaximumWidthShare) {
            let rows = caption.top...caption.bottom
            for (side, left, right) in [
                (FigureSide.left, page.stop(leftOf: caption.left, over: rows), caption.left - gap),
                (FigureSide.right, caption.right + gap, page.stop(rightOf: caption.right, over: rows)),
            ] where Double(right - left) >= Double(mask.width) * 0.2
                && page.drawnInk(within: PixelBox(left: left, top: caption.top, right: right, bottom: caption.bottom)) > 0 {
                let region = PixelBox(
                    left: left,
                    top: page.stop(above: caption.top, across: left...right),
                    right: right,
                    bottom: page.stop(below: caption.bottom, across: left...right)
                )
                if region.isValid { sides.append((side, region)) }
            }
        }
        sides.append((.above, PixelBox(left: 0, top: page.stop(above: caption.top, across: span), right: mask.width - 1, bottom: caption.top - gap)))
        // Below, unless what is there stands over another caption: a figure
        // between two legends is the lower one's, set above it as figures
        // almost always are (Nature Communications prints a legend at the
        // top of the page after its figure, over the next figure).
        let belowBottom = page.stop(below: caption.bottom, across: span)
        let otherCaptionUnder = text.lines.contains { line in
            guard line.captionLabel != nil, let other = pixels(line.bounds), other.intersection(anchorBox) == nil else { return false }
            return other.top > belowBottom && other.top <= belowBottom + gap * 3 && other.crosses(span)
        }
        if !otherCaptionUnder {
            sides.append((.below, PixelBox(left: 0, top: caption.bottom + gap, right: mask.width - 1, bottom: belowBottom)))
        }

        guard var (side, region) = sides.first(where: { page.holdsFigure($0.region) }) else { return nil }

        // The region's ink is read in runs of columns split at white
        // gutters. A run standing over another caption's column is that
        // caption's figure — two figures side by side, each over its own
        // legend — a run set between two paragraphs of a column is the
        // running text's, an equation's rules or a table's, and a run that is
        // one hairline is the rule a journal sets under a legend (Nature
        // Aging). Each is left out.
        if side == .above || side == .below {
            var claimed: [PixelBox] = []
            for line in text.lines where line.captionLabel != nil {
                guard let other = pixels(line.bounds), other.intersection(anchorBox) == nil, !other.crosses(span) else { continue }
                let columns = other.left...other.right
                let claim = side == .above
                    ? PixelBox(left: other.left, top: page.stop(above: other.top, across: columns), right: other.right, bottom: other.top - 1)
                    : PixelBox(left: other.left, top: other.bottom + 1, right: other.right, bottom: page.stop(below: other.bottom, across: columns))
                if let inside = claim.intersection(region) { claimed.append(inside) }
            }
            let gutter = max(2, Int(Double(mask.width) * figureGutterShare))
            var kept: PixelBox?
            var dropped = false
            for run in page.mask.inkRuns(within: region, minimumGap: gutter) {
                let total = page.mask.inkCount(within: run)
                let taken = claimed.reduce(0) { $0 + ($1.intersection(run).map { page.mask.inkCount(within: $0) } ?? 0) }
                let ink = inkBounds(within: run, in: page.mask) ?? run
                if taken * 2 >= total {
                    // The claimed figure comes off. Two figures with no clean
                    // white column between them are one run (a bioRxiv
                    // page): what is left is read again in runs,
                    // and one that stands clear of every claim and is a
                    // figure stays; one that touches a claim is the claimed
                    // figure reaching past its caption's width.
                    dropped = true
                    for claim in claimed { if let inside = claim.intersection(run) { page.mask.erase(inside) } }
                    for piece in page.mask.inkRuns(within: run, minimumGap: gutter) {
                        let apart = claimed.allSatisfy { claim in
                            claim.intersection(run) == nil || piece.left > claim.right + gap || piece.right < claim.left - gap
                        }
                        if apart, page.holdsFigure(piece), let left = inkBounds(within: piece, in: page.mask) {
                            kept = kept.map { $0.union(left) } ?? left
                        } else {
                            page.mask.erase(piece)
                        }
                    }
                } else if ink.height * 250 <= mask.height || ink.width * 250 <= mask.width
                            || page.isInRunningText(ink, apartFrom: caption, within: clearance) {
                    // A hairline either way: a rule under a legend, or the one
                    // Nature runs down the margin beside a column of text,
                    // which stood a figure's crop out to the page's edge.
                    page.mask.erase(run)
                    dropped = true
                } else {
                    kept = kept.map { $0.union(run) } ?? run
                }
            }
            guard let kept else { return nil }
            if dropped {
                let margin = Int((Double(max(mask.width, mask.height)) * padding).rounded())
                region.left = max(region.left, kept.left - margin)
                region.right = min(region.right, kept.right + margin)
            }
        }

        page.keepLabels(within: region, reach: Int(Double(mask.height) * Double(labelReach)))
        guard page.holdsFigure(region) else { return nil }
        return FigureRegion(box: region, mask: page.mask, side: side)
    }

    /// Whether the figure a caption line on this page names stands beside
    /// it: its region holds one (`figureRegion`), or the line is no legend
    /// but a sentence of the running text that opens with a reference
    /// ("Supplementary Figure S3A …", a Leukemia paper), which
    /// says nothing of where the figure is and leaves it where it was.
    static func legendStandsBesideFigure(captionAnchor anchor: CGRect, text: PageText, mask: PageInkMask) -> Bool {
        if figureRegion(captionAnchor: anchor, text: text, mask: mask) != nil { return true }
        return text.paragraphs.contains { paragraph in
            !paragraph.isCaption && paragraph.lines.contains { line in
                let overlap = line.intersection(anchor)
                return !overlap.isNull && overlap.height * 2 >= anchor.height && overlap.width * 2 >= min(line.width, anchor.width)
            }
        }
    }

    /// A figure with no caption on its page (`uncaptionedFigureBand`),
    /// cleared of the text around it as a captioned one is; nil when the
    /// band holds no figure once that text is gone. The band runs on to the
    /// nearest paragraph above and below it: `proseFreeBand` counts a
    /// strip's characters, and a panel's rows of labels count as prose to
    /// it, so a bioRxiv figure lost its top two panels.
    static func figureRegion(band: CGRect, on page: PDFPage, mask: PageInkMask) -> FigureRegion? {
        guard let text = PageText(page: page, mask: mask),
              var region = PixelBox(pdfRect: band, pageBounds: text.pageBounds, in: mask) else { return nil }
        var erased = ErasedPage(text, mask: mask, keeping: nil)
        let width = 0...(mask.width - 1)
        region.top = min(region.top, erased.stop(above: region.top, across: width))
        region.bottom = max(region.bottom, erased.stop(below: region.bottom, across: width))
        erased.keepLabels(within: region, reach: Int(Double(mask.height) * Double(labelReach)))
        guard erased.holdsFigure(region) else { return nil }
        return FigureRegion(box: region, mask: erased.mask, side: nil)
    }

    // MARK: - Geometry

    fileprivate struct PixelBox {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int

        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        var isValid: Bool { left <= right && top <= bottom }

        init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        init(normalized rect: PaperFigureRect, in mask: PageInkMask) {
            let l = Int((rect.x * Double(mask.width)).rounded(.down))
            let t = Int((rect.y * Double(mask.height)).rounded(.down))
            let r = Int(((rect.x + rect.width) * Double(mask.width)).rounded(.up)) - 1
            let b = Int(((rect.y + rect.height) * Double(mask.height)).rounded(.up)) - 1
            left = max(0, min(l, mask.width - 1))
            top = max(0, min(t, mask.height - 1))
            right = max(left, min(r, mask.width - 1))
            bottom = max(top, min(b, mask.height - 1))
        }

        /// A rectangle in PDF page coordinates, which measure up from the
        /// bottom, put into the mask's frame, which measures down from the
        /// top. Nil when it covers no pixel.
        init?(pdfRect rect: CGRect, pageBounds: CGRect, in mask: PageInkMask) {
            guard pageBounds.width > 0, pageBounds.height > 0, rect.width > 0, rect.height > 0 else { return nil }
            let t = Int(((pageBounds.maxY - rect.maxY) / pageBounds.height * Double(mask.height)).rounded())
            let b = Int(((pageBounds.maxY - rect.minY) / pageBounds.height * Double(mask.height)).rounded()) - 1
            let l = Int(((rect.minX - pageBounds.minX) / pageBounds.width * Double(mask.width)).rounded())
            let r = Int(((rect.maxX - pageBounds.minX) / pageBounds.width * Double(mask.width)).rounded()) - 1
            left = max(0, min(l, mask.width - 1))
            top = max(0, min(t, mask.height - 1))
            right = min(r, mask.width - 1)
            bottom = min(b, mask.height - 1)
            guard isValid else { return nil }
        }

        func intersection(_ other: PixelBox) -> PixelBox? {
            let result = PixelBox(
                left: max(left, other.left),
                top: max(top, other.top),
                right: min(right, other.right),
                bottom: min(bottom, other.bottom)
            )
            return result.isValid ? result : nil
        }

        func union(_ other: PixelBox) -> PixelBox {
            PixelBox(left: min(left, other.left), top: min(top, other.top), right: max(right, other.right), bottom: max(bottom, other.bottom))
        }

        func contains(_ other: PixelBox) -> Bool {
            left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom
        }

        /// Overlaps the columns of `span` across at least half the narrower
        /// of the two: a paragraph over a caption, not beside it.
        func crosses(_ span: ClosedRange<Int>) -> Bool {
            let overlap = min(right, span.upperBound) - max(left, span.lowerBound) + 1
            return overlap > 0 && overlap * 2 >= min(width, span.count)
        }

        func expanded(by amount: Int, within bounds: PixelBox) -> PixelBox {
            PixelBox(
                left: max(bounds.left, left - amount),
                top: max(bounds.top, top - amount),
                right: min(bounds.right, right + amount),
                bottom: min(bounds.bottom, bottom + amount)
            )
        }

        /// The box in PDF page coordinates, on a page whose media box is
        /// `pageBounds`: `init(pdfRect:pageBounds:in:)` the other way.
        func pdfRect(in pageBounds: CGRect, mask: PageInkMask) -> CGRect {
            CGRect(
                x: pageBounds.minX + CGFloat(left) / CGFloat(mask.width) * pageBounds.width,
                y: pageBounds.maxY - CGFloat(bottom + 1) / CGFloat(mask.height) * pageBounds.height,
                width: CGFloat(width) / CGFloat(mask.width) * pageBounds.width,
                height: CGFloat(height) / CGFloat(mask.height) * pageBounds.height
            )
        }

        func normalized(in mask: PageInkMask) -> PaperFigureRect {
            PaperFigureRect(
                x: Double(left) / Double(mask.width),
                y: Double(top) / Double(mask.height),
                width: Double(width) / Double(mask.width),
                height: Double(height) / Double(mask.height)
            )
        }
    }

    /// `box` with each edge that lands on ink moved outward until it lands
    /// on white, inside `band`. `allows`, when given, is asked about each
    /// one-pixel strip before an edge takes it.
    private static func grown(
        _ box: PixelBox,
        boundedBy band: PixelBox,
        in mask: PageInkMask,
        allows: ((PixelBox) -> Bool)? = nil
    ) -> PixelBox {
        var result = box
        let verticalLimit = Int(Double(mask.height) * maximumGrowth)
        let horizontalLimit = Int(Double(mask.width) * maximumGrowth)
        func may(_ strip: PixelBox) -> Bool { allows?(strip) ?? true }

        var moved = 0
        while result.top > band.top, moved < verticalLimit,
              mask.rowHasInk(result.top, from: result.left, through: result.right),
              may(PixelBox(left: result.left, top: result.top - 1, right: result.right, bottom: result.top - 1)) {
            result.top -= 1
            moved += 1
        }
        moved = 0
        while result.bottom < band.bottom, moved < verticalLimit,
              mask.rowHasInk(result.bottom, from: result.left, through: result.right),
              may(PixelBox(left: result.left, top: result.bottom + 1, right: result.right, bottom: result.bottom + 1)) {
            result.bottom += 1
            moved += 1
        }
        // Horizontal growth uses the vertical span the rows just settled on, so
        // a figure widened at the top is measured against its real height.
        moved = 0
        while result.left > band.left, moved < horizontalLimit,
              mask.columnHasInk(result.left, from: result.top, through: result.bottom),
              may(PixelBox(left: result.left - 1, top: result.top, right: result.left - 1, bottom: result.bottom)) {
            result.left -= 1
            moved += 1
        }
        moved = 0
        while result.right < band.right, moved < horizontalLimit,
              mask.columnHasInk(result.right, from: result.top, through: result.bottom),
              may(PixelBox(left: result.right + 1, top: result.top, right: result.right + 1, bottom: result.bottom)) {
            result.right += 1
            moved += 1
        }
        return result
    }

    private static func inkBounds(within box: PixelBox, in mask: PageInkMask) -> PixelBox? {
        var top = box.top
        while top <= box.bottom, !mask.rowHasInk(top, from: box.left, through: box.right) { top += 1 }
        guard top <= box.bottom else { return nil }
        var bottom = box.bottom
        while bottom > top, !mask.rowHasInk(bottom, from: box.left, through: box.right) { bottom -= 1 }
        var left = box.left
        while left <= box.right, !mask.columnHasInk(left, from: top, through: bottom) { left += 1 }
        guard left <= box.right else { return nil }
        var right = box.right
        while right > left, !mask.columnHasInk(right, from: top, through: bottom) { right -= 1 }
        return PixelBox(left: left, top: top, right: right, bottom: bottom)
    }

    private static func padded(
        _ box: PixelBox,
        boundedBy band: PixelBox,
        in mask: PageInkMask
    ) -> PixelBox {
        let inset = Int((Double(max(mask.width, mask.height)) * padding).rounded())
        guard inset > 0 else { return box }
        return PixelBox(
            left: max(band.left, box.left - inset),
            top: max(band.top, box.top - inset),
            right: min(band.right, box.right + inset),
            bottom: min(band.bottom, box.bottom + inset)
        )
    }
}

extension PDFPage {
    /// Draws the page's media box with `region`, in page coordinates, at the
    /// context's origin; the whole box when `region` is nil. Every renderer
    /// of a page, or of a crop of one, draws through this, so the ink mask,
    /// the renders and the text boxes PDFKit reports share one frame.
    ///
    /// `draw(with: .mediaBox, to:)` already puts the box's own origin at the
    /// context's origin, so only the region's offset inside the box is
    /// translated away. Translating by the box's origin as well would
    /// displace a page whose box does not start at
    /// (0, 0): the JBC paper 10.1074/jbc.M809512200 starts at (9, 9), its
    /// text boxes would miss its ink by 9 points each way, and `pageInk` would
    /// read its prose pages as figures.
    func drawMediaBox(_ region: CGRect? = nil, to context: CGContext) {
        if let region {
            let box = bounds(for: .mediaBox)
            context.translateBy(x: box.minX - region.minX, y: box.minY - region.minY)
        }
        draw(with: .mediaBox, to: context)
    }
}

private extension PaperFigureRectRefiner.PageInkMask {
    /// `box` grown over the filled ink around it, as far as `limit`: the
    /// grey box a legend is set in. An edge moves out while the line of
    /// pixels beyond it is mostly ink, so the loose marks of a figure beside
    /// a column of text never draw the column into the figure.
    func filledSurround(of box: PaperFigureRectRefiner.PixelBox, limit: Int) -> PaperFigureRectRefiner.PixelBox {
        var result = box
        func filled(_ strip: PaperFigureRectRefiner.PixelBox) -> Bool {
            strip.isValid && inkCount(within: strip) * 2 >= strip.width * strip.height
        }
        var moved = 0
        while moved < limit, result.top > 0,
              filled(.init(left: result.left, top: result.top - 1, right: result.right, bottom: result.top - 1)) {
            result.top -= 1
            moved += 1
        }
        moved = 0
        while moved < limit, result.bottom < height - 1,
              filled(.init(left: result.left, top: result.bottom + 1, right: result.right, bottom: result.bottom + 1)) {
            result.bottom += 1
            moved += 1
        }
        moved = 0
        while moved < limit, result.left > 0,
              filled(.init(left: result.left - 1, top: result.top, right: result.left - 1, bottom: result.bottom)) {
            result.left -= 1
            moved += 1
        }
        moved = 0
        while moved < limit, result.right < width - 1,
              filled(.init(left: result.right + 1, top: result.top, right: result.right + 1, bottom: result.bottom)) {
            result.right += 1
            moved += 1
        }
        return result
    }

    /// Takes the pixels of `box` off the page.
    mutating func erase(_ box: PaperFigureRectRefiner.PixelBox) {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right else { return }
        for row in top...bottom {
            let offset = row * width
            for column in left...right {
                dark[offset + column] = false
                strong[offset + column] = false
            }
        }
    }

    /// The pixels in `box` darker than `strongInkThreshold` that `excluded`
    /// does not mark.
    func strongInkCount(within box: PaperFigureRectRefiner.PixelBox, excluding excluded: [Bool]) -> Int {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right, excluded.count == strong.count else { return 0 }
        var count = 0
        for row in top...bottom {
            let offset = row * width
            for column in left...right where strong[offset + column] && !excluded[offset + column] {
                count += 1
            }
        }
        return count
    }

    /// The box around the ink in `box` that `excluded` does not mark; nil
    /// when there is none.
    func inkBounds(within box: PaperFigureRectRefiner.PixelBox, excluding excluded: [Bool]) -> PaperFigureRectRefiner.PixelBox? {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right, excluded.count == dark.count else { return nil }
        var result: PaperFigureRectRefiner.PixelBox?
        for row in top...bottom {
            let offset = row * width
            for column in left...right where dark[offset + column] && !excluded[offset + column] {
                if var found = result {
                    found.left = min(found.left, column)
                    found.right = max(found.right, column)
                    found.bottom = row
                    result = found
                } else {
                    result = PaperFigureRectRefiner.PixelBox(left: column, top: row, right: column, bottom: row)
                }
            }
        }
        return result
    }

    /// How many rows of `box` carry ink that `excluded` does not mark.
    func inkedRows(within box: PaperFigureRectRefiner.PixelBox, excluding excluded: [Bool]) -> Int {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right, excluded.count == dark.count else { return 0 }
        var rows = 0
        for row in top...bottom {
            let offset = row * width
            if (left...right).contains(where: { dark[offset + $0] && !excluded[offset + $0] }) { rows += 1 }
        }
        return rows
    }

    /// The runs of inked columns in `box`, split where at least `minimumGap`
    /// columns in a row are blank, each as tall as `box`.
    func inkRuns(within box: PaperFigureRectRefiner.PixelBox, minimumGap: Int) -> [PaperFigureRectRefiner.PixelBox] {
        guard box.isValid else { return [] }
        var runs: [PaperFigureRectRefiner.PixelBox] = []
        var start: Int?
        var lastInked = box.left
        for column in box.left...box.right where columnHasInk(column, from: box.top, through: box.bottom) {
            if let open = start, column - lastInked - 1 >= minimumGap {
                runs.append(.init(left: open, top: box.top, right: lastInked, bottom: box.bottom))
                start = column
            } else if start == nil {
                start = column
            }
            lastInked = column
        }
        if let open = start { runs.append(.init(left: open, top: box.top, right: lastInked, bottom: box.bottom)) }
        return runs
    }

    func inkCount(within box: PaperFigureRectRefiner.PixelBox) -> Int {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right else { return 0 }
        var count = 0
        for row in top...bottom {
            let offset = row * width
            for column in left...right where dark[offset + column] {
                count += 1
            }
        }
        return count
    }

    /// `inkCount(within:)` less the pixels `excluded` marks, a flag a pixel.
    func inkCount(within box: PaperFigureRectRefiner.PixelBox, excluding excluded: [Bool]) -> Int {
        let top = max(0, box.top), bottom = min(height - 1, box.bottom)
        let left = max(0, box.left), right = min(width - 1, box.right)
        guard top <= bottom, left <= right, excluded.count == dark.count else { return 0 }
        var count = 0
        for row in top...bottom {
            let offset = row * width
            for column in left...right where dark[offset + column] && !excluded[offset + column] {
                count += 1
            }
        }
        return count
    }

    func rowHasInk(_ row: Int, from first: Int, through last: Int) -> Bool {
        guard row >= 0, row < height, first <= last else { return false }
        let start = row * width + max(0, first)
        let end = row * width + min(width - 1, last)
        guard start <= end else { return false }
        var count = 0
        for index in start...end where dark[index] { count += 1 }
        return Double(count) / Double(end - start + 1) > PaperFigureRectRefiner.blankFraction
    }

    /// `rowHasInk(_:from:through:)` with the columns of `bands` left out.
    func rowHasInk(_ row: Int, from first: Int, through last: Int, apartFrom bands: [PaperFigureRectRefiner.PixelBox]) -> Bool {
        var start = max(0, first)
        for band in bands.sorted(by: { $0.left < $1.left }) where band.right >= start && band.left <= last {
            if band.left > start, rowHasInk(row, from: start, through: band.left - 1) { return true }
            start = max(start, band.right + 1)
        }
        return start <= last && rowHasInk(row, from: start, through: last)
    }

    func isInked(row: Int, column: Int) -> Bool {
        row >= 0 && row < height && column >= 0 && column < width && dark[row * width + column]
    }

    func columnHasInk(_ column: Int, from first: Int, through last: Int) -> Bool {
        guard column >= 0, column < width, first <= last else { return false }
        let top = max(0, first)
        let bottom = min(height - 1, last)
        guard top <= bottom else { return false }
        var count = 0
        for row in top...bottom where dark[row * width + column] { count += 1 }
        return Double(count) / Double(bottom - top + 1) > PaperFigureRectRefiner.blankFraction
    }
}
#endif
