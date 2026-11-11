// Figure panel locator, extended panel, anchor resolver and panel identity tests.

import Foundation
import PDFKit
import SQLite3
import Testing
@testable import ForeverLM

// MARK: - Schema

// MARK: - Panel locator

/// A synthetic two-panel figure page whose panels print the words a plot
/// prints: an axis title with its unit under each, tick numbers along the
/// bottom, and a caption beneath. What `PaperFigurePanelLocator.printedText`
/// is meant to read.
private enum SyntheticAxisPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let panelA = CGRect(x: 80, y: 520, width: 200, height: 150)
    static let panelB = CGRect(x: 330, y: 520, width: 200, height: 150)
    static let captionLine = "Figure 1 | Two synthetic panels with axis titles, drawn for the printed-text tests."

    static func page() throws -> (PDFPage, PDFDocument, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticAxisPage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.15, alpha: 1)
        context.fill(panelA)
        context.fill(panelB)
        draw("A", at: CGPoint(x: panelA.minX, y: 690), font: "Helvetica-Bold", size: 10, in: context)
        draw("B", at: CGPoint(x: panelB.minX, y: 690), font: "Helvetica-Bold", size: 10, in: context)
        draw("0 10 20", at: CGPoint(x: panelA.minX + 20, y: panelA.minY - 8), font: "Helvetica", size: 5, in: context)
        draw("Time (min)", at: CGPoint(x: panelA.minX + 60, y: panelA.minY - 18), font: "Helvetica", size: 6, in: context)
        draw("Pressure (mmHg)", at: CGPoint(x: panelB.minX + 40, y: panelB.minY - 18), font: "Helvetica", size: 6, in: context)
        draw(captionLine, at: CGPoint(x: 80, y: 480), font: "Helvetica", size: 9, in: context)
        for index in 0..<3 {
            draw("Legend prose describing the panels at length, line \(index + 1), so the legend holds ink.",
                 at: CGPoint(x: 80, y: 480 - 16 - CGFloat(index) * 16), font: "Times-Roman", size: 9, in: context)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(url: url))
        return (try #require(document.page(at: 0)), document, url)
    }

    private static func draw(_ text: String, at point: CGPoint, font: String, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
            )),
            context
        )
    }
}

/// A synthetic two-panel figure page: a page-wide banner line across the top
/// (a preprint server's running head), two panel blocks side by side headed
/// by bold letters "A" and "B" with small axis labels under them, the caption
/// beneath, and prose under that. Geometry in PDF points from the bottom-left.
enum SyntheticPanelPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let bannerBaseline: CGFloat = 770
    static let panelA = CGRect(x: 80, y: 520, width: 200, height: 150)
    static let panelB = CGRect(x: 330, y: 520, width: 200, height: 150)
    static let letterBaseline: CGFloat = 690
    static let captionBaseline: CGFloat = 480
    static let captionLine = "Figure 1 | Two synthetic panels, drawn for the panel locator tests."
    /// How many lines of legend prose sit under the caption. With `denseLegend`
    /// the legend fills the page below the caption and carries more ink than
    /// the figure, which is the Fig. 3 case. `proseSize` is the point size the
    /// legend is set at, its lines pitched as a journal pitches them: 11 like
    /// a preprint, or 8 like a Nature journal's columns.
    static func write(to url: URL, denseLegend: Bool, proseSize: CGFloat = 11) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)

        draw("bioRxiv preprint doi: https://doi.org/10.1101/2025.09.25.678303; this version posted September 26, 2025.",
             at: CGPoint(x: 40, y: bannerBaseline), font: "Helvetica", size: 8, in: context)

        context.setFillColor(gray: 0.15, alpha: 1)
        context.fill(panelA)
        context.fill(panelB)
        draw("A", at: CGPoint(x: panelA.minX, y: letterBaseline), font: "Helvetica-Bold", size: 10, in: context)
        draw("B", at: CGPoint(x: panelB.minX, y: letterBaseline), font: "Helvetica-Bold", size: 10, in: context)
        // Axis labels: bold, but far smaller than the panel letters.
        draw("Y", at: CGPoint(x: panelA.minX + 4, y: panelA.minY - 8), font: "Helvetica-Bold", size: 4, in: context)
        draw("X", at: CGPoint(x: panelB.minX + 4, y: panelB.minY - 8), font: "Helvetica-Bold", size: 4, in: context)

        draw(captionLine, at: CGPoint(x: 80, y: captionBaseline), font: "Helvetica", size: 11, in: context)
        let pitch = (proseSize * 1.45).rounded()
        let legendLines = denseLegend ? Int((captionBaseline - 40) / pitch) : 3
        for index in 0..<legendLines {
            draw("(A) Legend prose describing the first panel at length, line \(index + 1), so the legend holds ink.",
                 at: CGPoint(x: 80, y: captionBaseline - 16 - CGFloat(index) * pitch), font: "Times-Roman", size: proseSize, in: context)
        }

        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, font: String, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
            )),
            context
        )
    }

    /// The page, the document that owns it, and the file. A `PDFPage` only
    /// weakly references its `PDFDocument`; a caller that kept the page alone
    /// let the document go, and PDFKit's text scanner then crashed the test
    /// host inside `selectionForWord(at:)` ("Drawing a PDFPage when its
    /// PDFDocument is nil is unsupported"). Hold the document for as long as
    /// the page is used — `withExtendedLifetime(document)` at the end of the
    /// test is enough.
    static func page(denseLegend: Bool = false, proseSize: CGFloat = 11) throws -> (PDFPage, PDFDocument, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticPanelPage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        try write(to: url, denseLegend: denseLegend, proseSize: proseSize)
        let document = try #require(PDFDocument(url: url))
        return (try #require(document.page(at: 0)), document, url)
    }

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static func normalizedTop(_ y: CGFloat) -> Double { (mediaBox.maxY - y) / mediaBox.height }
    static func normalizedX(_ x: CGFloat) -> Double { x / mediaBox.width }
}

@Suite("Walkthrough panel locator")
struct PaperFigurePanelLocatorTests {

    private func line(_ text: String, size: Double, bold: Bool, x: Double, y: Double, width: Double = 0.01) -> PaperFigurePanelLocator.TextLine {
        PaperFigurePanelLocator.TextLine(
            text: text,
            fontName: bold ? "Arial-BoldMT" : "ArialMT",
            pointSize: size,
            isBold: bold,
            rect: PaperFigureRect(x: x, y: y, width: width, height: 0.0125)
        )
    }

    @Test("A line opens with a panel letter when its first token is one letter, however it is dressed")
    func leadingLetters() {
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "A") == "A")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "a") == "A")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "(b)") == "B")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "C.") == "C")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "E Lysosomes") == "E")
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "-") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "5") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "Brain") == nil)
        #expect(PaperFigurePanelLocator.leadingPanelLetter(of: "") == nil)
    }

    @Test("Panel letters are the bold single letters near the largest such size, once each, in a run")
    func anchors() {
        let lines = [
            line("A", size: 8.8, bold: true, x: 0.12, y: 0.10),
            line("Tmem192 LCMS analysis", size: 6.2, bold: true, x: 0.5, y: 0.11),
            line("B", size: 8.8, bold: true, x: 0.12, y: 0.21),
            line("D", size: 8.8, bold: true, x: 0.33, y: 0.21),
            line("-", size: 7.0, bold: true, x: 0.2, y: 0.25),
            line("Y", size: 4.2, bold: true, x: 0.14, y: 0.26),       // an axis label
            line("C", size: 8.8, bold: true, x: 0.12, y: 0.32),
            line("C", size: 8.8, bold: true, x: 0.6, y: 0.40),        // a second C: the first wins
            line("E Lysosomes", size: 8.8, bold: true, x: 0.33, y: 0.48),
            line("F", size: 8.8, bold: false, x: 0.7, y: 0.48),       // not bold
            line("X", size: 8.8, bold: true, x: 0.8, y: 0.05),        // out of the run
        ]
        let anchors = PaperFigurePanelLocator.panelAnchors(from: lines)
        #expect(anchors.map(\.label) == ["A", "B", "D", "C", "E"])
        #expect(anchors.first { $0.label == "C" }?.rect.x == 0.12)
        #expect(PaperFigurePanelLocator.panelAnchors(from: [line("Q", size: 8, bold: true, x: 0.1, y: 0.1)]).map(\.label) == ["Q"])
        #expect(PaperFigurePanelLocator.panelAnchors(from: []).isEmpty)
    }

    @Test("Letters partition the figure: right to the next letter overlapping the row, down to the first letter below, out to the edge otherwise")
    func partition() throws {
        // Figure 1 of the lysosome-aging preprint: A across the top; B and D on
        // the second row, D tall; C under B, reaching the bottom; E under D.
        let figure = PaperFigureRect(x: 0.11, y: 0.08, width: 0.78, height: 0.51)
        func anchor(_ label: String, _ x: Double, _ y: Double) -> PaperFigurePanelLocator.PanelAnchor {
            .init(label: label, rect: PaperFigureRect(x: x, y: y, width: 0.0104, height: 0.0125), pointSize: 8.8)
        }
        let anchors = [anchor("A", 0.119, 0.098), anchor("B", 0.118, 0.208), anchor("D", 0.328, 0.208), anchor("C", 0.118, 0.324), anchor("E", 0.327, 0.476)]
        let panels = PaperFigurePanelLocator.partition(anchors, within: figure)
        let gutter = PaperFigurePanelLocator.gutter
        let a = try #require(panels["A"]); let b = try #require(panels["B"]); let c = try #require(panels["C"])
        let d = try #require(panels["D"]); let e = try #require(panels["E"])
        let right = figure.x + figure.width
        let bottom = figure.y + figure.height
        func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-6 }

        // A: the whole first row, from the figure's top to just above B and D.
        #expect(close(a.x, figure.x) && close(a.y, figure.y) && close(a.x + a.width, right))
        #expect(close(a.y + a.height, 0.208 - gutter))
        // B: from the figure's left to just before D; down to C.
        #expect(close(b.x, figure.x) && close(b.y, 0.208 - gutter))
        #expect(close(b.x + b.width, 0.328 - gutter) && close(b.y + b.height, 0.324 - gutter))
        // C: under B, to the figure's bottom, stopping where D's column and E begin — E is beside it, not below it.
        #expect(close(c.x, figure.x) && close(c.x + c.width, min(0.328, 0.327) - gutter) && close(c.y + c.height, bottom))
        // D: tall — from its letter to the right edge, down to E.
        #expect(close(d.x, 0.328 - gutter) && close(d.y, 0.208 - gutter) && close(d.x + d.width, right))
        #expect(close(d.y + d.height, 0.476 - gutter))
        // E: beside C's lower half, so from its own letter, to the corner.
        #expect(close(e.x, 0.327 - gutter) && close(e.y, 0.476 - gutter) && close(e.x + e.width, right) && close(e.y + e.height, bottom))
        let allValid = panels.values.allSatisfy { $0.isValid }
        #expect(allValid)

        // A tall left panel keeps its height beside a column of two.
        let tall = PaperFigurePanelLocator.partition(
            [anchor("A", 0.12, 0.10), anchor("B", 0.5, 0.10), anchor("C", 0.5, 0.35)],
            within: figure
        )
        #expect(close(try #require(tall["A"]).y + tall["A"]!.height, bottom))
        #expect(close(try #require(tall["A"]).x + tall["A"]!.width, 0.5 - gutter))
        #expect(close(try #require(tall["B"]).y + tall["B"]!.height, 0.35 - gutter))
        #expect(close(try #require(tall["C"]).x, 0.5 - gutter))
        #expect(PaperFigurePanelLocator.partition([], within: figure).isEmpty)
    }

    @Test("On a page, the bold letters place the panels, the crop starts under the banner, and the axis labels are ignored")
    func panelsOnAPage() throws {
        let (page, document, _) = try SyntheticPanelPage.page()
        defer { withExtendedLifetime(document) {} }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        // The banner across the top is not part of the figure.
        #expect(crop.y > SyntheticPanelPage.normalizedTop(SyntheticPanelPage.bannerBaseline) + 0.005)
        #expect(crop.y < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.letterBaseline + 10))
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))

        let lines = PaperFigurePanelLocator.textLines(in: crop, on: page)
        #expect(lines.contains { $0.text == "A" && $0.isBold && $0.pointSize > 9 })
        #expect(lines.contains { $0.text == "Y" && $0.isBold && $0.pointSize < 5 })

        let panels = PaperFigurePanelLocator.panelRects(in: crop, on: page, mask: mask)
        #expect(panels.keys.sorted() == ["A", "B"])
        let a = try #require(panels["A"]); let b = try #require(panels["B"])
        // A ends before B begins, and each holds its own block.
        #expect(a.x + a.width <= b.x + 0.001)
        #expect(a.x <= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelA.minX) + 0.01)
        #expect(a.x + a.width >= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelA.maxX) - 0.01)
        #expect(b.x <= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.minX) + 0.01)
        #expect(b.x + b.width >= SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.maxX) - 0.01)
        #expect(a.y + a.height >= SyntheticPanelPage.normalizedTop(SyntheticPanelPage.panelA.minY) - 0.01)
        #expect(PaperFigurePanelLocator.panelRect(labelled: "b", in: crop, on: page, mask: mask) == b)
        #expect(PaperFigurePanelLocator.panelRect(labelled: "c", in: crop, on: page, mask: mask) == nil)
    }

    @Test("A long legend under the caption is prose, so the figure is the sparse side above it")
    func figureSideReadsProse() throws {
        let (page, document, _) = try SyntheticPanelPage.page(denseLegend: true)
        defer { withExtendedLifetime(document) {} }
        let caption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: page))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: caption, on: page) == .above)
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        // Above the caption, not the legend below it.
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))
        // The sparse variant has too little prose either side to say; the ink decides.
        let (sparse, sparseDocument, _) = try SyntheticPanelPage.page(denseLegend: false)
        defer { withExtendedLifetime(sparseDocument) {} }
        let sparseCaption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: sparse))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: sparseCaption, on: sparse) == nil)
        let head = try #require(PaperFigureRectRefiner.runningHeadBounds(on: page))
        #expect(head.minY > SyntheticPanelPage.mediaBox.height * (1 - PaperFigureRectRefiner.runningHeadDepth))
        #expect(head.width >= SyntheticPanelPage.mediaBox.width * PaperFigureRectRefiner.runningHeadMinimumWidthShare)
    }

    @Test("A figure's printed words are its axis titles, legend keys and condition labels — not its panel letters or tick numbers")
    func printedTextReadsLabelsNotTicks() {
        // The lines PDFKit hands back for Fig. 1 of the cardiac-sodium paper
        // (2026-09-20), in reading order, with two panels sharing an x axis.
        let lines = [
            line("a b", size: 11.3, bold: false, x: 0.2, y: 0.05),
            line("23Na TQF (intracellular Na)", size: 4.5, bold: false, x: 0.2, y: 0.1),
            line("relative to baseline (arb. units)", size: 7.7, bold: false, x: 0.21, y: 0.1),
            line("1.4", size: 7, bold: false, x: 0.23, y: 0.06),
            line("1.0", size: 7, bold: false, x: 0.23, y: 0.12),
            line("LVDP (mmHg)", size: 7.7, bold: false, x: 0.5, y: 0.1),
            line("**", size: 8.4, bold: false, x: 0.77, y: 0.1),
            line("ouabain", size: 4.9, bold: false, x: 0.36, y: 0.18),
            line("washout", size: 4.9, bold: false, x: 0.42, y: 0.18),
            line("ouabain", size: 4.9, bold: false, x: 0.65, y: 0.18),
            line("0 10 20 30 40 50 60", size: 7, bold: false, x: 0.27, y: 0.2),
            line("Time (min) Time (min)", size: 7.7, bold: false, x: 0.34, y: 0.21),
            line("c d", size: 11.3, bold: false, x: 0.2, y: 0.23),
            line("PAB PAB", size: 7, bold: false, x: 0.34, y: 0.24),
            line("n = 6", size: 7, bold: false, x: 0.34, y: 0.3),
            line("−5%", size: 7, bold: false, x: 0.34, y: 0.31),
        ]
        #expect(PaperFigurePanelLocator.printedText(from: lines) == [
            "23Na TQF (intracellular Na)", "relative to baseline (arb. units)", "LVDP (mmHg)", "**",
            "ouabain", "washout", "Time (min)", "PAB", "n = 6",
        ])
        #expect(PaperFigurePanelLocator.printedLine("  (C)  ") == nil)
        #expect(PaperFigurePanelLocator.printedLine("0.8") == nil)
        #expect(PaperFigurePanelLocator.printedLine("E Lysosomes") == "E Lysosomes")
        let many = (0..<60).map { line("label \($0)", size: 7, bold: false, x: 0.2, y: 0.1 + Double($0) * 0.01) }
        #expect(PaperFigurePanelLocator.printedText(from: many).count == PaperFigurePanelLocator.printedTextLineLimit)
    }

    @Test("The text-layer reading of a drawn figure has its panel letters and the words under them, and the writer's reference carries both")
    func textLayerReadingFromPage() throws {
        let (page, document, url) = try SyntheticAxisPage.page()
        defer { withExtendedLifetime(document) {} }
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticAxisPage.captionLine, on: page))
        let printed = PaperFigurePanelLocator.printedText(in: crop, on: page)
        // Two titles set on one baseline come back from PDFKit as one line,
        // "Time (min) Pressure (mmHg)"; the writer reads them either way.
        #expect(printed.contains { $0.contains("Time (min)") })
        #expect(printed.contains { $0.contains("Pressure (mmHg)") })
        #expect(!printed.contains("A"))
        #expect(!printed.contains { $0.hasPrefix("Figure 1 |") })
        #expect(!printed.contains("0 10 20"))

        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: SyntheticAxisPage.captionLine, analysis: nil)
        let readings = PaperFigurePanelLocator.textLayer(for: [record], pdfPath: url.path)
        #expect(readings["f1"]?.panelLabels == ["A", "B"])
        #expect(readings["f1"]?.printedText == printed)
        #expect(PaperFigurePanelLocator.panelLabels(for: [record], pdfPath: url.path) == ["f1": ["A", "B"]])
        let references = PaperWalkthroughGeneratorService.figureReferences(from: [record], pdfPath: url.path)
        #expect(references.first?.panelLabels == ["A", "B"])
        #expect(references.first?.printedText == printed)
    }

    @Test("Prose set at 8 pt, as Nature journals set their columns, is still prose")
    func figureSideReadsSmallProse() throws {
        // Fig. 1 of the cardiac-sodium paper (Nature Communications, 2026-09-20):
        // columns at 8.2 pt sat under a fixed 9 pt floor, no line counted as
        // body text, and the ink vote cropped the figure to the prose below
        // its caption. Prose is read by line width now, whatever its size.
        let (page, document, _) = try SyntheticPanelPage.page(denseLegend: true, proseSize: 8)
        defer { withExtendedLifetime(document) {} }
        let caption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticPanelPage.captionLine, on: page))
        #expect(PaperFigureRectRefiner.figureSide(captionBounds: caption, on: page) == .above)
        let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticPanelPage.captionLine, on: page))
        #expect(crop.y + crop.height < SyntheticPanelPage.normalizedTop(SyntheticPanelPage.captionBaseline))
        #expect(crop.y > SyntheticPanelPage.normalizedTop(SyntheticPanelPage.bannerBaseline) + 0.005)
    }
}

// MARK: - Analysed panel rectangles

@Suite("Analysed panel rectangles grow onto the ink they cut")
struct PaperFigureExtendedPanelTests {

    @Test("A panel cut short inside its own ink grows to its edge, and never into the next panel")
    func cutPanelGrowsToItsInkNotItsNeighbour() throws {
        // Figure 2h of the cardiac-sodium paper (2026-09-22): the vision
        // rectangle stopped a group of bars short of the panel's right edge,
        // and the figure's own rectangle short of the same labels.
        let (page, document, url) = try SyntheticPanelPage.page()
        defer {
            withExtendedLifetime(document) {}
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let a = SyntheticPanelPage.panelA, b = SyntheticPanelPage.panelB
        func normalized(_ rect: CGRect) -> PaperFigureRect {
            PaperFigureRect(
                x: SyntheticPanelPage.normalizedX(rect.minX),
                y: SyntheticPanelPage.normalizedTop(rect.maxY),
                width: rect.width / SyntheticPanelPage.mediaBox.width,
                height: rect.height / SyntheticPanelPage.mediaBox.height
            )
        }
        // A's rectangle stops 60 pt inside A; B's rectangle reaches 10 pt
        // into the gutter towards A, which is white, so it stays.
        let cutA = normalized(CGRect(x: a.minX, y: a.minY, width: a.width - 60, height: a.height))
        let looseB = normalized(CGRect(x: b.minX - 10, y: b.minY, width: b.width, height: b.height))
        // The figure's rectangle stops 40 pt inside B.
        let cutFigure = normalized(CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX - 40, height: a.height))

        let extended = PaperFigureRectRefiner.extendedPanelRects(["a": cutA, "b": looseB], within: cutFigure, with: mask)

        let tolerance = 0.01
        let figureRight = extended.figure.x + extended.figure.width
        #expect(abs(figureRight - SyntheticPanelPage.normalizedX(b.maxX)) < tolerance)
        let grownA = try #require(extended.panels["a"])
        let aRight = grownA.x + grownA.width
        #expect(abs(aRight - SyntheticPanelPage.normalizedX(a.maxX)) < tolerance)
        #expect(aRight < SyntheticPanelPage.normalizedX(b.minX))
        let grownB = try #require(extended.panels["b"])
        #expect(abs(grownB.x - looseB.x) < 0.001)
        #expect(abs(grownB.x + grownB.width - SyntheticPanelPage.normalizedX(b.maxX)) < tolerance)
    }

    @Test("Two panels whose rectangles overlap are split at the white gutter between them")
    func overlappingPanelsSplitAtTheirGutter() throws {
        // Figure 1 of the MitoSpace paper (2026-09-23): panel A's rectangle
        // ran into panel B's, and A's card showed B's heading cut in half.
        let (page, document, url) = try SyntheticPanelPage.page()
        defer {
            withExtendedLifetime(document) {}
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let a = SyntheticPanelPage.panelA, b = SyntheticPanelPage.panelB
        let box = SyntheticPanelPage.mediaBox
        func normalized(_ rect: CGRect) -> PaperFigureRect {
            PaperFigureRect(
                x: SyntheticPanelPage.normalizedX(rect.minX),
                y: SyntheticPanelPage.normalizedTop(rect.maxY),
                width: rect.width / box.width,
                height: rect.height / box.height
            )
        }
        // Both reach up to the letters; A runs 20 pt into B, B starts 20 pt
        // into the 50 pt gutter towards A.
        let top = SyntheticPanelPage.letterBaseline + 14
        let wideA = normalized(CGRect(x: a.minX, y: a.minY, width: b.minX + 20 - a.minX, height: top - a.minY))
        let wideB = normalized(CGRect(x: a.maxX + 20, y: b.minY, width: b.maxX - a.maxX - 20, height: top - b.minY))

        let split = PaperFigureRectRefiner.separatedPanelRects(["a": wideA, "b": wideB], with: mask)
        let splitA = try #require(split["a"]), splitB = try #require(split["b"])
        let aRight = splitA.x + splitA.width
        #expect(aRight >= SyntheticPanelPage.normalizedX(a.maxX))
        #expect(aRight < SyntheticPanelPage.normalizedX(b.minX))
        #expect(splitB.x > SyntheticPanelPage.normalizedX(a.maxX))
        #expect(splitB.x < SyntheticPanelPage.normalizedX(b.minX))
        #expect(aRight <= splitB.x)
        // Only the overlapping edges moved.
        #expect(abs(splitA.x - wideA.x) < 0.002 && abs(splitA.y - wideA.y) < 0.002)
        #expect(abs(splitA.height - wideA.height) < 0.002)
        #expect(abs(splitB.x + splitB.width - (wideB.x + wideB.width)) < 0.002)

        // The Reader's route, through the growth pass, keeps the split.
        let figure = normalized(CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX, height: top - a.minY))
        let extended = PaperFigureRectRefiner.extendedPanelRects(["a": wideA, "b": wideB], within: figure, with: mask)
        let extendedA = try #require(extended.panels["a"])
        #expect(extendedA.x + extendedA.width < SyntheticPanelPage.normalizedX(b.minX))

        // Two rectangles overlapping inside one block of ink have no gutter
        // between them, and are left as they were.
        let left = normalized(CGRect(x: a.minX, y: a.minY, width: 120, height: a.height))
        let right = normalized(CGRect(x: a.minX + 80, y: a.minY, width: 120, height: a.height))
        let unsplit = PaperFigureRectRefiner.separatedPanelRects(["x": left, "y": right], with: mask)
        #expect(unsplit["x"] == left && unsplit["y"] == right)
    }
}

// MARK: - Anchor resolver

@Suite("Walkthrough anchor resolver")
struct WalkthroughAnchorResolverTests {

    @Test("A panel step resolves to that panel with a lens; the whole figure without; the document opens and the page is read once")
    func resolvesAndCaches() async throws {
        let (_, _, url) = try SyntheticPanelPage.page()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: SyntheticPanelPage.captionLine, analysis: nil)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: url.path)

        let panelA = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 1)))
        #expect(panelA.panelLabels == ["A", "B"])
        #expect(panelA.panel == "A")
        let lens = try #require(panelA.lensImage)
        #expect(!lens.isEmpty)
        #expect(NSImage(data: lens) != nil)
        guard case .figure(let pageIndex, let rect, let caption, let shares) = panelA.target else {
            Issue.record("expected a figure target"); return
        }
        #expect(pageIndex == 0 && caption == SyntheticPanelPage.captionLine && !shares)
        let a = try #require(rect)
        #expect(a.x + a.width < SyntheticPanelPage.normalizedX(SyntheticPanelPage.panelB.minX))

        let whole = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1")))
        #expect(whole.panel == nil && whole.lensImage == nil && whole.panelLabels == ["A", "B"])
        guard case .figure(_, let wholeRect, _, _) = whole.target else { Issue.record("expected a figure target"); return }
        #expect(try #require(wholeRect).width > a.width)

        // The learner's own pick within the step, and "the whole figure" again.
        let picked = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a"), panel: "B"))
        #expect(picked.panel == "B")
        let cleared = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a"), panel: ""))
        #expect(cleared.panel == nil)

        // Every answer came from one open document and one read of the page's ink.
        let again = await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "a", pageNumber: 1))
        #expect(again == panelA)
        await resolver.prefetch([PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "b"), nil])
        #expect(await resolver.documentOpens == 1)
        #expect(await resolver.maskRenders == 1)

        // Other anchors, and nothing.
        let passage = try #require(await resolver.resolve(PaperWalkthroughAnchor(passage: "Two synthetic panels", pageNumber: 1)))
        #expect(passage.target == .passage("Two synthetic panels", pageHint: 0) && passage.panelLabels.isEmpty)
        #expect(try #require(await resolver.resolve(PaperWalkthroughAnchor(pageNumber: 3))).target == .page(pageIndex: 2))
        #expect(await resolver.resolve(nil) == nil)
        #expect(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 9")) == nil)
        #expect(resolver.matches(figures: [record], pdfPath: url.path))
        #expect(!resolver.matches(figures: [], pdfPath: url.path))
    }

    @Test("A figure the page cannot place still scrolls to its page, and a panel of it has no lens")
    func figureWithoutGeometry() async throws {
        let record = PaperFigureRecord(id: "f1", sourceID: "s", figureLabel: "Figure 1", pageIndex: 0, caption: "Figure 1 | Missing.", analysis: nil)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: "/nonexistent/paper.pdf")
        let resolved = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 1", panelLabel: "c")))
        #expect(resolved.target == .figure(pageIndex: 0, rect: nil, caption: "Figure 1 | Missing.", sharesPageWithOtherFigures: false))
        #expect(resolved.panel == nil && resolved.lensImage == nil && resolved.panelLabels.isEmpty)
    }
}

// MARK: - Panel identity

/// A panel is its label, not the label's last letter (2026-09-29). Figure 3
/// of "Engineered human resilience and durability" is a four-column funnel
/// whose vision analysis names its panels ALL OF BIOLOGY, FUNCTION
/// RETRIEVAL, DESIGN and VALIDATION; read as letters they were Y, L, N and
/// N, so DESIGN's rectangle was overwritten by VALIDATION's, and a walk
/// taking the columns left to right was warned it had them out of order.
@Suite("Walkthrough panel identity")
struct PaperWalkthroughPanelIdentityTests {

    /// The rectangles the vision pass stored for that figure.
    static let funnelPanels = [
        PaperFigurePanel(id: "fig-3-panel-1", label: "ALL OF BIOLOGY", explanation: "Every protein.",
                         rect: PaperFigureRect(x: 0.10671, y: 0.12364, width: 0.20242, height: 0.18040)),
        PaperFigurePanel(id: "fig-3-panel-2", label: "FUNCTION RETRIEVAL", explanation: "Proteins with the function.",
                         rect: PaperFigureRect(x: 0.30033, y: 0.12364, width: 0.19912, height: 0.17107)),
        PaperFigurePanel(id: "fig-3-panel-3", label: "DESIGN", explanation: "Designed variants.",
                         rect: PaperFigureRect(x: 0.49175, y: 0.12364, width: 0.19802, height: 0.18974)),
        PaperFigurePanel(id: "fig-3-panel-4", label: "VALIDATION", explanation: "What survives the assay.",
                         rect: PaperFigureRect(x: 0.69307, y: 0.15086, width: 0.19142, height: 0.17263)),
    ]
    static let funnelAnalysis = PaperFigureAnalysis(
        summary: "The search space and funnel.",
        visualEvidence: [],
        figureRect: PaperFigureRect(x: 0.10671, y: 0.12364, width: 0.77778, height: 0.22473),
        panels: funnelPanels,
        analysisVersion: PaperFigureAnalysis.currentVersion,
        generatedAt: Date(timeIntervalSince1970: 0)
    )
    static let funnelNames = ["ALL OF BIOLOGY", "FUNCTION RETRIEVAL", "DESIGN", "VALIDATION"]
    static let funnel = PaperWalkthroughFigureReference(
        label: "Figure 3", pageNumber: 6, caption: "Figure 3: The search space and funnel.", panelLabels: funnelNames
    )
    static let funnelText = """
    Every protein biology has produced is a candidate mechanism. Each stage of the funnel narrows the candidates \
    before any is tested. Figure 3 lays out the search space and the funnel from all of biology to validation.
    """

    /// The letter-only reading of a panel label: the last character of the
    /// label, upper-cased.
    static func letterOnlyPanelLetter(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]."))
        guard let last = trimmed.last, last.isLetter else { return nil }
        return String(last).uppercased()
    }

    @Test("A lettered panel is its letter, exactly as before; a named panel is its whole name")
    func identity() {
        // Every spelling of a lettered panel the model and the vision pass
        // write: the letter is what it always was, and the letter is the key.
        let lettered = ["a", "A", "(a)", "(B)", "b.", "[c]", "  d  ", "1a", "1A", "Figure 2B", "Fig. 3e", "Fig. S2b",
                        "Extended Data Fig. 3a", "panel b", "Panel B", "panels c and d", "b–d", "a, b", "(a) and (b)", "i", "v"]
        for label in lettered {
            #expect(PaperWalkthroughValidation.panelLetter(label) == Self.letterOnlyPanelLetter(label), "\(label)")
            #expect(PaperWalkthroughValidation.panelKey(label) == Self.letterOnlyPanelLetter(label), "\(label)")
            #expect(PaperWalkthroughValidation.panelDisplayName(label) == Self.letterOnlyPanelLetter(label), "\(label)")
        }
        #expect(PaperWalkthroughValidation.panelLetter("(c)") == "C")
        #expect(PaperWalkthroughValidation.panelLetter("Figure 2B") == "B")
        #expect(PaperWalkthroughValidation.samePanel("(a)", "Figure 1A"))
        #expect(!PaperWalkthroughValidation.samePanel("a", "b"))

        // A named panel is never one letter of its name.
        for name in Self.funnelNames {
            #expect(PaperWalkthroughValidation.panelLetter(name) == nil, "\(name)")
        }
        #expect(Self.funnelNames.compactMap(PaperWalkthroughValidation.panelKey)
                == ["all of biology", "function retrieval", "design", "validation"])
        #expect(Set(PaperWalkthroughValidation.panelKeys(Self.funnelNames)).count == 4)
        #expect(PaperWalkthroughValidation.panelKey("ALL OF  BIOLOGY") == "all of biology")
        #expect(PaperWalkthroughValidation.panelKey(" Design ") == "design")
        #expect(PaperWalkthroughValidation.panelKey("Figure 3 DESIGN") == "design")
        #expect(PaperWalkthroughValidation.samePanel("DESIGN", "design"))
        #expect(!PaperWalkthroughValidation.samePanel("DESIGN", "VALIDATION"))
        #expect(!PaperWalkthroughValidation.samePanel("DESIGN", "n"))
        // Roman-numeral panels stop colliding too: "ii" was "I".
        #expect(PaperWalkthroughValidation.panelKey("ii") == "ii")
        #expect(PaperWalkthroughValidation.panelKey("i") == "I")
        // A figure's label alone names no panel.
        #expect(PaperWalkthroughValidation.panelKey("Figure 2") == nil)
        #expect(PaperWalkthroughValidation.panelKey("") == nil)

        #expect(PaperWalkthroughValidation.panelDisplayName("Design") == "Design")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 2", panel: "b") == "Figure 2b")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 3", panel: "DESIGN") == "Figure 3 DESIGN")
        #expect(PaperWalkthroughValidation.figurePanelLabel("Figure 3", panel: nil) == "Figure 3")
        #expect(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "DESIGN").figureDisplayLabel == "Figure 3 DESIGN")
        #expect(PaperWalkthroughAnchor(figureLabel: "Figure 2", panelLabel: "a").figureDisplayLabel == "Figure 2a")
    }

    @Test("Lettered panels are ordered, covered and found exactly as before, with or without the figure list")
    func letteredUnchanged() throws {
        let figure = PaperWalkthroughFigureReference(label: "Figure 3", pageNumber: 24, caption: "Fig. 3.", panelLabels: ["A", "B", "C"])
        let disordered = [
            step(.figure, title: "c first", figure: "Figure 3", panel: "c"),
            step(.figure, title: "then a", figure: "Figure 3", panel: "a"),
            step(.figure, title: "then b", figure: "Figure 3", panel: "Figure 3B"),
        ]
        let expected = ["Step 2 (Figure 3 A) comes after step 1 (Figure 3 C); a figure's panels are walked in order."]
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: disordered) == expected)
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: disordered, figures: [figure]) == expected)

        let gaps = PaperWalkthroughValidation.panelCoverageGaps(
            steps: [step(.figure, body: "Panel B repeats it.", figure: "Figure 3", panel: "a")],
            figures: [figure]
        )
        #expect(gaps == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 3", missingPanels: ["C"])])

        // A lettered Find it keeps the lower-cased letter the record always kept.
        var find = step(.quiz, title: "Find", quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "Panel b.", kind: .find, targetPanel: "(B)"))
        find.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Walk", steps: [find, step(.explain, body: "More.")], sourceID: "src", sourceSHA256: "sha",
            figures: [figure], text: paperText, author: .assistant
        )
        #expect(outcome.walkthrough.steps[0].quiz?.kind == .find)
        #expect(outcome.walkthrough.steps[0].quiz?.targetPanel == "b")

        // The resolver's letters stay alphabetical and upper case.
        let panels = WalkthroughAnchorResolver.analysedPanels([
            PaperFigurePanel(id: "c", label: "c", explanation: "", rect: PaperFigureRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2)),
            PaperFigurePanel(id: "a", label: "(a)", explanation: "", rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            PaperFigurePanel(id: "b", label: "B", explanation: "", rect: nil),
        ])
        #expect(panels.labels == ["A", "C"])
        #expect(panels.rects["A"]?.x == 0.1)
    }

    @Test("Figure 3's four named columns are four panels: walked left to right, covered, and found by name")
    func namedPanelsInTheValidator() throws {
        let leftToRight = zip(Self.funnelNames, ["Everything", "Retrieval", "Design", "Validation"]).map { name, title in
            step(.figure, title: title, body: "This column narrows the candidates.", figure: "Figure 3", panel: name)
        }
        // Alphabetically DESIGN comes before FUNCTION RETRIEVAL; the figure
        // prints it after, and the figure's order is the one walked.
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: leftToRight, figures: [Self.funnel]).isEmpty)
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: leftToRight, figures: [Self.funnel]).isEmpty)

        let backwards = [leftToRight[2], leftToRight[1]]
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: backwards, figures: [Self.funnel])
                == ["Step 2 (Figure 3 FUNCTION RETRIEVAL) comes after step 1 (Figure 3 DESIGN); a figure's panels are walked in order."])
        // DESIGN and VALIDATION were both "N", so a step on each read as one panel twice.
        #expect(PaperWalkthroughValidation.panelOrderWarnings(steps: [leftToRight[3], leftToRight[2]], figures: [Self.funnel]).count == 1)

        // Coverage: a column is addressed by anchoring to it or naming it.
        let threeColumns = Array(leftToRight.prefix(3))
        #expect(PaperWalkthroughValidation.panelCoverageGaps(steps: threeColumns, figures: [Self.funnel])
                == [PaperWalkthroughValidation.PanelCoverageGap(figureLabel: "Figure 3", missingPanels: ["VALIDATION"])])
        let named = step(.figure, body: "The Validation column is what survives the assay.", figure: "Figure 3", panel: "DESIGN")
        #expect(PaperWalkthroughValidation.mentionedPanels(in: named, of: Self.funnel) == ["design", "validation"])

        // The whole walk validates without a false order warning, and a
        // Find it names its column by name.
        var find = step(.quiz, title: "Find", quiz: PaperWalkthroughQuiz(question: "Which column is tested in cells?", answer: "Validation.", kind: .find, targetPanel: "validation"))
        find.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        var byLetter = step(.quiz, title: "Find by letter", quiz: PaperWalkthroughQuiz(question: "Which column?", answer: "Design.", kind: .find, targetPanel: "N"))
        byLetter.anchor = PaperWalkthroughAnchor(figureLabel: "Figure 3")
        let outcome = try PaperWalkthroughValidation.walkthrough(
            title: "Funnel", steps: leftToRight + [find, byLetter], sourceID: "src", sourceSHA256: "sha",
            figures: [Self.funnel], text: Self.funnelText, author: .assistant
        )
        #expect(!outcome.warnings.contains { $0.contains("walked in order") })
        #expect(!outcome.warnings.contains { $0.contains("unaddressed") })
        #expect(outcome.walkthrough.steps.map(\.anchor?.panelLabel).prefix(4).map { $0 ?? "" } == Self.funnelNames)
        #expect(outcome.walkthrough.steps[4].quiz?.kind == .find)
        #expect(outcome.walkthrough.steps[4].quiz?.targetPanel == "VALIDATION")
        // "N" is not a panel of this figure, however DESIGN used to be read.
        #expect(outcome.walkthrough.steps[5].quiz?.kind == .recall)

        // No letter-shaped caption, note or citation is made up for a name.
        #expect(PaperFigureCaptionTitle.panelCaption(for: "DESIGN", in: "Figure 3: The funnel. (N) Not a panel.") == nil)
        #expect(WalkthroughStepPanelNote.note(for: "DESIGN", inBody: "Look at panel n. It is not this one.") == nil)
        let text = "Unrelated counts are shown in Fig. 3n of the supplement here. The funnel in Figure 3 narrows all of biology down to validation."
        #expect(PaperFigureMention.sentence(citing: "Figure 3", panel: "DESIGN", in: text)?.hasPrefix("The funnel in Figure 3") == true)
        #expect(PaperFigureMention.sentence(citing: "Figure 3", panel: "n", in: text)?.hasPrefix("Unrelated counts") == true)

        // The grade names the column as printed.
        let quiz = try #require(outcome.walkthrough.steps[4].quiz)
        #expect(WalkthroughStepComposer.findRecord(quiz: quiz, picked: "DESIGN", correct: false)
                .hasPrefix("**Not panel DESIGN — it's panel VALIDATION.**"))
    }

    @Test("The resolver keeps each named column's own rectangle, in the figure's order, and a pick by name finds it")
    func namedPanelsInTheResolver() async throws {
        let record = PaperFigureRecord(id: "fig-3", sourceID: "s", figureLabel: "Figure 3", pageIndex: 5,
                                       caption: "Figure 3: The search space and funnel.", analysis: Self.funnelAnalysis)
        let resolver = WalkthroughAnchorResolver(figures: [record], pdfPath: nil)
        for panel in Self.funnelPanels {
            let resolved = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: panel.label)))
            #expect(resolved.panel == panel.label)
            #expect(resolved.panelLabels == Self.funnelNames)
            guard case .figure(let pageIndex, let rect, _, _) = resolved.target else {
                Issue.record("expected a figure target"); return
            }
            #expect(pageIndex == 5)
            #expect(rect == panel.rect, "\(panel.label)")
        }
        // A pick by name in any case, over a step anchored to another column.
        let picked = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "DESIGN"), panel: "validation"))
        #expect(picked.panel == "VALIDATION")
        // A letter that used to stand for DESIGN is not a panel.
        let byLetter = try #require(await resolver.resolve(PaperWalkthroughAnchor(figureLabel: "Figure 3", panelLabel: "N")))
        #expect(byLetter.panel == nil)
        guard case .figure(_, let whole, _, _) = byLetter.target else { Issue.record("expected a figure target"); return }
        #expect(whole == Self.funnelAnalysis.figureRect)
    }

    @Test("inspect_paper_figure and the phone deck find a named column by name, not by its last letter")
    func namedPanelsInTheToolsAndThePhone() throws {
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "DESIGN", in: Self.funnelAnalysis)?.id == "fig-3-panel-3")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "design", in: Self.funnelAnalysis)?.id == "fig-3-panel-3")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "Figure 3 VALIDATION", in: Self.funnelAnalysis)?.id == "fig-3-panel-4")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "all of  biology", in: Self.funnelAnalysis)?.id == "fig-3-panel-1")
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "N", in: Self.funnelAnalysis) == nil)

        let figure = SyncedPaperFigure(id: "fig-3", sourceID: "s", figureLabel: "Figure 3", pageIndex: 5,
                                       caption: "Figure 3: The search space and funnel.", analysis: Self.funnelAnalysis)
        let design = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 3", panel: "Design", in: [figure]))
        #expect(design.panel?.id == "fig-3-panel-3")
        let validation = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 3", panel: "VALIDATION", in: [figure]))
        #expect(validation.panel?.id == "fig-3-panel-4")
        #expect(MobileWalkthroughDeck.panelLetters(of: design) == Self.funnelNames)

        // A lettered figure's chips are the lower-case letters they always were.
        let lettered = PaperFigureAnalysis(
            summary: "s", visualEvidence: [], figureRect: nil,
            panels: [
                PaperFigurePanel(id: "pa", label: "(A)", explanation: "", rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
                PaperFigurePanel(id: "pb", label: "b", explanation: "", rect: nil),
                PaperFigurePanel(id: "pa2", label: "a", explanation: "", rect: nil),
            ],
            analysisVersion: PaperFigureAnalysis.currentVersion, generatedAt: Date(timeIntervalSince1970: 0)
        )
        let letteredFigure = SyncedPaperFigure(id: "f2", sourceID: "s", figureLabel: "Figure 2", pageIndex: 1, caption: "Figure 2.", analysis: lettered)
        let panelA = try #require(MobileWalkthroughDeck.figure(labelled: "Figure 2", panel: "Figure 2a", in: [letteredFigure]))
        #expect(panelA.panel?.id == "pa")
        #expect(MobileWalkthroughDeck.panelLetters(of: panelA) == ["a", "b"])
    }
}
