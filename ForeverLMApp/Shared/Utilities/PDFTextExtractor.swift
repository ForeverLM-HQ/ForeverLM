import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
#if os(macOS)
import AppKit
import CoreText
import Vision
#endif

private let pdfTextLogger = Logger(subsystem: "com.foreverlm", category: "PDFTextExtractor")

/// A deterministic figure-to-page observation from one PDF. Identity remains a
/// storage concern because it also includes the owning source ID; the extractor
/// reports only structure visible in the PDF itself.
///
/// There is deliberately no image path here. A figure's pixels are already in
/// the PDF, so every client renders the page on demand from `pageIndex` rather
/// than reading a second copy off disk.
struct PDFIndexedFigure: Equatable, Sendable {
    let figureLabel: String
    let pageIndex: Int
    let caption: String
}

enum PDFTextExtractor {
    static let minimumEmbeddedWordsBeforeOCR = 25

    #if canImport(PDFKit)
    static func text(
        from document: PDFDocument,
        pages pageRange: Range<Int>,
        progress: ((Int, Int) -> Void)? = nil
    ) -> String {
        let embedded = embeddedText(from: document, pages: pageRange)
        let recognized = shouldOCR(embedded) ? ocrText(from: document, pages: pageRange, progress: progress) : embedded
        return recognized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func embeddedText(from document: PDFDocument, pages pageRange: Range<Int>) -> String {
        let upperBound = min(pageRange.upperBound, document.pageCount)
        guard pageRange.lowerBound < upperBound else { return "" }
        var text = ""
        for pageIndex in pageRange.lowerBound..<upperBound {
            guard let pageText = document.page(at: pageIndex)?.string else { continue }
            // Preserve page boundaries so the canonical cleanup can identify
            // repeated headers, footers, and page numbers before reflowing.
            if !text.isEmpty { text += "\u{000C}" }
            text += canonicalPageText(pageText)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    /// A page's text as the source keeps it: an unmapped glyph marked
    /// (`markingUnmappedGlyphs`), and the soft hyphens a publisher's typesetter
    /// left — after a hyphen at a line end, inside a word where it could break —
    /// dropped, since they are no part of a word (`removingSoftHyphens()`). The
    /// page itself keeps them; the readers' anchors look past them
    /// (`ReaderTextAnchor.normalize`).
    static func canonicalPageText(_ pageText: String) -> String {
        markingUnmappedGlyphs(pageText).removingSoftHyphens()
    }

    /// PDFKit returns U+0000 for a glyph the PDF gives no Unicode for — in the
    /// papers that exposed it, minus signs ("t=−43.49") and "fi"/"ffi"
    /// ligatures ("scientific"). The character is unknown, not absent, so it
    /// becomes U+FFFD, the replacement character: dropping it would turn a
    /// negative statistic positive without a trace, and a NUL is not text any
    /// consumer — SQLite, a prompt, a reader — handles as such.
    static func markingUnmappedGlyphs(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0 }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            scalars.append(scalar.value == 0 ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }

    #if canImport(PDFKit)
    static func textWithFigureReferences(
        from document: PDFDocument,
        pages pageRange: Range<Int>,
        progress: ((Int, Int) -> Void)? = nil
    ) -> String {
        let text = text(from: document, pages: pageRange, progress: progress)
        #if os(macOS)
        let figureMarkdown = figurePageMarkdown(from: document, pages: pageRange)
        guard !figureMarkdown.isEmpty else { return text }
        guard !text.isEmpty else { return figureMarkdown }
        return text + "\n\n" + figureMarkdown
        #else
        return text
        #endif
    }
    #endif

    static func shouldOCR(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count < minimumEmbeddedWordsBeforeOCR
    }

    #if canImport(PDFKit)
    private static func ocrText(
        from document: PDFDocument,
        pages pageRange: Range<Int>,
        progress: ((Int, Int) -> Void)?
    ) -> String {
        #if os(macOS)
        let upperBound = min(pageRange.upperBound, document.pageCount)
        guard pageRange.lowerBound < upperBound else { return "" }
        let totalPages = upperBound - pageRange.lowerBound
        var pages: [String] = []

        for (offset, pageIndex) in (pageRange.lowerBound..<upperBound).enumerated() {
            progress?(offset + 1, totalPages)
            guard let page = document.page(at: pageIndex),
                  let image = renderedImage(for: page),
                  let pageText = recognizedText(in: image),
                  !pageText.isEmpty else { continue }
            pages.append(pageText)
        }

        return pages.joined(separator: "\n\n")
        #else
        return ""
        #endif
    }

    #if os(macOS)
    /// How many pages either side of its legend a figure is looked for when
    /// the legend's own page shows no figure.
    static let figurePageReach = 3

    /// Locate structurally labelled figures and the page each one sits on:
    /// one figure a label, on the page that shows it, carrying its caption's
    /// words.
    ///
    /// Structure, and nothing is written to disk. A figure's image already
    /// exists inside the PDF, and rendering a second JPEG copy of the page
    /// beside it bought nothing that `pageIndex` does not buy — while costing
    /// gigabytes and, because the rendered path was absolute, breaking the
    /// moment the library reached another machine. Callers that need pixels
    /// ask `pageJPEGData(from:pageIndex:)` for them at the moment of use.
    ///
    /// A caption is not always printed on its figure's page, and its words
    /// can be pages away (product owner, 2026-09-28: "the figure text box sometimes
    /// can live on a different page than the figure … sometimes it can even
    /// live a few pages away"). The page is read, most plainly said first:
    ///
    /// - *The label printed alone.* EMBO sets a legend on the page before or
    ///   after its figure and prints only "Figure 1." under the figure;
    ///   Nature prints "Fig. 3 | See next page for caption."
    ///   (`PaperFigureCaptionTitle.isStub`). The figure is on that page,
    ///   wherever its words are. Indexed to its legend's page, Figure 1 of
    ///   the EMBO cristae paper was a page of prose on a walkthrough card.
    /// - *A legend on a page that shows a figure*
    ///   (`PaperFigureRectRefiner.showsFigure`) is that figure's, whether
    ///   the figure stands above, below or beside it — when a figure stands
    ///   there at all (`PaperFigureRectRefiner.figureRegion`). JBC sets a
    ///   legend at the foot of the page after its figure, under the next
    ///   figure and its legend; one with nothing drawn beside it is a legend
    ///   on a page that shows none.
    /// - *A legend on a page that shows none.* Its figure is a page within
    ///   `figurePageReach` that a figure fills (`PageInk.isFigurePage`) and
    ///   that prints no caption, never the title page, legends and such
    ///   pages paired in order
    ///   (`FigurePlacement.pairedInOrder`), so two full-page figures followed
    ///   by a page of both legends each keep their own page — Cell's figure
    ///   page with its legend overleaf is one. Two or more left over in runs
    ///   of legends are a legends section, a preprint's, and are paired
    ///   forward with the figure pages after them however far on, never past
    ///   a page another figure holds. Failing that, a legend
    ///   opening its page under the running head belongs to a figure that
    ///   filled the page before, as Nature sets one: indexed to the caption's
    ///   page, Fig. 6 of the cardiac-sodium paper cropped to the
    ///   running head. Otherwise it stays on its page.
    ///
    /// Pixels are read for a legend's page, and for the caption-free pages
    /// near a legend whose page shows no figure, each once.
    static func indexedFigures(
        from document: PDFDocument,
        pages pageRange: Range<Int>
    ) -> [PDFIndexedFigure] {
        let upperBound = min(pageRange.upperBound, document.pageCount)
        guard pageRange.lowerBound < upperBound else { return [] }
        var placement = FigurePlacement(document: document, pages: pageRange.lowerBound..<upperBound)
        return placement.figures()
    }

    /// Render one page to JPEG bytes in memory, for a vision model or a view
    /// that is about to show it. Nothing is cached to disk: the PDF is the
    /// cache, and a render costs far less than the storage a copy would take.
    static func pageJPEGData(
        from document: PDFDocument,
        pageIndex: Int,
        maxDimension: CGFloat = 1_800,
        compressionQuality: Double = 0.82
    ) -> Data? {
        guard let page = document.page(at: pageIndex),
              let image = renderedPageImage(for: page, maxDimension: maxDimension),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    /// Render one page to JPEG bytes with a faint measurement grid ruled over
    /// it, for a vision model that has to say *where* on the page something is.
    ///
    /// Asked to place a figure on an unmarked page, a model estimates, and the
    /// estimates are poor in a recognisable way: they land on round numbers and
    /// repeat across unrelated figures, because a generic "content block" is the
    /// best guess available when there is nothing to measure against. Ruling the
    /// page turns the estimate into a reading.
    ///
    /// The grid is the reader's overlay and never the paper's, so it is drawn to
    /// be dismissable: a violet no journal uses for data, thin enough to read
    /// the page through, and numbered only along the top and left edges. The
    /// prompt says the same thing in words, because a model that mistook a
    /// gridline for a trend line would be worse than no grid at all.
    static func measuredPageJPEGData(
        from document: PDFDocument,
        pageIndex: Int,
        maxDimension: CGFloat = 1_800,
        compressionQuality: Double = 0.82
    ) -> Data? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(maxDimension / max(box.width, box.height), 3.0)
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.drawMediaBox(to: context)
        context.restoreGState()
        drawMeasurementGrid(in: context, width: CGFloat(width), height: CGFloat(height))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    /// Violet at two weights: every 0.05 faint, every 0.1 readable and numbered.
    /// Coordinates are normalized with a top-left origin, the frame
    /// `PaperFigureRect` uses, so what the model reads off the page is already
    /// in the units the answer is stored in.
    private static func drawMeasurementGrid(in context: CGContext, width: CGFloat, height: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setLineWidth(max(1, width / 1_000))

        for (step, alpha) in [(0.05, 0.14), (0.10, 0.32)] {
            context.setStrokeColor(red: 0.42, green: 0.16, blue: 0.92, alpha: alpha)
            var fraction = step
            while fraction < 0.999 {
                // A 0.05 line that is also a 0.1 line is drawn once, at the
                // heavier weight, by the second pass.
                let isMajor = (fraction * 100).rounded().truncatingRemainder(dividingBy: 10) == 0
                if step < 0.1 && isMajor {
                    fraction += step
                    continue
                }
                let x = CGFloat(fraction) * width
                let y = height - CGFloat(fraction) * height
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
                fraction += step
            }
            context.strokePath()
        }

        let labelSize = max(9, width / 62)
        var fraction = 0.1
        while fraction < 0.999 {
            let text = String(format: "%.1f", fraction)
            // x along the top edge, y down the left edge: both read from the
            // top-left corner, which is where 0,0 is.
            drawGridLabel(
                text,
                at: CGPoint(x: CGFloat(fraction) * width + labelSize * 0.2, y: height - labelSize * 1.15),
                size: labelSize,
                in: context
            )
            drawGridLabel(
                text,
                at: CGPoint(x: labelSize * 0.2, y: height - CGFloat(fraction) * height + labelSize * 0.25),
                size: labelSize,
                in: context
            )
            fraction += 0.1
        }
    }

    private static func drawGridLabel(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 0.36, green: 0.10, blue: 0.86, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // A chip behind the number, so it stays readable over a dark panel.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.88)
        context.fill(CGRect(
            x: point.x - size * 0.15,
            y: point.y - descent - size * 0.1,
            width: textWidth + size * 0.3,
            height: ascent + descent + size * 0.2
        ))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A compact, portable figure index appended to canonical text.
    ///
    /// It is not a list of `![caption](file:///…)` links pointing at rendered
    /// page JPEGs: those absolute paths name one Mac's home directory, so they
    /// are dead on a second machine and meaningless to a model reading the
    /// text. A label and a page number travel everywhere and are all
    /// any client needs to render the figure from the PDF itself. Captions are
    /// not repeated here — they are already in the extracted page text above.
    private static func figurePageMarkdown(
        from document: PDFDocument,
        pages pageRange: Range<Int>
    ) -> String {
        let figures = indexedFigures(from: document, pages: pageRange)
        guard !figures.isEmpty else { return "" }

        var seen = Set<String>()
        var lines: [String] = []
        for figure in figures {
            let key = "\(figure.figureLabel.lowercased())\u{1F}\(figure.pageIndex)"
            guard seen.insert(key).inserted else { continue }
            lines.append("- \(figure.figureLabel) — page \(figure.pageIndex + 1)")
        }

        guard !lines.isEmpty else { return "" }
        return "## Figures\n\n" + lines.joined(separator: "\n")
    }

    /// A caption is a paragraph, and the page's text breaks it into lines
    /// wherever the layout did. A caption taken as the line its label opened
    /// would title Fig. 1 of the cardiac-sodium paper was titled
    /// "Intracellular Na elevation and contractility in isolated Langendorff"
    /// — the title's first printed line, cut where the column wrapped
    /// (the product owner: "this is not the full title actually"). With only the text
    /// to go on, the caption is extended line by line until its title
    /// sentence closes; `figureCaptionRecords(on:)` reads the page's fonts
    /// and takes the whole paragraph.
    static func figureCaptionRecords(in text: String) -> [(label: String, caption: String)] {
        figureCaptionRecords(lines: nonEmptyLines(text).map { CaptionLine(text: $0) })
    }

    /// The caption paragraph as printed: the label's line and every line
    /// after it set in the same font size, up to the next caption, a change
    /// of size (the body text that follows a caption is set larger), a
    /// paragraph gap wider than the caption's own line pitch, or a folio.
    /// Lines are joined with newlines, so the stored caption is a literal
    /// substring of `page.string` and `PaperFigureRectRefiner.captionBounds`
    /// still finds its first line on the page; readers collapse the breaks
    /// (`PaperFigureCaptionTitle.collapsed`).
    static func figureCaptionRecords(on page: PDFPage) -> [(label: String, caption: String)] {
        figureCaptions(on: page).map { ($0.label, $0.caption) }
    }

    /// The page's captions as `figureCaptionRecords(on:)` reads them, each
    /// saying whether its label opened a line of the running text.
    static func figureCaptions(on page: PDFPage) -> [FigureCaption] {
        figureCaptions(lines: captionLines(on: page) ?? nonEmptyLines(page.string ?? "").map { CaptionLine(text: $0) })
    }

    /// One caption as the page's text prints it.
    struct FigureCaption {
        let label: String
        let caption: String
        /// The line its label opens carries on the sentence above it: running
        /// text that begins with a reference to the figure, not its legend
        /// (`continuesRunningText`).
        let isRunningText: Bool
    }

    /// One non-empty line of a page's text with what is known of its type.
    struct CaptionLine {
        var text: String
        /// The dominant font size on the line, when the page's fonts were read.
        var pointSize: Double? = nil
        /// The line's box on the page, when measured: its first printed
        /// piece, which for a label set in a face of its own is the label.
        var bounds: CGRect? = nil
        /// The box of every piece printed on the line's row, the label and
        /// the words after it.
        var rowBounds: CGRect? = nil
    }

    /// Where a caption stops being read when nothing else stops it. Long
    /// enough for a Nature legend with eight panels; short enough that a
    /// caption set in the body's own face cannot swallow the page.
    static let maximumCaptionCharacters = 2_400
    static let maximumCaptionLines = 40

    static func figureCaptionRecords(lines: [CaptionLine]) -> [(label: String, caption: String)] {
        figureCaptions(lines: lines).map { ($0.label, $0.caption) }
    }

    static func figureCaptions(lines: [CaptionLine]) -> [FigureCaption] {
        var records: [FigureCaption] = []
        var index = 0
        while index < lines.count {
            guard let label = PaperFigureCaptionTitle.label(openingLine: lines[index].text),
                  let start = PaperFigureCaptionTitle.captionStart(in: lines[index].text) else {
                index += 1
                continue
            }
            let opening = lines[index]
            // From the label on, past any arrow set before it: still a
            // literal piece of the page's text.
            var caption = String(opening.text[start...])
            var previous = opening
            var pitch: CGFloat? = nil
            var next = index + 1
            while next < lines.count, next - index < maximumCaptionLines {
                let line = lines[next]
                guard PaperFigureCaptionTitle.label(openingLine: line.text) == nil,
                      caption.count + line.text.count + 1 <= maximumCaptionCharacters,
                      continuesCaption(line, after: previous, opening: opening, caption: caption, pitch: &pitch)
                else { break }
                caption += "\n" + line.text
                previous = line
                next += 1
            }
            // An entry in a list of figures names a figure and prints no legend.
            if !PaperFigureCaptionTitle.isContentsEntry(caption) {
                records.append(FigureCaption(
                    label: label,
                    caption: caption,
                    isRunningText: index > 0 && continuesRunningText(opening, after: lines[index - 1])
                ))
            }
            index = next
        }
        return records
    }

    /// Whether a line that opens with a figure's label carries on the
    /// running text above it instead of opening a caption: the line before
    /// it is set in the same size, directly above it at the text's own
    /// pitch, across at least its measure, and breaks off mid-sentence.
    /// Page 6 of the Biophysical Journal's "How and when to measure
    /// mitochondrial inner membrane potentials" reads "… as exemplified in"
    /// / "Fig. 5. The measured fluorescence both inside and outside", and
    /// that sentence would be Figure 5's title; its legend,
    /// "FIGURE 5 Potential pitfalls…", is printed lower on the page.
    /// `PaperFigureRectRefiner.PageText.paragraphs` reads the line the same
    /// way, as a reference in the text. Only a page's measured lines can say
    /// so: text alone never does.
    ///
    /// The line is measured across its whole row: a legend's label set in a
    /// face of its own is a piece of the line by itself, and a Molecular
    /// Neurodegeneration legend, "Fig. 3 Domain structure of tau…" under
    /// "(See figure on next page.)", read as running text against its bold
    /// label alone. A sentence closes before its brackets and quotes. The
    /// line above is a line of text, one line tall: PDFKit reads an embedded
    /// picture as a line of its own, U+FFFC as large as the picture and in
    /// the body's size, and a bioRxiv legend under its figure read as the
    /// picture's sentence carried on.
    private static func continuesRunningText(_ line: CaptionLine, after previous: CaptionLine) -> Bool {
        guard let size = line.pointSize, let previousSize = previous.pointSize, abs(size - previousSize) < 0.2,
              let bounds = line.rowBounds ?? line.bounds, let above = previous.rowBounds ?? previous.bounds,
              previous.text.rangeOfCharacter(from: .letters) != nil,
              above.height <= bounds.height * 1.5, bounds.height <= above.height * 1.5,
              let last = previous.text.last(where: { !")]}\"'\u{201D}\u{2019}".contains($0) }),
              !".!?:".contains(last) else { return false }
        return above.width >= bounds.width * 0.9 && PaperFigureRectRefiner.PageText.continues(bounds, under: above)
    }

    /// Whether `line` is still the caption that `opening` began.
    private static func continuesCaption(
        _ line: CaptionLine,
        after previous: CaptionLine,
        opening: CaptionLine,
        caption: String,
        pitch: inout CGFloat?
    ) -> Bool {
        // A folio or a lone number is never caption, and a line that opens
        // with the tail of a figure reference ("Fig. 2). We observed…") is
        // prose that broke across lines, not the caption carrying on.
        guard line.text.count >= 3, line.text.rangeOfCharacter(from: .letters) != nil,
              !opensWithFigureReference(line.text) else { return false }
        guard let size = line.pointSize, let openingSize = opening.pointSize else {
            // Text alone: the caption runs on only until its title sentence
            // has closed, which is the part a reader shows.
            return PaperFigureCaptionTitle.sentenceEnd(in: caption) == nil
        }
        guard abs(size - openingSize) < 0.2 else { return false }
        // Same face: a paragraph break shows as a gap wider than the caption's
        // line pitch, measured from its own first two lines. A jump up the
        // page is the next column, which the caption may well run into.
        if let bounds = line.bounds, let last = previous.bounds {
            let gap = last.minY - bounds.minY
            if gap > 0 {
                if let pitch {
                    if gap > pitch * 1.8 { return false }
                } else {
                    pitch = gap
                    if gap > max(last.height, bounds.height) * 2.2 { return false }
                }
            }
        }
        return true
    }

    /// "Fig. 2) offers…", "Figure 3e–h), and…": a line that begins with a
    /// figure's name and is not a caption is a reference the layout broke.
    private static func opensWithFigureReference(_ line: String) -> Bool {
        guard let regex = figureReferenceOpeningRegex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static let figureReferenceOpeningRegex = try? NSRegularExpression(
        pattern: #"^(?:(?:Extended\s+Data|Supplementary(?:\s+Data)?|Supplemental|Supp\.|Appendix)\s+)?(?:Figure|Fig\.?)\s+[A-Za-z]?\d+"#,
        options: [.caseInsensitive]
    )

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    #if canImport(AppKit)
    /// The page's lines with their dominant font size and box, from PDFKit's
    /// attributed string — the same text as `page.string`, with fonts.
    private static func captionLines(on page: PDFPage) -> [CaptionLine]? {
        guard let attributed = page.attributedString else { return nil }
        let text = attributed.string as NSString
        guard text.length > 0 else { return [] }
        var lines: [CaptionLine] = []
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let line = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var sizes: [Double: Int] = [:]
            attributed.enumerateAttribute(.font, in: range) { value, fontRange, _ in
                guard let font = value as? NSFont else { return }
                sizes[(font.pointSize * 10).rounded() / 10, default: 0] += fontRange.length
            }
            let size = sizes.max { $0.value < $1.value }?.key
            let printed = page.selection(for: range)?.selectionsByLine() ?? []
            // The page's text can run two printed lines into one: a
            // watermark set across the page and the label printed under
            // it, "ACCELERATED ARTICLE PREVIEWExtended Data Fig. 1" (a
            // Nature accelerated preview). A line that opens no
            // caption is read again as the lines PDFKit lays it out in,
            // when one of those opens one.
            if printed.count > 1, PaperFigureCaptionTitle.label(openingLine: line) == nil,
               printed.contains(where: { opensCaption($0) }) {
                for piece in printed {
                    guard let text = piece.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                    let box = piece.bounds(for: page)
                    let measured = box.width > 0 && box.height > 0 ? box : nil
                    lines.append(CaptionLine(
                        text: text,
                        pointSize: pointSize(of: piece) ?? size,
                        bounds: measured,
                        rowBounds: measured
                    ))
                }
                continue
            }
            var bounds: CGRect? = nil
            var row: CGRect? = nil
            if let first = printed.first {
                let box = first.bounds(for: page)
                if box.width > 0, box.height > 0 {
                    bounds = box
                    row = printed.map { $0.bounds(for: page) }.filter { piece in
                        piece.width > 0 && piece.height > 0
                            && min(piece.maxY, box.maxY) - max(piece.minY, box.minY) >= min(piece.height, box.height) / 2
                    }.reduce(box) { $0.union($1) }
                }
            }
            lines.append(CaptionLine(text: line, pointSize: size, bounds: bounds, rowBounds: row))
        }
        return lines
    }

    /// Whether a printed line opens a caption, past any marks before it.
    private static func opensCaption(_ line: PDFSelection) -> Bool {
        guard let text = line.string, let start = PaperFigureCaptionTitle.captionStart(in: text) else { return false }
        return PaperFigureCaptionTitle.label(openingLine: String(text[start...])) != nil
    }

    /// The font size most of a printed line is set in.
    private static func pointSize(of line: PDFSelection) -> Double? {
        guard let attributed = line.attributedString, attributed.length > 0 else { return nil }
        var sizes: [Double: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizes[(font.pointSize * 10).rounded() / 10, default: 0] += range.length
        }
        return sizes.max { $0.value < $1.value }?.key
    }
    #else
    private static func captionLines(on page: PDFPage) -> [CaptionLine]? { nil }
    #endif

    /// A page drawn at up to 2,400 pixels on its long side, as OCR reads it.
    static func renderedImage(for page: PDFPage) -> CGImage? {
        guard let image = renderedPageImage(for: page, maxDimension: 2_400) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func renderedPageImage(for page: PDFPage, maxDimension: CGFloat) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxDimension / max(bounds.width, bounds.height), 3.0)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    private static func recognizedText(in image: CGImage) -> String? {
        let request = textRecognitionRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            pdfTextLogger.error("OCR failed: \(error.localizedDescription)")
            return nil
        }

        let lines = request.results?.compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
        return lines.joined(separator: "\n")
    }

    /// The one way ForeverLM reads a page's pixels: a paper's or a notebook
    /// file's text here, and a scanned book's lines in `ScannedPDFTextLayer`.
    static func textRecognitionRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision reads the page's own script instead of being told one, and this
        // is the only place that can happen: OCR runs only when the PDF carries
        // under `minimumEmbeddedWordsBeforeOCR` words of embedded text, so there
        // is no text to sample a language from beforehand. The pixels are the
        // first evidence of the language, and they arrive here.
        //
        // Measured on rendered pages. A hardcoded `["en-US"]` reads
        // Latin and Cyrillic correctly — Dutch survives blur and downscaling to
        // 85% word accuracy with byte-identical output either way — so a
        // language list buys nothing there. It returns an *empty string* for
        // Japanese and Chinese, which need a different model to resolve glyphs
        // at all. Detection fixes that case without guessing from the reader's
        // locale, which is the wrong signal anyway: this app's whole premise is
        // a reader whose own language differs from their sources'.
        request.automaticallyDetectsLanguage = true
        return request
    }
    #endif
    #endif
}

/// The page boundaries a PDF source's stored text keeps as form feeds
/// (`PDFTextExtractor.embeddedText`), made legible to a model as `[page N]`
/// lines — one-based, counted within the source's own pages — so a citation can
/// carry the page a passage sits on (`foreverlm://source/<id>?page=N`) and the
/// reader can open it even when the excerpt is not found. Applied to the text
/// handed to the model, never to the stored text: the stored text's hash is the
/// revision other tools bind to, and the readers search the pages themselves.
/// Text without a form feed — a web article, a transcript, a PDF extracted
/// before boundaries were kept — is returned untouched.
enum PDFPageMarkers {
    static let formFeed: Character = "\u{000C}"

    static func labeled(_ text: String) -> String {
        guard text.contains(formFeed) else { return text }
        let pages = text.split(separator: formFeed, omittingEmptySubsequences: false)
        var labeled = ""
        for (index, page) in pages.enumerated() {
            let body = page.trimmingCharacters(in: .whitespacesAndNewlines)
            if index > 0 { labeled += "\n\n" }
            labeled += "[page \(index + 1)]"
            if !body.isEmpty { labeled += "\n\n" + body }
        }
        return labeled
    }
}

#if os(macOS)
/// The pass behind `PDFTextExtractor.indexedFigures`: every caption line in
/// the pages, then the page each labelled figure is shown on. A page is
/// rendered only to ask whether it shows a figure, and at most once.
private struct FigurePlacement {
    /// One caption line as printed.
    struct Caption {
        let label: String
        let caption: String
        let pageIndex: Int
        /// Its place among the captions printed on its page.
        let position: Int
        /// A sentence of the running text that opens with the label
        /// (`PDFTextExtractor.FigureCaption.isRunningText`).
        let isRunningText: Bool
    }

    /// A legend whose page shows no figure, to be paired with a page that does.
    struct Legend {
        let pageIndex: Int
        /// Printed in the upper half of its page: a legend there points back
        /// to a figure before it, one lower down to a figure after it.
        let pointsBack: Bool
    }

    let document: PDFDocument
    let pages: Range<Int>
    private var masks: [Int: PaperFigureRectRefiner.PageInkMask] = [:]
    private var inks: [Int: PaperFigureRectRefiner.PageInk?] = [:]

    init(document: PDFDocument, pages: Range<Int>) {
        self.document = document
        self.pages = pages
    }

    mutating func figures() -> [PDFIndexedFigure] {
        // Every caption line, a label's in page order. One figure comes out
        // of a label however often it is printed — a caption re-begun after a
        // broken line, a "Fig. 3 | continued", a bioRxiv page headed "Figure
        // 2" over the legend "Figure 2 – ATP synthesis…" — so a repeat on one
        // page needs no dropping (which would keep the heading and lose the
        // words).
        var labels: [String] = []
        var printed: [String: [Caption]] = [:]
        for pageIndex in pages {
            guard let page = document.page(at: pageIndex) else { continue }
            for (position, record) in PDFTextExtractor.figureCaptions(on: page).enumerated() {
                let key = record.label.lowercased()
                if printed[key] == nil { labels.append(key) }
                printed[key, default: []].append(Caption(
                    label: record.label,
                    caption: record.caption,
                    pageIndex: pageIndex,
                    position: position,
                    isRunningText: record.isRunningText
                ))
            }
        }
        // The words: the first legend that carries them. A sentence of the
        // running text that opens with the label lends it words only when no
        // legend is printed: the Biophysical Journal's "… as exemplified in /
        // Fig. 5. The measured fluorescence…" came before Figure 5's legend
        // on its page, and titled the figure.
        let words: [String: Caption] = printed.compactMapValues { lines in
            lines.first { !$0.isRunningText && !PaperFigureCaptionTitle.isStub($0.caption) }
                ?? lines.first { !PaperFigureCaptionTitle.isStub($0.caption) }
                ?? lines.first
        }
        let captionPages = Set(printed.values.joined().map(\.pageIndex))

        // A label printed alone is printed with its figure.
        var figurePage: [String: Int] = [:]
        for key in labels {
            if let stub = printed[key]?.first(where: { PaperFigureCaptionTitle.isStub($0.caption) }) {
                figurePage[key] = stub.pageIndex
            }
        }
        // A legend on a page that shows a figure is that figure's — beside
        // it, as the Biophysical Journal sets one, as well as above or below.
        // One on a page with no figure waits to be paired, so legends sharing
        // a page keep their figures in order.
        var away: [(key: String, caption: Caption, legend: Legend)] = []
        for key in labels where figurePage[key] == nil {
            guard let legend = words[key] else { continue }
            if pageShowsFigure(legend.pageIndex), standsBesideFigure(legend) {
                figurePage[key] = legend.pageIndex
            } else {
                away.append((key, legend, Legend(pageIndex: legend.pageIndex, pointsBack: pointsBack(legend))))
            }
        }
        if !away.isEmpty {
            let claimed = Set(figurePage.values)
            let reach = PDFTextExtractor.figurePageReach
            let nearby = Set(away.flatMap {
                max(pages.lowerBound, $0.legend.pageIndex - reach)...min(pages.upperBound - 1, $0.legend.pageIndex + reach)
            })
            var candidates: [Int] = []
            // The first page is the title page: its logos and graphical
            // abstract are ink outside the text, and no legend's figure.
            for index in nearby.sorted() where index > 0 && !captionPages.contains(index) && !claimed.contains(index) {
                if isFigurePage(index) { candidates.append(index) }
            }
            var paired = Self.pairedInOrder(away.map(\.legend), with: candidates, reach: reach)
            // Legends set in runs — two or more on one page or on pages that
            // follow one another — with two or more of them left without a
            // figure are a legends section, a preprint's, whose figures follow
            // on pages of their own however far on: 21 legends on pages 24–33
            // and their figures on pages 42–62 of one bioRxiv preprint. All
            // such legends are then paired forward over the
            // later figure pages together, the nearest winning — a PMC
            // manuscript lists main legends it has no figures for before the
            // supplementary ones its last pages show — and the pairing is kept
            // when it places more of them. A caption alone in the body text is
            // not a section: an eLife paper's thin line drawings, too faint to
            // count as a figure, sat right beside theirs on pages 4 and 10. It never reaches past a page
            // another figure holds: a section's figures follow it, and what
            // lies beyond the figures placed after it — a Nature paper's
            // Reporting Summary, set as pictures, after its Extended Data —
            // is not theirs. One legend left over is never sent far: in a
            // Nature Cancer paper that was a supplementary image 23 pages on.
            let section = Self.consecutiveRuns(of: away.map(\.legend.pageIndex)).filter { $0.count >= 2 }.flatMap { $0 }
            let placed = section.compactMap { paired[$0] }.count
            if section.count - placed >= 2, let first = section.first {
                // Figures the other legends were paired with hold their
                // pages as well.
                let held = claimed.union(away.indices.filter { !section.contains($0) }.compactMap { paired[$0] })
                var later: [Int] = []
                for index in (away[first].legend.pageIndex + 1)..<pages.upperBound
                    where !captionPages.contains(index) && !held.contains(index) {
                    if isFigurePage(index) { later.append(index) }
                }
                let far = Self.pairedInOrder(
                    section.map { away[$0].legend }, with: later, reach: pages.count, forwardOnly: true, barriers: held
                )
                if far.compactMap({ $0 }).count > placed {
                    for (index, page) in zip(section, far) { paired[index] = page }
                }
            }
            var taken = claimed.union(paired.compactMap { $0 })
            for (entry, page) in zip(away, paired) {
                // Unpaired, a legend opening its page still belongs to a
                // figure that filled the page before; any other stays where
                // it is printed.
                let before = page == nil ? pageBefore(opening: entry.caption, claimed: taken) : nil
                if let before { taken.insert(before) }
                figurePage[entry.key] = page ?? before ?? entry.legend.pageIndex
            }
        }

        let order = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        return labels
            .compactMap { key -> (Int, PDFIndexedFigure)? in
                guard let page = figurePage[key], let legend = words[key] else { return nil }
                return (order[key] ?? 0, PDFIndexedFigure(figureLabel: legend.label, pageIndex: page, caption: legend.caption))
            }
            .sorted { ($0.1.pageIndex, $0.0) < ($1.1.pageIndex, $1.0) }
            .map(\.1)
    }

    /// The page before `legend`'s when the legend is the first thing printed
    /// on its page, under the running head, and the page before is a figure
    /// that filled it (`uncaptionedFigureBand`) — Nature's layout for a
    /// full-page figure.
    private mutating func pageBefore(opening legend: Caption, claimed: Set<Int>) -> Int? {
        let before = legend.pageIndex - 1
        guard legend.position == 0, before >= pages.lowerBound, !claimed.contains(before),
              let page = document.page(at: legend.pageIndex),
              let previous = document.page(at: before),
              PaperFigureRectRefiner.captionLeadsPage(legend.caption, on: page),
              PaperFigureRectRefiner.uncaptionedFigureBand(on: previous, mask: mask(before)) != nil
        else { return nil }
        return before
    }

    /// Whether a figure stands beside `legend` on its page: its region holds
    /// one (`PaperFigureRectRefiner.figureRegion`). Figure 4 of a JBC paper
    /// fills the page before its legend, which is printed at the
    /// foot of Figure 5's page under two columns of text; with the page
    /// showing Figure 5, Figure 4 was indexed there and cropped to the text.
    /// A legend the page's text cannot place, or a sentence of the running
    /// text that only opens with a figure's label, is taken to stand by its
    /// figure (`PaperFigureRectRefiner.legendStandsBesideFigure`).
    private mutating func standsBesideFigure(_ legend: Caption) -> Bool {
        guard let page = document.page(at: legend.pageIndex),
              let anchor = PaperFigureRectRefiner.captionBounds(of: legend.caption, on: page),
              let mask = mask(legend.pageIndex),
              let text = PaperFigureRectRefiner.PageText(page: page, mask: mask) else { return true }
        return PaperFigureRectRefiner.legendStandsBesideFigure(captionAnchor: anchor, text: text, mask: mask)
    }

    private func pointsBack(_ legend: Caption) -> Bool {
        guard let page = document.page(at: legend.pageIndex),
              let bounds = PaperFigureRectRefiner.captionBounds(of: legend.caption, on: page) else { return false }
        return bounds.midY > page.bounds(for: .mediaBox).midY
    }

    private mutating func mask(_ index: Int) -> PaperFigureRectRefiner.PageInkMask? {
        if let cached = masks[index] { return cached }
        guard let page = document.page(at: index), let made = PaperFigureRectRefiner.mask(for: page) else { return nil }
        masks[index] = made
        return made
    }

    private mutating func ink(_ index: Int) -> PaperFigureRectRefiner.PageInk? {
        if let known = inks[index] { return known }
        let measured = document.page(at: index).flatMap { PaperFigureRectRefiner.pageInk(on: $0, mask: mask(index)) }
        inks[index] = measured
        return measured
    }

    private mutating func pageShowsFigure(_ index: Int) -> Bool {
        ink(index)?.showsFigure ?? false
    }

    private mutating func isFigurePage(_ index: Int) -> Bool {
        ink(index)?.isFigurePage ?? false
    }

    /// The indices of `pages` — ascending page numbers — in runs whose pages
    /// follow one another with no page between: legends set on one page, or
    /// on the next.
    static func consecutiveRuns(of pages: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for (index, page) in pages.enumerated() {
            if let last = runs.last?.last, page - pages[last] <= 1 {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs
    }

    /// Each legend's figure page, legends and pages paired in document order
    /// — legend i before legend j means its page comes before j's — placing
    /// as many legends as `reach` allows, then keeping them as near their
    /// pages as it can. A page on the side a legend points to (`pointsBack`)
    /// counts half a page nearer; `forwardOnly` pairs a legend only with a
    /// page after it, and no pairing reaches across a page in `barriers`.
    /// Nil for a legend no page is paired with.
    static func pairedInOrder(
        _ legends: [Legend],
        with pages: [Int],
        reach: Int,
        forwardOnly: Bool = false,
        barriers: Set<Int> = []
    ) -> [Int?] {
        let walls = barriers.sorted()
        struct Score: Equatable {
            var placed = 0
            var distance = 0.0
            func beats(_ other: Score) -> Bool {
                placed != other.placed ? placed > other.placed : distance < other.distance
            }
        }
        func distance(_ legend: Legend, _ page: Int) -> Double? {
            let offset = page - legend.pageIndex
            guard offset != 0, abs(offset) <= reach, !forwardOnly || offset > 0,
                  !walls.contains(where: { min(legend.pageIndex, page) < $0 && $0 < max(legend.pageIndex, page) })
            else { return nil }
            return Double(abs(offset)) + ((offset < 0) == legend.pointsBack ? 0 : 0.5)
        }
        // best[i][j]: the best pairing of legends i… with pages j….
        var best = [[Score]](repeating: [Score](repeating: Score(), count: pages.count + 1), count: legends.count + 1)
        func paired(_ i: Int, _ j: Int) -> Score? {
            distance(legends[i], pages[j]).map {
                Score(placed: best[i + 1][j + 1].placed + 1, distance: best[i + 1][j + 1].distance + $0)
            }
        }
        for i in stride(from: legends.count - 1, through: 0, by: -1) {
            for j in stride(from: pages.count - 1, through: 0, by: -1) {
                var score = best[i + 1][j].beats(best[i][j + 1]) ? best[i + 1][j] : best[i][j + 1]
                if let pair = paired(i, j), pair.beats(score) || pair == score { score = pair }
                best[i][j] = score
            }
        }
        var result = [Int?](repeating: nil, count: legends.count)
        var i = 0, j = 0
        while i < legends.count, j < pages.count {
            if let pair = paired(i, j), pair == best[i][j] {
                result[i] = pages[j]
                i += 1
                j += 1
            } else if best[i + 1][j] == best[i][j] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
#endif
