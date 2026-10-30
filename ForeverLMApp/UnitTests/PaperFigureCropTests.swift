import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import ForeverLM

/// A synthetic journal page: one solid "figure" block, its printed caption
/// beneath it, and body prose below that.
///
/// The geometry is stated in points from the bottom-left, the way PDF pages
/// measure, and the expectations below convert once so a reader can check them
/// against the numbers here.
private enum SyntheticPaperPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let figureBlock = CGRect(x: 100, y: 500, width: 400, height: 200)
    static let captionBaseline: CGFloat = 470
    static let captionLine = "Figure 1 | A synthetic block, drawn for the crop tests."

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static var figureTop: Double { (mediaBox.maxY - figureBlock.maxY) / mediaBox.height }
    static var figureBottom: Double { (mediaBox.maxY - figureBlock.minY) / mediaBox.height }
    static var figureLeft: Double { figureBlock.minX / mediaBox.width }
    static var figureRight: Double { figureBlock.maxX / mediaBox.width }
    static var captionTop: Double { (mediaBox.maxY - captionBaseline - 12) / mediaBox.height }

    static func write(to url: URL) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)

        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(figureBlock)

        draw(captionLine, at: CGPoint(x: 100, y: captionBaseline), size: 11, in: context)
        // Body prose under the caption. It is long and dense on purpose: it is
        // the thing a crop must not swallow.
        for (index, line) in [
            "The block above is not the subject of this paragraph, which continues",
            "for several lines so that the region below the caption carries enough",
            "ink to be mistaken for part of the figure by anything less careful.",
        ].enumerated() {
            draw(line, at: CGPoint(x: 100, y: 430 - CGFloat(index) * 16), size: 11, in: context)
        }

        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

@Suite("Paper Figure Crop")
struct PaperFigureCropTests {

    private func withSyntheticPage(
        _ body: (PDFPage, PaperFigureRectRefiner.PageInkMask) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureCropTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try SyntheticPaperPage.write(to: url)

        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        try body(page, mask)
    }

    private func refined(
        _ rect: PaperFigureRect?,
        page: PDFPage,
        mask: PaperFigureRectRefiner.PageInkMask,
        sharesPage: Bool = false,
        allowsGrowth: Bool = true
    ) -> PaperFigureRect? {
        PaperFigureRectRefiner.refined(
            rect,
            captionBounds: PaperFigureRectRefiner.captionBounds(
                of: SyntheticPaperPage.captionLine,
                on: page
            ),
            pageBounds: page.bounds(for: .mediaBox),
            with: mask,
            sharesPageWithOtherFigures: sharesPage,
            allowsGrowth: allowsGrowth
        )
    }

    @Test("The caption is found by selection, on the line it is printed on")
    func captionAnchorLandsOnTheCaptionLine() throws {
        try withSyntheticPage { page, _ in
            let bounds = try #require(
                PaperFigureRectRefiner.captionBounds(of: SyntheticPaperPage.captionLine, on: page)
            )
            // The caption sits below the figure block and above the body prose.
            #expect(bounds.maxY < SyntheticPaperPage.figureBlock.minY)
            #expect(bounds.minY > 440)
            #expect(bounds.minX < 110)
        }
    }

    @Test("With no rectangle from the model, the page still yields the figure alone")
    func nilRectResolvesToTheFigureBlock() throws {
        try withSyntheticPage { page, mask in
            let rect = try #require(refined(nil, page: page, mask: mask))
            #expect(abs(rect.x - SyntheticPaperPage.figureLeft) < 0.02)
            #expect(abs(rect.y - SyntheticPaperPage.figureTop) < 0.02)
            #expect(abs((rect.x + rect.width) - SyntheticPaperPage.figureRight) < 0.02)
            // The whole point: the caption and the prose under it stay out.
            #expect(rect.y + rect.height < SyntheticPaperPage.captionTop)
        }
    }

    @Test("The page's crop wins over a stored rectangle that is wrong")
    func displayedCropPrefersThePageToTheStoredRectangle() throws {
        try withSyntheticPage { page, mask in
            // The stored kind of mistake: a full-width strip across the top of
            // the page (Nature, Fig. 1 of the mtDNA-in-blood paper, 2026-10-23).
            let wrong = PaperFigureRect(x: 0.05, y: 0.12, width: 0.9, height: 0.1)
            let shown = try #require(PaperFigureRectRefiner.displayedFigureCrop(
                forCaption: SyntheticPaperPage.captionLine,
                measured: wrong,
                on: page,
                mask: mask
            ))
            let fromPage = try #require(PaperFigureRectRefiner.figureCrop(
                forCaption: SyntheticPaperPage.captionLine,
                on: page,
                mask: mask
            ))
            #expect(shown == fromPage)
            #expect(shown != wrong)
            #expect(abs(shown.x - SyntheticPaperPage.figureLeft) < 0.02)
        }
    }

    @Test("A stored rectangle stands in only where the page yields no crop")
    func displayedCropFallsBackToTheStoredRectangle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureCropTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("blank.pdf")
        var box = SyntheticPaperPage.mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let page = try #require(PDFDocument(url: url)?.page(at: 0))

        let caption = "Figure 1 | A caption this blank page does not print."
        #expect(PaperFigureRectRefiner.figureCrop(forCaption: caption, on: page) == nil)
        let measured = PaperFigureRect(x: 0.2, y: 0.2, width: 0.5, height: 0.3)
        #expect(PaperFigureRectRefiner.displayedFigureCrop(forCaption: caption, measured: measured, on: page) == measured)
        let invalid = PaperFigureRect(x: 0.6, y: 0.6, width: 0.9, height: 0.9)
        #expect(PaperFigureRectRefiner.displayedFigureCrop(forCaption: caption, measured: invalid, on: page) == nil)
        #expect(PaperFigureRectRefiner.displayedFigureCrop(forCaption: caption, measured: nil, on: page) == nil)
    }

    @Test("Slack around the figure is trimmed away")
    func slackIsTrimmed() throws {
        try withSyntheticPage { page, mask in
            let generous = PaperFigureRect(x: 0.02, y: 0.02, width: 0.96, height: 0.5)
            let rect = try #require(refined(generous, page: page, mask: mask))
            #expect(rect.x > 0.12)
            #expect(rect.x + rect.width < 0.87)
            #expect(rect.y > 0.08)
            #expect(rect.width < 0.75)
        }
    }

    @Test("A rectangle that slices the only figure on the page is repaired")
    func slicedSoleFigureIsRecovered() throws {
        try withSyntheticPage { page, mask in
            // Half the figure, which is what an estimate looks like when it is
            // wrong in the direction that matters.
            let sliced = PaperFigureRect(x: 0.16, y: 0.11, width: 0.20, height: 0.26)
            let rect = try #require(refined(sliced, page: page, mask: mask))
            #expect(abs((rect.x + rect.width) - SyntheticPaperPage.figureRight) < 0.02)
            #expect(rect.width > 0.6)
        }
    }

    @Test("A sliced rectangle is left alone when the page holds other figures")
    func slicedRectSurvivesWhenFiguresShareAPage() throws {
        try withSyntheticPage { page, mask in
            let sliced = PaperFigureRect(x: 0.16, y: 0.11, width: 0.20, height: 0.26)
            let rect = try #require(refined(sliced, page: page, mask: mask, sharesPage: true))
            // Growth is bounded and the fallback is off, so this stays a crop of
            // the part that was asked for rather than becoming the whole block.
            #expect(rect.width < 0.6)
        }
    }

    @Test("A panel is only ever trimmed, never grown")
    func panelRefinementNeverGrows() throws {
        try withSyntheticPage { page, mask in
            let panel = PaperFigureRect(x: 0.20, y: 0.15, width: 0.20, height: 0.15)
            let rect = try #require(
                refined(panel, page: page, mask: mask, sharesPage: true, allowsGrowth: false)
            )
            #expect(rect.x >= panel.x - 0.02)
            #expect(rect.x + rect.width <= panel.x + panel.width + 0.02)
            #expect(rect.y + rect.height <= panel.y + panel.height + 0.02)
        }
    }

    @Test("Every refined rectangle is a valid one")
    func refinementAlwaysProducesValidGeometry() throws {
        try withSyntheticPage { page, mask in
            let inputs: [PaperFigureRect?] = [
                nil,
                PaperFigureRect(x: 0, y: 0, width: 1, height: 1),
                PaperFigureRect(x: 0.9, y: 0.9, width: 0.09, height: 0.09),
                PaperFigureRect(x: 0.16, y: 0.11, width: 0.66, height: 0.26),
            ]
            for input in inputs {
                guard let rect = refined(input, page: page, mask: mask) else { continue }
                #expect(rect.isValid)
            }
        }
    }

    @Test("The measured page carries a grid the plain render does not")
    func measuredPageIsRuled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureGridTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try SyntheticPaperPage.write(to: url)
        let document = try #require(PDFDocument(url: url))

        let plain = try #require(PDFTextExtractor.pageJPEGData(from: document, pageIndex: 0))
        let measured = try #require(PDFTextExtractor.measuredPageJPEGData(from: document, pageIndex: 0))
        #expect(!measured.isEmpty)
        #expect(measured != plain)

        // The grid is the model's aid and must not become the crop's geometry:
        // the mask is taken from the page, so a ruled page still crops to the
        // block rather than to the outermost gridlines.
        let page = try #require(document.page(at: 0))
        let mask = try #require(PaperFigureRectRefiner.mask(for: page))
        let rect = try #require(refined(nil, page: page, mask: mask))
        #expect(rect.width < 0.75)
    }

    @Test("Panel letters in running prose are not indexed as figures")
    func inTextFigureReferencesAreNotCaptions() {
        let text = """
        Fig. 1 | Cytosolic mtRNA leakage is a feature of senescent cells.
        Fig. 2a, b) show the same effect in replicative senescence.
        Figure 11h shows the quantification for the western blots.
        Figure 1c, d of the companion paper report the opposite.
        Fig. 8k
        Figure 3B | An uppercase panel that really is its own caption.
        FIGURE S2. Sensitivity analysis for the alternate assumptions.
        """
        let labels = PDFTextExtractor.figureCaptionRecords(in: text).map(\.label)
        #expect(labels == ["Figure 1", "Figure 3B", "Figure S2"])
    }
}

@Suite("Paper Figure Single-Figure Analysis")
struct PaperFigureSingleAnalysisTests {

    private func analysis(summary: String, rect: PaperFigureRect?) -> PaperFigureAnalysis {
        PaperFigureAnalysis(
            summary: summary,
            visualEvidence: [],
            figureRect: rect,
            panels: [],
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }

    private func indexedStore() throws -> (KnowledgeStore, StudioArticle, [PaperFigureRecord]) {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(url: "https://example.com/one-figure-at-a-time", title: "Per-Figure Paper")
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.saveSource(article)
        let figures = (1...3).map { index in
            PaperFigureRecord(
                id: PaperFigureIndexContract.figureID(
                    sourceID: article.id,
                    figureLabel: "Figure \(index)",
                    pageIndex: index
                ),
                sourceID: article.id,
                figureLabel: "Figure \(index)",
                pageIndex: index,
                caption: "Figure \(index) | Something measured.",
                analysis: nil
            )
        }
        try store.replacePaperFigureIndex(
            sourceID: article.id,
            pdfPath: "Papers/per-figure.pdf",
            pageCount: 12,
            figures: figures,
            indexVersion: PaperFigureIndexContract.currentVersion
        )
        return (store, article, figures)
    }

    @Test("Explaining one figure keeps the rest of the paper's index untouched")
    func singleFigureAnalysisIsIsolated() throws {
        let (store, article, figures) = try indexedStore()
        let target = figures[1]

        let updated = try store.updatePaperFigureAnalysis(
            sourceID: article.id,
            figureID: target.id,
            analysis: analysis(
                summary: "The treated series separates after week four.",
                rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4)
            )
        )
        #expect(updated)

        let stored = try store.paperFigures(sourceID: article.id)
        #expect(stored.count == 3)
        let explained = try #require(stored.first { $0.id == target.id })
        #expect(explained.analysis?.summary == "The treated series separates after week four.")
        #expect(explained.analysis?.figureRect?.width == 0.8)
        // The two nobody asked about are still structure only — which is the
        // whole saving.
        #expect(stored.filter { $0.analysis == nil }.count == 2)
        // Structure is intact: labels, pages and captions are as indexed.
        #expect(stored.map(\.figureLabel) == ["Figure 1", "Figure 2", "Figure 3"])
        #expect(stored.map(\.pageIndex) == [1, 2, 3])
    }

    @Test("A figure's new explanation republishes its source")
    func singleFigureAnalysisMarksTheSourceChanged() throws {
        let (store, article, figures) = try indexedStore()
        let before = try store.pendingSyncChangeCount()

        _ = try store.updatePaperFigureAnalysis(
            sourceID: article.id,
            figureID: figures[0].id,
            analysis: analysis(summary: "A clear separation.", rect: nil)
        )

        // The figures travel inside the source record, so a rect that improved
        // here is only better on the phone if the record is republished.
        #expect(try store.pendingSyncChangeCount() >= before)
        let pending = try store.pendingSyncItemSummaries(limit: 20)
        #expect(pending.contains { $0.title.contains("Per-Figure Paper") })
    }

    @Test("An analysis for a figure that was never indexed is refused")
    func unknownFigureIsNotInvented() throws {
        let (store, article, _) = try indexedStore()
        let updated = try store.updatePaperFigureAnalysis(
            sourceID: article.id,
            figureID: "fig_not_a_real_figure",
            analysis: analysis(summary: "Nothing.", rect: nil)
        )
        #expect(!updated)
        #expect(try store.paperFigures(sourceID: article.id).allSatisfy { $0.analysis == nil })
    }

    @Test("A continued caption never wins the label over the page holding the figure")
    func earlierPageWinsADuplicateLabel() {
        // Nature prints "Fig. 3 | See next page for caption." under the figure
        // and repeats "Fig. 3 | …" on the caption page that follows. Both are
        // real caption lines; only the first has the figure.
        let figures = [4, 5].map { page in
            PaperFigureRecord(
                id: "fig-\(page)",
                sourceID: "src",
                figureLabel: "Figure 3",
                pageIndex: page,
                caption: "Fig. 3 | Something.",
                analysis: nil
            )
        }
        let match = PaperFigureIndexer.figure(labelled: "Fig. 3", in: figures)
        #expect(match?.pageIndex == 4)
        #expect(PaperFigureIndexer.figure(labelled: "Figure 3", in: figures)?.pageIndex == 4)
        #expect(PaperFigureIndexer.figure(labelled: "Figure 9", in: figures) == nil)
    }
}

@Suite("Paper Figure Tool Selection")
struct PaperFigureToolSelectionTests {

    private func syntheticPaper() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureToolTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        try SyntheticPaperPage.write(to: url)
        return (root, url)
    }

    private func record(caption: String, label: String, page: Int) -> PaperFigureRecord {
        PaperFigureRecord(
            id: "fig-\(label)-\(page)",
            sourceID: "src",
            figureLabel: label,
            pageIndex: page,
            caption: caption,
            analysis: nil
        )
    }

    @Test("A figure with no vision analysis is still cropped to its figure")
    func unexplainedFigureIsStillCropped() throws {
        let (root, url) = try syntheticPaper()
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try SourceImageCatalog.entries(
            sourceID: "src", filePath: url.path, query: nil, page: 1
        )
        #expect(entries.first?.reference.crop == nil)

        let cropped = ReviewSessionManager.croppedToFigures(
            entries,
            sourceID: "src",
            filePath: url.path,
            figures: [record(caption: SyntheticPaperPage.captionLine, label: "Figure 1", page: 0)],
            query: ""
        )
        let crop = try #require(cropped.first?.reference.crop, "nothing paid for, nothing cropped")
        #expect(crop.isValid)
        // The caption and the prose beneath it are outside the crop.
        #expect(crop.y + crop.height < SyntheticPaperPage.captionTop)
        #expect(crop.width < 0.8)
    }

    @Test("Asking for a figure returns the figure, not every page that names it")
    func figureQuerySkipsPagesThatMerelyMentionIt() throws {
        let (root, url) = try syntheticPaper()
        defer { try? FileManager.default.removeItem(at: root) }

        // What a PDF text search hands back for "Figure 1" on a paper that also
        // discusses Figure 1 in its prose: the discussion pages, in page order,
        // with the figure itself somewhere in the list.
        let discussion = SourceImageEntry(
            reference: SourceImageReference(sourceID: "src", location: .page(4)),
            caption: "…as shown in Figure 1, the effect persists…",
            context: ""
        )
        let theFigure = SourceImageEntry(
            reference: SourceImageReference(sourceID: "src", location: .page(1)),
            caption: SyntheticPaperPage.captionLine,
            context: ""
        )

        let cropped = ReviewSessionManager.croppedToFigures(
            [discussion, theFigure],
            sourceID: "src",
            filePath: url.path,
            figures: [record(caption: SyntheticPaperPage.captionLine, label: "Figure 1", page: 0)],
            query: "Figure 1"
        )

        #expect(cropped.count == 1)
        let only = try #require(cropped.first)
        #expect(only.reference.location == .page(1))
        #expect(only.reference.crop != nil)
    }

    @Test("A caption continued onto the next page never stands in for the figure")
    func continuedCaptionLosesToTheFigurePage() throws {
        let (root, url) = try syntheticPaper()
        defer { try? FileManager.default.removeItem(at: root) }

        let cropped = ReviewSessionManager.croppedToFigures(
            [SourceImageEntry(
                reference: SourceImageReference(sourceID: "src", location: .page(9)),
                caption: "",
                context: ""
            )],
            sourceID: "src",
            filePath: url.path,
            figures: [
                record(caption: SyntheticPaperPage.captionLine, label: "Figure 1", page: 0),
                record(caption: "Figure 1 | continued from the previous page.", label: "Figure 1", page: 1),
            ],
            query: "Figure 1"
        )
        #expect(cropped.count == 1)
        #expect(cropped.first?.reference.location == .page(1))
    }

    @Test("A source with no figure index is handed back untouched")
    func noIndexMeansNoChange() throws {
        let (root, url) = try syntheticPaper()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try SourceImageCatalog.entries(
            sourceID: "src", filePath: url.path, query: nil, page: 1
        )
        let cropped = ReviewSessionManager.croppedToFigures(
            entries, sourceID: "src", filePath: url.path, figures: [], query: "Figure 1"
        )
        #expect(cropped == entries)
    }
}

/// A two-page synthetic Nature layout: a figure that fills the first page above
/// two paragraphs of body text, with its caption opening the second page under
/// the running head. Nothing on the first page names the figure.
private enum SyntheticFullPageFigure {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let figureBlock = CGRect(x: 72, y: 330, width: 468, height: 390)
    static let captionLine = "Figure 1 | A block that fills the page before this one, drawn for the tests."
    static let runningHead = "Article        https://doi.org/10.1000/synthetic-paper-figure-tests-running-head-line"
    static let proseLine = "This paragraph is body text set across the full measure of the page, dense enough that a strip of the page holding one of its lines is prose."

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static var figureTop: Double { (mediaBox.maxY - figureBlock.maxY) / mediaBox.height }
    static var figureBottom: Double { (mediaBox.maxY - figureBlock.minY) / mediaBox.height }
    /// The top of the body text under the figure, normalized.
    static var proseTop: Double { (mediaBox.maxY - 300) / mediaBox.height }

    /// `figurePageHoldsFigure` false draws prose from head to foot on the first
    /// page instead of a figure — the page a caption must never be moved to.
    static func write(to url: URL, figurePageHoldsFigure: Bool = true) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))

        context.beginPDFPage(nil)
        draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
        if figurePageHoldsFigure {
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 1, alpha: 1)
            draw("a", at: CGPoint(x: 80, y: 700), size: 12, in: context)
            draw("b", at: CGPoint(x: 320, y: 700), size: 12, in: context)
            draw("Time (min)", at: CGPoint(x: 260, y: 340), size: 9, in: context)
            context.setFillColor(gray: 0, alpha: 1)
            for index in 0..<6 {
                draw(proseLine, at: CGPoint(x: 72, y: 290 - CGFloat(index) * 14), size: 10, in: context)
            }
        } else {
            for index in 0..<40 {
                draw(proseLine, at: CGPoint(x: 72, y: 740 - CGFloat(index) * 14), size: 10, in: context)
            }
        }
        draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
        draw(captionLine, at: CGPoint(x: 72, y: 735), size: 11, in: context)
        for index in 0..<6 {
            draw(proseLine, at: CGPoint(x: 72, y: 700 - CGFloat(index) * 14), size: 10, in: context)
        }
        draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

@Suite("Paper Figure With Its Caption On The Following Page")
struct PaperFigureFollowingPageCaptionTests {

    private func withDocument(
        figurePageHoldsFigure: Bool = true,
        _ body: (PDFDocument) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureFollowingPageCaptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try SyntheticFullPageFigure.write(to: url, figurePageHoldsFigure: figurePageHoldsFigure)
        let document = try #require(PDFDocument(url: url))
        try withExtendedLifetime(document) { try body(document) }
    }

    @Test("A caption that opens a page belongs to the figure filling the page before it")
    func leadingCaptionIsIndexedOnThePageBefore() throws {
        try withDocument { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1"])
            #expect(indexed.map(\.pageIndex) == [0])
            #expect(indexed.first?.caption == SyntheticFullPageFigure.captionLine)
        }
    }

    @Test("A caption opening a page after a page of prose stays on its own page")
    func leadingCaptionAfterProseStaysPut() throws {
        try withDocument(figurePageHoldsFigure: false) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.pageIndex) == [1])
            let first = try #require(document.page(at: 0))
            #expect(PaperFigureRectRefiner.uncaptionedFigureBand(on: first) == nil)
        }
    }

    @Test("The figure page is cropped to the figure, not the prose beneath it or the head above")
    func figurePageCropsToTheFigure() throws {
        try withDocument { document in
            let page = try #require(document.page(at: 0))
            let next = try #require(document.page(at: 1))
            #expect(PaperFigureRectRefiner.captionLeadsPage(SyntheticFullPageFigure.captionLine, on: next))
            #expect(PaperFigureRectRefiner.captionBounds(of: SyntheticFullPageFigure.captionLine, on: page) == nil)

            let crop = try #require(PaperFigureRectRefiner.figureCrop(
                forCaption: SyntheticFullPageFigure.captionLine,
                on: page
            ))
            #expect(abs(crop.y - SyntheticFullPageFigure.figureTop) < 0.02)
            #expect(abs(crop.y + crop.height - SyntheticFullPageFigure.figureBottom) < 0.02)
            #expect(crop.y + crop.height < SyntheticFullPageFigure.proseTop)
            #expect(abs(crop.x - 72.0 / 612.0) < 0.02)
            #expect(abs(crop.x + crop.width - 540.0 / 612.0) < 0.02)
        }
    }
}

/// EMBO's layout, after the cristae paper (2026-09-28): a figure's legend is
/// set on the page before or after it, and the figure's own page prints only
/// its label. Page 1 closes with Figure 1's legend under two paragraphs; page
/// 2 is Figure 1 over "Figure 1."; page 3 is Figure 2 over "Figure 2."; page 4
/// opens with Figure 2's legend behind an arrow pointing back at it. The
/// running head is EMBO's too: two short pieces on one baseline.
private enum SyntheticLegendElsewhere {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let figureBlock = CGRect(x: 72, y: 110, width: 468, height: 600)
    static let runningHead = "The Synthetic Journal        Synthetic Author et al — running head across the page"
    static let proseLine = "This paragraph is body text set across the full measure of the page, dense enough that a strip of the page holding one of its lines is prose."
    static let firstLegend = "Figure 1. A block drawn on the page after this one, for the tests."
    static let secondLegend = "Figure 2. A block drawn on the page before this one, for the tests."

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static var figureTop: Double { (mediaBox.maxY - figureBlock.maxY) / mediaBox.height }
    static var figureBottom: Double { (mediaBox.maxY - figureBlock.minY) / mediaBox.height }

    static func write(to url: URL) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))

        context.beginPDFPage(nil)
        draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
        for index in 0..<30 {
            draw(proseLine, at: CGPoint(x: 72, y: 730 - CGFloat(index) * 14), size: 10, in: context)
        }
        draw(firstLegend, at: CGPoint(x: 72, y: 250), size: 9, in: context)
        draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
        context.endPDFPage()

        for label in ["Figure 1.", "Figure 2."] {
            context.beginPDFPage(nil)
            draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 0, alpha: 1)
            draw(label, at: CGPoint(x: 72, y: 80), size: 9, in: context)
            draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
            context.endPDFPage()
        }

        context.beginPDFPage(nil)
        draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
        draw("\u{25C0} " + secondLegend, at: CGPoint(x: 60, y: 735), size: 9, in: context)
        for index in 0..<30 {
            draw(proseLine, at: CGPoint(x: 72, y: 690 - CGFloat(index) * 14), size: 10, in: context)
        }
        draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
        context.endPDFPage()
        context.closePDF()
    }

    /// A title page, two figures that each fill a page, then one page
    /// carrying both their legends between paragraphs, and no label printed
    /// with either figure: the legends are one and two pages from their
    /// figures.
    static func writeLegendsTogether(to url: URL) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw("A synthetic paper whose legends are printed together", at: CGPoint(x: 72, y: 700), size: 18, in: context)
        for index in 0..<30 {
            draw(proseLine, at: CGPoint(x: 72, y: 640 - CGFloat(index) * 14), size: 10, in: context)
        }
        context.endPDFPage()
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 0, alpha: 1)
            draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
            context.endPDFPage()
        }
        context.beginPDFPage(nil)
        draw(runningHead, at: CGPoint(x: 72, y: 760), size: 9, in: context)
        draw("Figure 1. The first block, two pages before this legend.", at: CGPoint(x: 72, y: 735), size: 9, in: context)
        for index in 0..<12 {
            draw(proseLine, at: CGPoint(x: 72, y: 700 - CGFloat(index) * 14), size: 10, in: context)
        }
        draw("Figure 2. The second block, on the page before this legend.", at: CGPoint(x: 72, y: 500), size: 9, in: context)
        for index in 0..<12 {
            draw(proseLine, at: CGPoint(x: 72, y: 470 - CGFloat(index) * 14), size: 10, in: context)
        }
        draw("Synthetic Journal | 2026", at: CGPoint(x: 72, y: 30), size: 8, in: context)
        context.endPDFPage()
        context.closePDF()
    }

    /// A preprint's layout: a title page, a page of `legends` legends and
    /// nothing else, five pages of references, then one page a figure with
    /// nothing printed on it. The figures are six or more pages from their
    /// legends. With `otherFigureBetween`, a page carrying Figure 9 over its
    /// label sits between the references and those figure pages.
    static func writeLegendsSection(to url: URL, legends: Int, otherFigureBetween: Bool = false) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw("A synthetic preprint whose legends are listed together", at: CGPoint(x: 72, y: 700), size: 18, in: context)
        for index in 0..<30 {
            draw(proseLine, at: CGPoint(x: 72, y: 640 - CGFloat(index) * 14), size: 10, in: context)
        }
        context.endPDFPage()
        context.beginPDFPage(nil)
        for number in 1...legends {
            let top = 740 - CGFloat(number - 1) * 60
            draw("Figure \(number). The block drawn for figure \(number), pages after this legend.", at: CGPoint(x: 72, y: top), size: 9, in: context)
            draw("(A) The block, drawn solid. (B) The same block, for the tests.", at: CGPoint(x: 72, y: top - 11), size: 9, in: context)
        }
        context.endPDFPage()
        for _ in 0..<5 {
            context.beginPDFPage(nil)
            for index in 0..<45 {
                draw(proseLine, at: CGPoint(x: 72, y: 740 - CGFloat(index) * 14), size: 10, in: context)
            }
            context.endPDFPage()
        }
        if otherFigureBetween {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 0, alpha: 1)
            draw("Figure 9.", at: CGPoint(x: 72, y: 80), size: 9, in: context)
            context.endPDFPage()
        }
        for _ in 0..<legends {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 0, alpha: 1)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// An eLife paper's layout: two captions set into pages of body text,
    /// pages 2 and 5, with figures too faint to count as figures beside them,
    /// and two pages of figures with nothing printed on them at the end.
    static func writeCaptionsInBodyText(to url: URL) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 0..<8 {
            context.beginPDFPage(nil)
            for index in 0..<45 {
                draw(proseLine, at: CGPoint(x: 72, y: 740 - CGFloat(index) * 14), size: 10, in: context)
            }
            if page == 1 || page == 4 {
                let number = page == 1 ? 1 : 2
                draw("Figure \(number). A drawing too faint to measure, beside this caption.", at: CGPoint(x: 72, y: 90), size: 9, in: context)
            }
            context.endPDFPage()
        }
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.1, alpha: 1)
            context.fill(figureBlock)
            context.setFillColor(gray: 0, alpha: 1)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

@Suite("Paper Figure Whose Legend Is On Another Page")
struct PaperFigureLegendElsewhereTests {

    private func withDocument(
        _ write: (URL) throws -> Void,
        _ body: (PDFDocument) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureLegendElsewhereTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try write(url)
        let document = try #require(PDFDocument(url: url))
        try withExtendedLifetime(document) { try body(document) }
    }

    @Test("A figure is indexed on the page that prints its label alone, with its legend's words")
    func labelPrintedAloneMarksTheFigurePage() throws {
        try withDocument(SyntheticLegendElsewhere.write) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1", "Figure 2"])
            #expect(indexed.map(\.pageIndex) == [1, 2])
            #expect(indexed.map(\.caption) == [SyntheticLegendElsewhere.firstLegend, SyntheticLegendElsewhere.secondLegend])
        }
    }

    @Test("A legend behind an arrow is still a legend, stored from its label on")
    func arrowBeforeALegendIsPassedOver() throws {
        try withDocument(SyntheticLegendElsewhere.write) { document in
            let page = try #require(document.page(at: 3))
            let records = PDFTextExtractor.figureCaptionRecords(on: page)
            #expect(records.map(\.label) == ["Figure 2"])
            #expect(records.first?.caption == SyntheticLegendElsewhere.secondLegend)
        }
        #expect(PaperFigureCaptionTitle.label(openingLine: "\u{25C0} Figure 2. The dye.") == "Figure 2")
        #expect(PaperFigureCaptionTitle.label(openingLine: "\u{25B8}") == nil)
        #expect(PaperFigureCaptionTitle.isStub("Figure 1."))
        #expect(PaperFigureCaptionTitle.isStub("Fig. 3 | See next page for caption."))
        #expect(!PaperFigureCaptionTitle.isStub(SyntheticLegendElsewhere.firstLegend))
    }

    @Test("A page of prose and a legend shows no figure; a figure's page does")
    func figureInkTellsAFigurePageFromProse() throws {
        try withDocument(SyntheticLegendElsewhere.write) { document in
            let prose = try #require(document.page(at: 0))
            let figure = try #require(document.page(at: 1))
            #expect(!PaperFigureRectRefiner.showsFigure(prose))
            #expect(PaperFigureRectRefiner.showsFigure(figure))
        }
    }

    @Test("The figure's page crops to the figure above its label, words taken from another page")
    func figurePageCropsAboveItsLabel() throws {
        try withDocument(SyntheticLegendElsewhere.write) { document in
            let page = try #require(document.page(at: 1))
            #expect(PaperFigureRectRefiner.captionBounds(of: SyntheticLegendElsewhere.firstLegend, on: page) == nil)
            let anchor = try #require(PaperFigureRectRefiner.captionAnchor(of: SyntheticLegendElsewhere.firstLegend, on: page))
            #expect(anchor.maxY < SyntheticLegendElsewhere.figureBlock.minY)

            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticLegendElsewhere.firstLegend, on: page))
            #expect(abs(crop.y - SyntheticLegendElsewhere.figureTop) < 0.02)
            #expect(abs(crop.y + crop.height - SyntheticLegendElsewhere.figureBottom) < 0.02)
        }
    }

    @Test("Legends printed together pages after their figures keep their figures in order")
    func legendsTogetherPairInOrder() throws {
        try withDocument(SyntheticLegendElsewhere.writeLegendsTogether) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1", "Figure 2"])
            #expect(indexed.map(\.pageIndex) == [1, 2])
        }
    }

    @Test("A legends section is paired with the figure pages that follow it, however far on")
    func legendsSectionPairsForward() throws {
        try withDocument({ try SyntheticLegendElsewhere.writeLegendsSection(to: $0, legends: 3) }) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1", "Figure 2", "Figure 3"])
            #expect(indexed.map(\.pageIndex) == [7, 8, 9])
        }
    }

    @Test("A legends section never reaches past a page another figure holds")
    func legendsSectionStopsAtAnotherFigure() throws {
        try withDocument({
            try SyntheticLegendElsewhere.writeLegendsSection(to: $0, legends: 3, otherFigureBetween: true)
        }) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1", "Figure 2", "Figure 3", "Figure 9"])
            #expect(indexed.map(\.pageIndex) == [1, 1, 1, 7])
        }
    }

    @Test("Captions set apart in the body text are no legends section")
    func captionsInBodyTextStayPut() throws {
        try withDocument(SyntheticLegendElsewhere.writeCaptionsInBodyText) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.pageIndex) == [1, 4])
        }
    }

    @Test("A lone legend is never sent to a caption-free figure page far away")
    func loneLegendStaysPut() throws {
        try withDocument({ try SyntheticLegendElsewhere.writeLegendsSection(to: $0, legends: 1) }) { document in
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.pageIndex) == [1])
        }
    }
}

@Suite("Paper Figure Prose-Free Band")
struct PaperFigureProseFreeBandTests {

    /// Body text from the head of the page to its foot, broken once by a
    /// paragraph gap of `gap` extra points.
    private func proseOnlyPage(paragraphGap gap: CGFloat) throws -> (PDFDocument, PDFPage) {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = "This paragraph is body text set across the full measure of the page, dense enough that a strip of the page holding one of its lines is prose."
        var y: CGFloat = 780
        for index in 0..<80 where y > -4 {
            if index == 20 { y -= gap }
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(
                    string: line,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 10, nil)]
                )),
                context
            )
            y -= 14
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        return (document, try #require(document.page(at: 0)))
    }

    // Build 138 trapped on launch here (2026-09-23): a gap one strip tall
    // between two paragraphs was trimmed on both sides into a Range whose
    // upper bound fell below its lower one.
    @Test("A paragraph gap between two blocks of prose is no figure band, and does not trap")
    func narrowGapBetweenParagraphsIsNoBand() throws {
        for gap in [0, 4, 9, 12, 16, 24] as [CGFloat] {
            let (document, page) = try proseOnlyPage(paragraphGap: gap)
            withExtendedLifetime(document) {
                #expect(PaperFigureRectRefiner.proseFreeBand(on: page) == nil, "gap \(gap)")
                #expect(PaperFigureRectRefiner.uncaptionedFigureBand(on: page) == nil, "gap \(gap)")
            }
        }
    }
}

/// A page whose media box starts at (20, 20), not (0, 0), as the JBC paper
/// 10.1074/jbc.M809512200's starts at (9, 9): a figure block, its caption and
/// prose on the first page, prose alone on the second. Every coordinate here
/// is a page coordinate, the box's origin included, the frame PDFKit reports
/// text boxes in.
private enum SyntheticOffsetPage {
    static let mediaBox = CGRect(x: 20, y: 20, width: 612, height: 792)
    static let figureBlock = CGRect(x: 120, y: 520, width: 400, height: 200)
    static let captionOrigin = CGPoint(x: 120, y: 490)
    static let captionLine = "Figure 1 | A block on a page whose box starts twenty points in."
    static let proseLine = "This paragraph is body text set across the full measure of the page, dense enough to read as prose."

    /// `rect`, a page rectangle, normalized top-left in the media box: the
    /// frame `PaperFigureRect` and every `?crop=` use.
    static func normalized(_ rect: CGRect) -> PaperFigureRect {
        PaperFigureRect(
            x: (rect.minX - mediaBox.minX) / mediaBox.width,
            y: (mediaBox.maxY - rect.maxY) / mediaBox.height,
            width: rect.width / mediaBox.width,
            height: rect.height / mediaBox.height
        )
    }

    static func write(to url: URL) throws {
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let page = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary

        context.beginPDFPage(page)
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(figureBlock)
        context.setFillColor(gray: 0, alpha: 1)
        draw(captionLine, at: captionOrigin, size: 11, in: context)
        for index in 0..<8 {
            draw(proseLine, at: CGPoint(x: 92, y: 440 - CGFloat(index) * 16), size: 10, in: context)
        }
        context.endPDFPage()

        context.beginPDFPage(page)
        for index in 0..<45 {
            draw(proseLine, at: CGPoint(x: 92, y: 760 - CGFloat(index) * 15), size: 10, in: context)
        }
        context.endPDFPage()
        context.closePDF()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

/// `PDFPage.draw(with: .mediaBox, to:)` puts the media box's origin at the
/// context's origin itself. Until 2026-09-28 every renderer translated by the
/// box's origin as well, so a page whose box does not start at (0, 0) was
/// drawn displaced by that origin — the mask and the renders alike, while
/// the text boxes stayed put — and the JBC paper's prose pages read as
/// figure ink.
@Suite("Paper Figure Page Whose Media Box Does Not Start At Zero")
struct PaperFigureMediaBoxOriginTests {

    private func withDocument(_ body: (PDFDocument) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureMediaBoxOriginTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("paper.pdf")
        try SyntheticOffsetPage.write(to: url)
        let document = try #require(PDFDocument(url: url))
        try #require(document.page(at: 0)?.bounds(for: .mediaBox) == SyntheticOffsetPage.mediaBox)
        try withExtendedLifetime(document) { try body(document) }
    }

    /// The box of the picture's dark, colourless pixels — the block and the
    /// text, never the measurement grid's violet — inside `window`,
    /// normalized top-left like the picture's crop.
    private func darkBounds(
        of data: Data,
        within window: PaperFigureRect = PaperFigureRect(x: 0, y: 0, width: 1, height: 1)
    ) throws -> PaperFigureRect {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let rows = Int(window.y * Double(height))..<Int(((window.y + window.height) * Double(height)).rounded())
        let columns = Int(window.x * Double(width))..<Int(((window.x + window.width) * Double(width)).rounded())
        var left = width, top = height, right = -1, bottom = -1
        // Rows are stored top first.
        for row in rows {
            for column in columns {
                let offset = (row * width + column) * 4
                guard max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 120 else { continue }
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        try #require(right >= left && bottom >= top, "nothing dark in the picture")
        return PaperFigureRect(
            x: Double(left) / Double(width),
            y: Double(top) / Double(height),
            width: Double(right - left + 1) / Double(width),
            height: Double(bottom - top + 1) / Double(height)
        )
    }

    private func expectClose(
        _ actual: PaperFigureRect,
        _ expected: PaperFigureRect,
        within tolerance: Double,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (a, e, edge) in [
            (actual.x, expected.x, "left"),
            (actual.y, expected.y, "top"),
            (actual.x + actual.width, expected.x + expected.width, "right"),
            (actual.y + actual.height, expected.y + expected.height, "bottom"),
        ] {
            #expect(abs(a - e) < tolerance, "\(comment): \(edge) edge at \(a), expected \(e)", sourceLocation: sourceLocation)
        }
    }

    @Test("A page of prose keeps its ink inside its text boxes")
    func proseInkSitsInItsTextBoxes() throws {
        try withDocument { document in
            let prose = try #require(document.page(at: 1))
            let ink = try #require(PaperFigureRectRefiner.pageInk(on: prose))
            #expect(ink.text > 0.01)
            #expect(ink.figure < 0.001, "text ink fell outside the text boxes: \(ink.figure)")
            #expect(!ink.showsFigure)
            let figure = try #require(document.page(at: 0))
            #expect(PaperFigureRectRefiner.showsFigure(figure))
        }
    }

    @Test("The caption's text box and the crop measured on the ink name the same page")
    func figureCropLandsOnTheBlock() throws {
        try withDocument { document in
            let page = try #require(document.page(at: 0))
            // PDFKit reports text in page coordinates, origin included.
            let caption = try #require(PaperFigureRectRefiner.captionBounds(of: SyntheticOffsetPage.captionLine, on: page))
            #expect(abs(caption.minX - SyntheticOffsetPage.captionOrigin.x) < 2)
            #expect(caption.maxY < SyntheticOffsetPage.figureBlock.minY)

            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticOffsetPage.captionLine, on: page))
            expectClose(crop, SyntheticOffsetPage.normalized(SyntheticOffsetPage.figureBlock), within: 0.015, "crop")
            #expect(crop.y + crop.height < SyntheticOffsetPage.normalized(caption).y)
        }
    }

    @Test("Every render of a crop shows the part of the page the crop names")
    func rendersShowWhatTheCropNames() throws {
        try withDocument { document in
            let page = try #require(document.page(at: 0))
            let margin: CGFloat = 10
            let crop = SyntheticOffsetPage.normalized(SyntheticOffsetPage.figureBlock.insetBy(dx: -margin, dy: -margin))
            // The block inside a crop that leaves `margin` points round it.
            let inside = PaperFigureRect(
                x: margin / (SyntheticOffsetPage.figureBlock.width + 2 * margin),
                y: margin / (SyntheticOffsetPage.figureBlock.height + 2 * margin),
                width: SyntheticOffsetPage.figureBlock.width / (SyntheticOffsetPage.figureBlock.width + 2 * margin),
                height: SyntheticOffsetPage.figureBlock.height / (SyntheticOffsetPage.figureBlock.height + 2 * margin)
            )

            let catalog = try #require(SourceImageCatalog.renderPage(page, crop: crop))
            expectClose(try darkBounds(of: catalog.data), inside, within: 0.01, "show_source_image crop")

            let lens = try #require(WalkthroughAnchorResolver.renderLens(crop, on: page))
            expectClose(try darkBounds(of: lens), inside, within: 0.01, "walkthrough lens")

            // The ruled page the vision pass reads its rectangle off: the
            // block, above the caption, where the page says it is. The grid's
            // numbers along the top and left edges are left out; JPEG's
            // chroma subsampling greys their thin violet strokes.
            let measured = try #require(PDFTextExtractor.measuredPageJPEGData(from: document, pageIndex: 0))
            let aboveCaption = PaperFigureRect(x: 0.05, y: 0.05, width: 0.95, height: 0.33)
            expectClose(
                try darkBounds(of: measured, within: aboveCaption),
                SyntheticOffsetPage.normalized(SyntheticOffsetPage.figureBlock),
                within: 0.005,
                "measured page"
            )
        }
    }
}

/// Pages set the ways a figure shares its page, drawn for the region tests:
/// another figure's legend above it, a column of text beside it, a caption
/// set beside it, figures side by side, a legend at the foot of the next
/// figure's page. Each is the shape of a page that cropped wrong in the
/// library on 2026-09-28. Geometry in PDF points from the bottom-left.
private enum SyntheticSharedPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let words = """
        the membrane potential of each crista was measured against the inner boundary membrane \
        in live cells stained with a dye whose fluorescence follows the potential across it
        """.split(separator: " ").map(String.init)

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static func top(_ y: CGFloat) -> Double { (mediaBox.maxY - y) / mediaBox.height }
    static func left(_ x: CGFloat) -> Double { x / mediaBox.width }

    /// A document of one page for each closure, and the file it is in.
    static func document(
        mediaBox: CGRect = mediaBox,
        pages: [(CGContext) -> Void]
    ) throws -> (PDFDocument, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticSharedPage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("paper.pdf")
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            page(context)
            context.endPDFPage()
        }
        context.closePDF()
        return (try #require(PDFDocument(url: url)), url)
    }

    static func text(_ string: String, at point: CGPoint, size: CGFloat = 9, font: String = "Helvetica", in context: CGContext) {
        context.textPosition = point
        CTLineDraw(line(string, size: size, font: font), context)
    }

    /// `count` lines of body text from `baseline` down, `pitch` apart, each
    /// justified to `width` as a journal sets a column; the last line of the
    /// paragraph is short. Returns the baseline under the last line.
    @discardableResult
    static func paragraph(
        x: CGFloat,
        baseline: CGFloat,
        width: CGFloat,
        lines count: Int,
        pitch: CGFloat = 11,
        size: CGFloat = 9,
        in context: CGContext
    ) -> CGFloat {
        var next = 0
        for index in 0..<count {
            let measure = index == count - 1 ? width * 0.4 : width
            var string = ""
            while true {
                let candidate = string.isEmpty ? words[next % words.count] : string + " " + words[next % words.count]
                guard CTLineGetTypographicBounds(line(candidate, size: size, font: "Times-Roman"), nil, nil, nil) <= Double(measure) else { break }
                string = candidate
                next += 1
            }
            let plain = line(string, size: size, font: "Times-Roman")
            let set = index == count - 1 ? plain : (CTLineCreateJustifiedLine(plain, 1, Double(width)) ?? plain)
            context.textPosition = CGPoint(x: x, y: baseline - CGFloat(index) * pitch)
            CTLineDraw(set, context)
        }
        return baseline - CGFloat(count) * pitch
    }

    /// One line of body text justified to `width`, as a column's line that
    /// runs on to the next is set.
    static func justified(_ string: String, at point: CGPoint, width: CGFloat, size: CGFloat = 9, in context: CGContext) {
        let plain = line(string, size: size, font: "Times-Roman")
        context.textPosition = point
        CTLineDraw(CTLineCreateJustifiedLine(plain, 1, Double(width)) ?? plain, context)
    }

    static func block(_ rect: CGRect, gray: CGFloat = 0.15, in context: CGContext) {
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(rect)
        context.setFillColor(gray: 0, alpha: 1)
    }

    private static func line(_ string: String, size: CGFloat, font: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [.font: CTFontCreateWithName(font as CFString, size, nil)]
        ))
    }
}

@Suite("Paper Figure Region")
struct PaperFigureRegionTests {
    private typealias Page = SyntheticSharedPage

    private func crop(_ caption: String, pageIndex: Int = 0, in document: PDFDocument) throws -> PaperFigureRect {
        let page = try #require(document.page(at: pageIndex))
        return try #require(PaperFigureRectRefiner.figureCrop(forCaption: caption, on: page))
    }

    @Test("Another figure's legend printed above a figure, in its grey box, stays out of the crop")
    func legendAboveStaysOut() throws {
        // Figure 7 of the EMBO cristae paper, page 11: Figure 6's legend
        // opens the page in a grey box, and the crop took it in.
        let figure = CGRect(x: 80, y: 380, width: 450, height: 260)
        let caption = "Figure 7. Opa1 regulates the difference in potential between cristae and IBM."
        let (document, url) = try Page.document(pages: [{ context in
            Page.block(CGRect(x: 60, y: 676, width: 492, height: 84), gray: 0.9, in: context)
            Page.text("◀ Figure 6. Crista junctions regulate the difference in potential.", at: CGPoint(x: 70, y: 745), in: context)
            Page.paragraph(x: 70, baseline: 732, width: 470, lines: 5, in: context)
            Page.block(figure, in: context)
            Page.text(caption, at: CGPoint(x: 70, y: 355), in: context)
            Page.paragraph(x: 70, baseline: 342, width: 470, lines: 3, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let rect = try crop(caption, in: document)
            #expect(abs(rect.y - Page.top(figure.maxY)) < 0.015)
            #expect(rect.y + rect.height < Page.top(355 + 9))
            #expect(abs(rect.x - Page.left(figure.minX)) < 0.015)
        }
    }

    @Test("A column of text beside a figure stays out of its crop")
    func columnBesideStaysOut() throws {
        // Figure 8 of the cristae paper, page 12, and Figure 5 of the JBC
        // paper, page 8: a figure in one column, prose in the other, and
        // the crop ran the width of the page.
        let figure = CGRect(x: 60, y: 480, width: 230, height: 250)
        let caption = "Figure 8. The largest differences arise in cristae vesicles."
        let (document, url) = try Page.document(pages: [{ context in
            Page.block(figure, in: context)
            Page.text(caption, at: CGPoint(x: 60, y: 460), size: 8, in: context)
            Page.paragraph(x: 60, baseline: 448, width: 230, lines: 3, size: 8, in: context)
            Page.paragraph(x: 60, baseline: 390, width: 230, lines: 26, in: context)
            Page.paragraph(x: 320, baseline: 740, width: 240, lines: 60, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let rect = try crop(caption, in: document)
            #expect(rect.x + rect.width < Page.left(320))
            #expect(abs(rect.x + rect.width - Page.left(figure.maxX)) < 0.015)
            #expect(abs(rect.y - Page.top(figure.maxY)) < 0.015)
        }
    }

    @Test("A caption set beside its figure crops the figure beside it, not the sliver above the caption")
    func sideCaptionCropsTheFigureBesideIt() throws {
        // The Biophysical Journal, pages 2 to 6 (2026-09-28): the band above
        // "FIGURE 1 Proton transport…" was the top tenth of the page.
        let figure = CGRect(x: 50, y: 520, width: 320, height: 222)
        let caption = "FIGURE 1 Proton transport across the inner mito-"
        let (document, url) = try Page.document(pages: [{ context in
            Page.text("Probing mitochondrial membrane potentials", at: CGPoint(x: 400, y: 770), size: 8, in: context)
            Page.block(figure, in: context)
            Page.text(caption, at: CGPoint(x: 385, y: 660), size: 8, font: "Times-Roman", in: context)
            Page.paragraph(x: 385, baseline: 650, width: 175, lines: 7, pitch: 10, size: 8, in: context)
            Page.paragraph(x: 50, baseline: 480, width: 245, lines: 34, in: context)
            Page.paragraph(x: 315, baseline: 480, width: 245, lines: 34, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            let anchor = try #require(PaperFigureRectRefiner.captionAnchor(of: caption, on: page))
            #expect(PaperFigureRectRefiner.figureRegion(captionAnchor: anchor, on: page, mask: mask)?.side == .left)
            let rect = try crop(caption, in: document)
            #expect(abs(rect.y - Page.top(figure.maxY)) < 0.015)
            #expect(abs(rect.y + rect.height - Page.top(figure.minY)) < 0.015)
            #expect(rect.x + rect.width < Page.left(385))
        }
    }

    @Test("Figures sharing a page are each cropped to their own ink, not their neighbours' and captions")
    func figuresSharingAPageKeepApart() throws {
        // The α-KGDH paper (J. Neurosci. 2004), pages 3 and 4: every crop
        // on a page of two or three figures took in the others.
        let first = CGRect(x: 60, y: 580, width: 490, height: 160)
        let second = CGRect(x: 60, y: 330, width: 220, height: 170)
        let third = CGRect(x: 330, y: 300, width: 220, height: 200)
        let captions = [
            "Figure 1. H2O2 release from synaptosomes measured by a direct assay.",
            "Figure 2. H2O2 production by the isolated enzyme.",
            "Figure 3. Stimulation of H2O2 production by NADH.",
        ]
        let (document, url) = try Page.document(pages: [{ context in
            Page.block(first, in: context)
            Page.text(captions[0], at: CGPoint(x: 60, y: 560), size: 8, in: context)
            Page.paragraph(x: 60, baseline: 549, width: 490, lines: 3, size: 8, in: context)
            Page.block(second, in: context)
            Page.text(captions[1], at: CGPoint(x: 60, y: 310), size: 8, in: context)
            Page.paragraph(x: 60, baseline: 299, width: 230, lines: 3, size: 8, in: context)
            Page.block(third, in: context)
            Page.text(captions[2], at: CGPoint(x: 320, y: 280), size: 8, in: context)
            Page.paragraph(x: 320, baseline: 269, width: 240, lines: 3, size: 8, in: context)
            Page.paragraph(x: 60, baseline: 200, width: 230, lines: 11, in: context)
            Page.paragraph(x: 320, baseline: 200, width: 240, lines: 11, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let one = try crop(captions[0], in: document)
            #expect(abs(one.y - Page.top(first.maxY)) < 0.015)
            #expect(one.y + one.height < Page.top(560 + 9))
            let two = try crop(captions[1], in: document)
            #expect(abs(two.y - Page.top(second.maxY)) < 0.015)
            #expect(two.x + two.width < Page.left(third.minX))
            #expect(two.y + two.height < Page.top(310 + 9))
            let three = try crop(captions[2], in: document)
            #expect(abs(three.y - Page.top(third.maxY)) < 0.015)
            #expect(three.x > Page.left(second.maxX))
        }
    }

    @Test("A narrow column set beside a figure, a short running head over it, stays out of the crop")
    func narrowColumnAndShortHeadStayOut() throws {
        // Figure 1 of the JBC paper, page 2: the column wrapped beside the
        // figure is a fifth of the page wide, under the width a line of
        // prose was held to, and the running head is one short line over it.
        let figure = CGRect(x: 50, y: 520, width: 360, height: 220)
        let caption = "FIGURE 1. Mitochondrial pathways of electron flow."
        let (document, url) = try Page.document(pages: [{ context in
            Page.text("Mitochondrial ROS and O2", at: CGPoint(x: 432, y: 758), size: 12, font: "Helvetica-BoldOblique", in: context)
            Page.block(figure, in: context)
            Page.paragraph(x: 425, baseline: 740, width: 140, lines: 22, in: context)
            Page.text(caption, at: CGPoint(x: 50, y: 500), size: 8, in: context)
            Page.paragraph(x: 50, baseline: 489, width: 360, lines: 3, size: 8, in: context)
            Page.paragraph(x: 50, baseline: 440, width: 245, lines: 32, in: context)
            Page.paragraph(x: 320, baseline: 440, width: 245, lines: 32, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let rect = try crop(caption, in: document)
            #expect(rect.x + rect.width < Page.left(425))
            #expect(abs(rect.y - Page.top(figure.maxY)) < 0.015)
        }
    }

    /// An A4 page of the white paper "Engineered human resilience and
    /// durability" (2026-09-29): its title and date set at the right over a
    /// rule, two columns under it.
    private static let whitePaperBox = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
    private static let whitePaperRule = CGRect(x: 53.7, y: 778.6, width: 488, height: 0.6)
    private static func a4Top(_ y: CGFloat) -> Double { Double((whitePaperBox.maxY - y) / whitePaperBox.height) }
    private static func a4Left(_ x: CGFloat) -> Double { Double(x / whitePaperBox.width) }

    private func whitePaperHead(_ context: CGContext) {
        Page.text("Engineered human resilience and durability | September 2026", at: CGPoint(x: 332, y: 790), size: 8, in: context)
        context.fill(Self.whitePaperRule)
    }

    /// Text in white, as a figure sets its titles on a dark band.
    private func whiteText(_ string: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
        )), context)
    }

    private func stroke(_ points: [CGPoint], width: CGFloat = 1, in context: CGContext) {
        context.setStrokeColor(gray: 0.1, alpha: 1)
        context.setLineWidth(width)
        context.addLines(between: points)
        context.strokePath()
    }

    @Test("A running head set short at one side is the head: a panel letter level with the other column's text is the figure's")
    func shortHeadOverTwoColumnsKeepsPanelLetter() throws {
        // Figure 2 of the white paper, page 4. The head is a third of the
        // page wide, so it was passed over, and so was the right column's
        // first line; the next row joined panel A's letter to that column's
        // second line, spanning the page, and was taken for the head. The
        // crop began under it, without the letter or the legend.
        let caption = "Figure 2: What a reserve claim has to say. (A) Raise the load"
        let (document, url) = try Page.document(mediaBox: Self.whitePaperBox, pages: [{ context in
            self.whitePaperHead(context)
            Page.paragraph(x: 307.6, baseline: 758, width: 234, lines: 30, pitch: 12, size: 10, in: context)
            Page.text("A", at: CGPoint(x: 61.7, y: 743), size: 9, font: "Helvetica-Bold", in: context)
            // The legend's keys and the plot, drawn: its words are outlines.
            self.stroke([CGPoint(x: 92, y: 740), CGPoint(x: 113, y: 740)], width: 1.5, in: context)
            self.stroke([CGPoint(x: 92, y: 731), CGPoint(x: 113, y: 731)], width: 1.5, in: context)
            self.stroke([CGPoint(x: 86, y: 738), CGPoint(x: 86, y: 638), CGPoint(x: 256, y: 638)], in: context)
            self.stroke([CGPoint(x: 86, y: 655), CGPoint(x: 150, y: 700), CGPoint(x: 200, y: 690), CGPoint(x: 256, y: 640)], width: 1.5, in: context)
            self.stroke([CGPoint(x: 193, y: 738), CGPoint(x: 193, y: 638)], width: 0.5, in: context)
            Page.text("imposed load", at: CGPoint(x: 150, y: 625), size: 7, in: context)
            Page.text("B", at: CGPoint(x: 61.7, y: 598), size: 9, font: "Helvetica-Bold", in: context)
            Page.block(CGRect(x: 86, y: 535, width: 170, height: 20), gray: 0.9, in: context)
            self.stroke([CGPoint(x: 90, y: 545), CGPoint(x: 250, y: 545)], width: 1.5, in: context)
            Page.text("reserve", at: CGPoint(x: 160, y: 505), size: 7, in: context)
            Page.text(caption, at: CGPoint(x: 53.9, y: 475), size: 9, in: context)
            Page.paragraph(x: 53.9, baseline: 463, width: 229, lines: 7, pitch: 12, size: 10, in: context)
            Page.paragraph(x: 53.9, baseline: 390, width: 235, lines: 25, pitch: 12, size: 10, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            // Read from the text alone or with the ink, the head stays over
            // the rule; with the ink it is the title and the rule.
            #expect((PaperFigureRectRefiner.runningHeadBounds(on: page)?.minY ?? .infinity) > Self.whitePaperRule.maxY)
            let head = try #require(PaperFigureRectRefiner.runningHeadBounds(on: page, mask: mask))
            #expect(head.minY <= Self.whitePaperRule.minY + 1 && head.minY > 760)
            let rect = try crop(caption, in: document)
            #expect(rect.y < Self.a4Top(752), "panel A's letter is in the crop")
            #expect(rect.y > Self.a4Top(Self.whitePaperRule.minY), "the rule is not")
            #expect(rect.x + rect.width < Self.a4Left(307.6))
            #expect(rect.y + rect.height < Self.a4Top(475 + 9))
        }
    }

    @Test("A figure's titles set across a dark band under a short running head are the figure's top, not the head")
    func darkHeaderBandStaysInTheCrop() throws {
        // Figure 3 of the white paper, page 6: a funnel whose four stage
        // titles are printed in white on a dark band. Their row spans two
        // thirds of the page, and under a head too narrow to count it was
        // taken for the head; the crop began under the band.
        let band = CGRect(x: 68.5, y: 731, width: 458, height: 37)
        let caption = "Figure 3: The search space and funnel. Every protein biology has produced is a candidate mechanism."
        let (document, url) = try Page.document(mediaBox: Self.whitePaperBox, pages: [{ context in
            self.whitePaperHead(context)
            Page.block(band, gray: 0.2, in: context)
            for (title, x) in [("ALL OF BIOLOGY", 95.8), ("FUNCTION RETRIEVAL", 201), ("DESIGN", 341), ("VALIDATION", 448)] as [(String, CGFloat)] {
                self.whiteText(title, at: CGPoint(x: x, y: 744), size: 8, in: context)
            }
            Page.text("250M", at: CGPoint(x: 140, y: 700), size: 20, font: "Helvetica-Bold", in: context)
            for (words, x) in [("known proteins", 115), ("candidates matched", 225), ("mechanism rebuilt", 349), ("tested under load", 472)] as [(String, CGFloat)] {
                Page.text(words, at: CGPoint(x: x, y: 680), size: 8, in: context)
            }
            for x in [105, 267, 429] as [CGFloat] {
                self.stroke([CGPoint(x: x, y: 659), CGPoint(x: x + 146, y: 659)], width: 0.5, in: context)
                Page.block(CGRect(x: x + 3, y: 620, width: 4, height: 4), gray: 0.4, in: context)
                Page.text("removed here", at: CGPoint(x: x + 14, y: 619), size: 7, in: context)
            }
            self.stroke([CGPoint(x: 238, y: 580), CGPoint(x: 238, y: 565), CGPoint(x: 470, y: 565), CGPoint(x: 470, y: 580)], in: context)
            Page.text("Each round of evidence reshapes the next pass", at: CGPoint(x: 292, y: 571), size: 7, in: context)
            Page.text(caption, at: CGPoint(x: 53.9, y: 525), size: 10, in: context)
            Page.paragraph(x: 53.9, baseline: 513, width: 488, lines: 3, pitch: 12, size: 10, in: context)
            Page.paragraph(x: 53.9, baseline: 440, width: 235, lines: 30, pitch: 12, size: 10, in: context)
            Page.paragraph(x: 307.6, baseline: 440, width: 234, lines: 30, pitch: 12, size: 10, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            #expect((PaperFigureRectRefiner.runningHeadBounds(on: page)?.minY ?? .infinity) > Self.whitePaperRule.maxY)
            #expect((PaperFigureRectRefiner.runningHeadBounds(on: page, mask: mask)?.minY ?? .infinity) > band.maxY)
            let rect = try crop(caption, in: document)
            #expect(abs(rect.y - Self.a4Top(band.maxY)) < 0.01, "the band is the crop's top")
            #expect(rect.y > Self.a4Top(Self.whitePaperRule.minY))
            #expect(rect.y + rect.height < Self.a4Top(525 + 9))
        }
    }

    /// A Nature article's page (10.1038/s41586-025-09298-z, 2026-09-30):
    /// on a right-hand page "Article" at the top left over a rule run off
    /// the page's right edge, on a left-hand page the rule alone run off its
    /// left edge, and a hairline down the left margin to the foot, from the
    /// label or from under the rule. The figure's panel letters are set four
    /// points under the rule.
    private static let natureBox = CGRect(x: 0, y: 0, width: 595.276, height: 790.866)
    private static func natureMarginRule(rightHandPage: Bool) -> CGRect {
        CGRect(x: 33.3, y: 55, width: 1.2, height: rightHandPage ? 707 : 687)
    }
    private static func natureHeadRule(rightHandPage: Bool) -> CGRect {
        rightHandPage ? CGRect(x: 39.9, y: 746.3, width: 555.4, height: 0.7) : CGRect(x: 0, y: 746.3, width: 562, height: 0.7)
    }
    private static func natureTop(_ y: CGFloat) -> Double { Double((natureBox.maxY - y) / natureBox.height) }
    private static func natureLeft(_ x: CGFloat) -> Double { Double(x / natureBox.width) }

    /// A page of the Nature article: its head, and when `figure` is given
    /// that figure under it with panel letters "a" and "b" at the same place
    /// on every page, as Extended Data pages set them, over its caption and
    /// two columns of text.
    private func naturePage(_ context: CGContext, rightHandPage: Bool, figure caption: String?) {
        if rightHandPage {
            Page.text("Article", at: CGPoint(x: 39.9, y: 751), size: 17, font: "Helvetica-Bold", in: context)
        }
        context.fill(Self.natureHeadRule(rightHandPage: rightHandPage))
        context.fill(Self.natureMarginRule(rightHandPage: rightHandPage))
        guard let caption else {
            Page.paragraph(x: 39.9, baseline: 725, width: 250, lines: 55, pitch: 11.5, size: 9, in: context)
            Page.paragraph(x: 305, baseline: 725, width: 250, lines: 55, pitch: 11.5, size: 9, in: context)
            return
        }
        Page.text("a", at: CGPoint(x: 40.5, y: 736), size: 9, font: "Helvetica-Bold", in: context)
        Page.text("b", at: CGPoint(x: 290, y: 736), size: 9, font: "Helvetica-Bold", in: context)
        stroke([CGPoint(x: 60, y: 732), CGPoint(x: 60, y: 560), CGPoint(x: 270, y: 560)], in: context)
        stroke([CGPoint(x: 60, y: 580), CGPoint(x: 120, y: 700), CGPoint(x: 190, y: 640), CGPoint(x: 265, y: 720)], width: 1.5, in: context)
        Page.block(CGRect(x: 310, y: 560, width: 240, height: 168), gray: 0.55, in: context)
        Page.text("Relative indel rate", at: CGPoint(x: 360, y: 545), size: 7, in: context)
        Page.text(caption, at: CGPoint(x: 39.9, y: 520), size: 8, font: "Helvetica-Bold", in: context)
        Page.paragraph(x: 39.9, baseline: 509, width: 515, lines: 4, pitch: 10, size: 8, in: context)
        Page.paragraph(x: 39.9, baseline: 450, width: 250, lines: 34, pitch: 11.5, size: 9, in: context)
        Page.paragraph(x: 305, baseline: 450, width: 250, lines: 34, pitch: 11.5, size: 9, in: context)
    }

    @Test("A journal's short head that runs from page to page is the head, however little white is under it")
    func naturesArticleHeadStaysOutOfTheCrop() throws {
        // "Article" has a rule four points under it, then the figure, and
        // the hairline down the margin inks every row beside it: no white
        // under it its own height, so it was no head, and a figure at the
        // top of the page was cropped with "Article", the rule to the page's
        // edge and the hairline (y 0.029). It is the head because the next
        // right-hand page prints it at the same place, which no figure's
        // title is; the panel letters, printed at the same place on both
        // figure pages, are too short to run.
        let first = "Fig. 1 | Generated nucleases function as gene editors in human cells."
        let second = "Fig. 2 | Mutation distribution in active proteins."
        let (document, url) = try Page.document(mediaBox: Self.natureBox, pages: [
            { self.naturePage($0, rightHandPage: true, figure: first) },
            { self.naturePage($0, rightHandPage: false, figure: second) },
            { self.naturePage($0, rightHandPage: true, figure: nil) },
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            let rule = Self.natureHeadRule(rightHandPage: true)
            let head = try #require(PaperFigureRectRefiner.runningHead(on: page, mask: mask))
            #expect(head.bounds.minY <= rule.minY + 1 && head.bounds.minY > 742, "the head takes its rule and stops over the panel letters")
            #expect(head.sideBands.contains { $0.intersects(Self.natureMarginRule(rightHandPage: true)) }, "the margin's hairline goes with it")

            let rect = try crop(first, in: document)
            #expect(rect.y > Self.natureTop(rule.minY), "the rule is out of the crop")
            #expect(rect.y < Self.natureTop(742), "panel a's letter is in it")
            #expect(rect.x > Self.natureLeft(Self.natureMarginRule(rightHandPage: true).maxX), "the margin's hairline is out")
            #expect(rect.x < Self.natureLeft(40.5))
            #expect(rect.x + rect.width < Self.natureLeft(560), "the crop stops at the figure, not the rule's end")
            #expect(rect.y + rect.height < Self.natureTop(520))

            // A left-hand page has no label, only the rule, run off the
            // page's other edge.
            let verso = try crop(second, pageIndex: 1, in: document)
            #expect(verso.y > Self.natureTop(Self.natureHeadRule(rightHandPage: false).minY), "the bare rule is the head")
            #expect(verso.y < Self.natureTop(742))
            #expect(verso.x + verso.width < Self.natureLeft(560))
        }
    }

    @Test("A legend at the foot of the next figure's page belongs to the figure page before it")
    func legendUnderAnotherFigureGoesBack() throws {
        // Figure 4 of the JBC paper fills page 7; its legend is printed at
        // the foot of page 8, under two columns of text and Figure 5 with
        // its legend. With page 8 showing a figure, Figure 4 was indexed
        // there and cropped to the text.
        let (document, url) = try Page.document(pages: [
            { context in
                Page.text("A synthetic paper", at: CGPoint(x: 60, y: 740), size: 16, in: context)
                Page.paragraph(x: 60, baseline: 700, width: 490, lines: 50, in: context)
            },
            { context in
                Page.block(CGRect(x: 60, y: 90, width: 490, height: 640), in: context)
            },
            { context in
                Page.block(CGRect(x: 60, y: 560, width: 230, height: 180), in: context)
                Page.text("FIGURE 5. ROS generation as a share of electron flux.", at: CGPoint(x: 60, y: 540), size: 8, in: context)
                Page.paragraph(x: 60, baseline: 529, width: 230, lines: 4, size: 8, in: context)
                Page.paragraph(x: 60, baseline: 470, width: 230, lines: 24, in: context)
                Page.paragraph(x: 320, baseline: 740, width: 240, lines: 50, in: context)
                context.fill(CGRect(x: 60, y: 188, width: 500, height: 0.8))
                Page.text("FIGURE 4. Estimated O2 response of ROS generation at each site.", at: CGPoint(x: 60, y: 175), size: 8, in: context)
                Page.paragraph(x: 60, baseline: 164, width: 500, lines: 4, size: 8, in: context)
            },
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 4", "Figure 5"])
            #expect(indexed.map(\.pageIndex) == [1, 2])
            let page = try #require(document.page(at: 1))
            let rect = try #require(PaperFigureRectRefiner.figureCrop(forCaption: indexed[0].caption, on: page))
            #expect(abs(rect.y - Page.top(730)) < 0.015)
        }
    }

    @Test("A pale watermark on every page is no figure, beside a legend or on a page of its own")
    func paleWatermarkIsNoFigure() throws {
        // A Nature accepted manuscript sets "ARTICLE IN PRESS" across every
        // page at a grey of 210 to 219. Its legends read as standing beside a
        // figure, and a page holding one sentence and the watermark read as
        // a figure's page.
        func watermark(_ context: CGContext) {
            context.setStrokeColor(gray: 0.85, alpha: 1)
            context.setLineWidth(18)
            context.strokeLineSegments(between: [CGPoint(x: 120, y: 120), CGPoint(x: 500, y: 680)])
        }
        let (document, url) = try Page.document(pages: [
            { context in
                Page.text("A synthetic accepted manuscript", at: CGPoint(x: 60, y: 740), size: 16, in: context)
                Page.paragraph(x: 60, baseline: 700, width: 490, lines: 50, in: context)
                watermark(context)
            },
            { context in
                Page.text("This article contains 15 Supplementary Figures.", at: CGPoint(x: 60, y: 700), size: 9, in: context)
                watermark(context)
            },
            { context in
                Page.text("Figure 1. An index built from primary human fibroblasts.", at: CGPoint(x: 60, y: 720), size: 9, in: context)
                Page.paragraph(x: 60, baseline: 707, width: 490, lines: 12, in: context)
                Page.text("Figure 2. The index validated against time-resolved activation.", at: CGPoint(x: 60, y: 540), size: 9, in: context)
                Page.paragraph(x: 60, baseline: 527, width: 490, lines: 12, in: context)
                watermark(context)
            },
            { context in
                Page.block(CGRect(x: 70, y: 200, width: 470, height: 500), in: context)
                watermark(context)
            },
            { context in
                Page.block(CGRect(x: 70, y: 260, width: 470, height: 440), in: context)
                watermark(context)
            },
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 1", "Figure 2"])
            #expect(indexed.map(\.pageIndex) == [3, 4])
        }
    }

    @Test("A figure page with no caption keeps the panels above its densest rows of labels")
    func uncaptionedFigureKeepsItsTopPanels() throws {
        // Figure 6 of a bioRxiv preprint: its page prints no caption, and
        // the prose-free band stopped under a row of labels dense enough to
        // count as prose, so the crop began at the third panel.
        let upper = CGRect(x: 70, y: 560, width: 470, height: 160)
        let lower = CGRect(x: 70, y: 120, width: 470, height: 330)
        let caption = "Figure 1. Pan-CDK patterns of therapy resistance."
        let (document, url) = try Page.document(pages: [
            { context in
                Page.text("A synthetic preprint", at: CGPoint(x: 60, y: 740), size: 16, in: context)
                Page.paragraph(x: 60, baseline: 700, width: 490, lines: 50, in: context)
            },
            { context in
                Page.block(upper, in: context)
                // Three rows of condition labels under the upper panels, each
                // row more characters than a line of prose holds.
                for (row, y) in [546, 538, 530].enumerated() {
                    for (column, x) in [70, 190, 310, 430].enumerated() {
                        let label = Array(repeating: "CDK\(row)\(column)", count: 3 + column + row).joined(separator: " ")
                        Page.text(label, at: CGPoint(x: CGFloat(x), y: CGFloat(y)), size: 6, in: context)
                    }
                }
                Page.block(lower, in: context)
            },
            { context in
                Page.text(caption, at: CGPoint(x: 60, y: 720), size: 9, in: context)
                Page.paragraph(x: 60, baseline: 707, width: 490, lines: 14, in: context)
                Page.paragraph(x: 60, baseline: 520, width: 490, lines: 36, in: context)
            },
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.pageIndex) == [1])
            let rect = try crop(caption, pageIndex: 1, in: document)
            #expect(abs(rect.y - Page.top(upper.maxY)) < 0.015)
            #expect(abs(rect.y + rect.height - Page.top(lower.minY)) < 0.015)
        }
    }
}

@Suite("Paper Figure Words From Its Legend")
struct PaperFigureLegendWordsTests {
    private typealias Page = SyntheticSharedPage

    @Test("A sentence of the running text that opens with a figure's label does not title the figure")
    func runningTextReferenceDoesNotTitleTheFigure() throws {
        // Page 6 of the Biophysical Journal's "How and when to measure
        // mitochondrial inner membrane potentials" (2026-09-28): the right
        // column breaks "… as exemplified in" / "Fig. 5. The measured
        // fluorescence both inside and outside", and that sentence was
        // Figure 5's title while its legend is printed under the figure.
        let reference = "Fig. 5. The measured fluorescence both inside and outside"
        let legend = "FIGURE 5 Potential pitfalls in quantitative membrane potential determinations using fluorescent probes."
        let (document, url) = try Page.document(pages: [{ context in
            Page.text("Probing mitochondrial membrane potentials", at: CGPoint(x: 400, y: 770), size: 8, in: context)
            Page.paragraph(x: 50, baseline: 740, width: 245, lines: 30, in: context)
            Page.paragraph(x: 315, baseline: 740, width: 245, lines: 10, in: context)
            Page.justified("aging of the structures is being considered, as exemplified in", at: CGPoint(x: 315, y: 630), width: 245, in: context)
            Page.justified(reference, at: CGPoint(x: 315, y: 619), width: 245, in: context)
            Page.paragraph(x: 315, baseline: 608, width: 245, lines: 19, in: context)
            Page.block(CGRect(x: 80, y: 150, width: 450, height: 230), in: context)
            Page.text(legend, at: CGPoint(x: 50, y: 130), size: 8, font: "Times-Roman", in: context)
            Page.paragraph(x: 50, baseline: 120, width: 500, lines: 3, pitch: 10, size: 8, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let captions = PDFTextExtractor.figureCaptions(on: page)
            #expect(captions.map(\.label) == ["Figure 5", "Figure 5"])
            #expect(captions.first { $0.caption.hasPrefix(reference) }?.isRunningText == true)
            #expect(captions.first { $0.caption.hasPrefix(legend) }?.isRunningText == false)
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.map(\.figureLabel) == ["Figure 5"])
            #expect(indexed.first?.caption.hasPrefix(legend) == true)
            #expect(PaperFigureCaptionTitle.title(from: indexed.first?.caption ?? "")?
                .hasPrefix("Potential pitfalls in quantitative membrane potential") == true)
        }
    }

    @Test("A caption set in the body's face right under the text is still a caption")
    func captionUnderTheTextIsStillACaption() throws {
        // Under a line that closes its sentence, and under a paragraph's
        // short last line: the text above has ended, so the label opens a
        // legend. Alone on its page, a reference keeps its words.
        let (document, url) = try Page.document(pages: [{ context in
            Page.paragraph(x: 60, baseline: 740, width: 245, lines: 6, in: context)
            Page.justified("the potential of each crista was read against its boundary.", at: CGPoint(x: 60, y: 674), width: 245, in: context)
            Page.text("Figure 2. Cristae within one mitochondrion differ", at: CGPoint(x: 60, y: 663), font: "Times-Roman", in: context)
            Page.paragraph(x: 60, baseline: 652, width: 245, lines: 5, in: context)
            Page.text("Figure 3. The dye follows the potential in live cells", at: CGPoint(x: 60, y: 597), font: "Times-Roman", in: context)
            Page.paragraph(x: 60, baseline: 586, width: 245, lines: 4, in: context)
            Page.justified("in live cells whose boundary membrane was stained as in", at: CGPoint(x: 60, y: 542), width: 245, in: context)
            Page.text("Fig. 4. The fluorescence of each crista was then read", at: CGPoint(x: 60, y: 531), font: "Times-Roman", in: context)
            Page.paragraph(x: 60, baseline: 520, width: 245, lines: 4, in: context)
        }])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(document) {
            let page = try #require(document.page(at: 0))
            let captions = PDFTextExtractor.figureCaptions(on: page)
            #expect(captions.map(\.label) == ["Figure 2", "Figure 3", "Figure 4"])
            #expect(captions.map(\.isRunningText) == [false, false, true])
            let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
            #expect(indexed.first { $0.figureLabel == "Figure 4" }?.caption.hasPrefix("Fig. 4. The fluorescence") == true)
        }
    }
}

/// A Nature-style page: a column of body prose on the left, a plot with its
/// legend under it in the right column. Nature rules the page's top and runs a
/// hairline down the left margin, and the first lines of the left column sit
/// level with the plot's axis title, which PDFKit joins into one wide row.
private enum SyntheticColumnPage {
    static let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let plot = CGRect(x: 340, y: 520, width: 220, height: 195)
    static let caption = "Fig. 1 | A plot in the right column, drawn for the crop tests."

    /// Normalized top-left, the frame `PaperFigureRect` uses.
    static var plotTop: Double { (mediaBox.maxY - plot.maxY) / mediaBox.height }
    static var plotLeft: Double { plot.minX / mediaBox.width }
    static var plotRight: Double { plot.maxX / mediaBox.width }

    static func page(marginHairline: Bool, topRule: Bool, in directory: URL) throws -> PDFPage {
        let url = directory.appendingPathComponent("column-\(UUID().uuidString).pdf")
        var box = mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.5)
        if topRule { stroke(from: CGPoint(x: 0, y: 735), to: CGPoint(x: 580, y: 735), in: context) }
        if marginHairline { stroke(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 40, y: 725), in: context) }
        for index in 0..<12 {
            draw("Body prose of the left column runs here and goes on and on \(index)",
                 at: CGPoint(x: 60, y: 715 - CGFloat(index) * 12), size: 9, in: context)
        }
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(plot)
        draw("Mean count", at: CGPoint(x: 322, y: 715), size: 7, in: context)
        draw(caption, at: CGPoint(x: 320, y: 500), size: 8, in: context)
        for index in 0..<10 {
            draw("More running prose of the right column under the legend \(index)",
                 at: CGPoint(x: 320, y: 470 - CGFloat(index) * 12), size: 9, in: context)
        }
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(url: url)?.page(at: 0))
    }

    private static func stroke(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

@Suite("Paper Figure Beside A Column Of Prose")
struct PaperFigureBesideProseTests {

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureColumnTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("A hairline down the margin does not stretch the crop over the column of prose")
    func marginHairlineIsNoFigure() throws {
        try withDirectory { directory in
            let page = try SyntheticColumnPage.page(marginHairline: true, topRule: true, in: directory)
            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticColumnPage.caption, on: page))
            // Nature, Fig. 1 of the mtDNA-in-blood paper, 2026-10-23: the crop ran
            // from the margin rule to the plot's right edge.
            #expect(crop.x > SyntheticColumnPage.plotLeft - 0.04)
            #expect(crop.x + crop.width < SyntheticColumnPage.plotRight + 0.04)
        }
    }

    @Test("The first lines of a column of prose are no running head over the plot beside them")
    func firstLinesOfAColumnAreNoRunningHead() throws {
        try withDirectory { directory in
            let page = try SyntheticColumnPage.page(marginHairline: false, topRule: true, in: directory)
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            // Only the rule is the head: it ends well above the first line of
            // prose, whose row the axis title widens to a head's width.
            let head = PaperFigureRectRefiner.runningHeadBounds(on: page, mask: mask)
            if let head {
                let bottom = (page.bounds(for: .mediaBox).maxY - head.minY) / page.bounds(for: .mediaBox).height
                #expect(bottom < SyntheticColumnPage.plotTop)
            }
            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: SyntheticColumnPage.caption, on: page))
            // The plot's own top is in the crop, not cut off under a "head".
            #expect(crop.y <= SyntheticColumnPage.plotTop + 0.005)
            #expect(crop.x > SyntheticColumnPage.plotLeft - 0.04)
        }
    }
}

/// Nature's "Brief Communication" page after the DRF benchmarking paper, Fig. 1
/// (2026-10-26): the head is one row of 9 pt text, and the figure's first rows of
/// labels (panel letters over panel titles, legends under them) start a row's
/// height under it. Rows that close read as the head's own next lines, and the
/// crop began under the figure's top 68 pt.
@Suite("Paper Figure Under A Brief Communication Head")
struct PaperFigureUnderBannerHeadTests {

    private static let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 791)
    private static let caption = "Fig. 1 | Evaluating the calibration of benchmarking metrics. a, The technical duplicate baseline is generated by splitting cells from each perturbation"
    private static let headBaseline: CGFloat = 760
    /// The top of the first row of labels, normalized from the page's top.
    private static var labelsTop: Double { (mediaBox.maxY - (headBaseline - 14.8 + 6.2)) / mediaBox.height }
    private static var headBottom: Double { (mediaBox.maxY - (headBaseline - 2.1)) / mediaBox.height }

    private func withPage(_ body: (PDFPage) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureBannerHeadTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("page.pdf")
        var box = Self.mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let head = Self.headBaseline
        Self.draw("Brief Communication", at: CGPoint(x: 40, y: head), size: 9, in: context)
        Self.draw("https://doi.org/10.1000/synthetic-brief-communication-fixture", at: CGPoint(x: 330, y: head), size: 9, in: context)
        let first = head - 14.8, second = head - 24.8, third = head - 34.8
        for (text, x) in [("a", 41), ("b", 184), ("c", 340), ("Technical duplicate", 73),
                          ("Interpolated duplicate", 210), ("Dynamic range fraction", 400)] as [(String, CGFloat)] {
            Self.draw(text, at: CGPoint(x: x, y: first), size: 8, in: context)
        }
        for (text, x) in [("Affected genes", 192), ("Intermediate genes", 226), ("Unaffected genes", 269),
                          ("Perturbation", 113), ("Good calibration", 418)] as [(String, CGFloat)] {
            Self.draw(text, at: CGPoint(x: x, y: second), size: 8, in: context)
        }
        for (text, x) in [("Ideal response", 360), ("Mean baseline", 92)] as [(String, CGFloat)] {
            Self.draw(text, at: CGPoint(x: x, y: third), size: 8, in: context)
        }
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 60, y: 480, width: 460, height: 230))
        context.setFillColor(gray: 0, alpha: 1)
        Self.draw(Self.caption, at: CGPoint(x: 40, y: 468), size: 8, in: context)
        for index in 0..<10 {
            Self.draw("Running prose of the page under the legend goes on across the measure of the column here \(index)",
                      at: CGPoint(x: 40, y: 440 - CGFloat(index) * 12), size: 9, in: context)
        }
        context.endPDFPage()
        context.closePDF()
        try body(try #require(PDFDocument(url: url)?.page(at: 0)))
    }

    @Test("A figure's rows of labels a row's height under the head are not the head's own lines")
    func labelRowsAreNotTheHead() throws {
        try withPage { page in
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            let head = try #require(PaperFigureRectRefiner.runningHeadBounds(on: page, mask: mask))
            // The head is its one row, not the three rows of labels under it.
            #expect(head.height < 12)
            #expect(head.minY > Self.mediaBox.maxY * (1 - Self.labelsTop))
        }
    }

    @Test("The crop reaches the figure's top row of labels")
    func cropKeepsTheTopRows() throws {
        try withPage { page in
            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: Self.caption, on: page))
            #expect(crop.y <= Self.labelsTop + 0.005)
            #expect(crop.y >= Self.headBottom - 0.005)
        }
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
            )),
            context
        )
    }
}

/// Nature's Fig. 5 of the mtDNA-in-blood paper (2026-10-30): "Article" is the
/// head, and the figure's top rows are a row of panel letters and titles, a
/// legend and a row of tick labels, each a few points under the one above. The
/// search for the head passed the narrow rows over one by one, then took the
/// wide row of tick labels for the head, and the crop began under the figure's
/// top panels with the blue outline cutting them off.
@Suite("Paper Figure Under A Head Over Rows Of Labels")
struct PaperFigureUnderLabelRowsTests {

    private static let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 791)
    private static let caption = "Fig. 5 | Individuals with identified CH tend to have increased accumulation of age-accumulating mtSNVs relative to the general population and do not show evidence of positive selection."
    /// The top of the panel letters and titles, normalized from the page's top.
    private static var lettersTop: Double { (mediaBox.maxY - 743) / mediaBox.height }

    /// Three pages that print "Article" alike, as a journal's head runs, the
    /// middle one with the figure.
    private func withPage(_ body: (PDFPage) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureLabelRowsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pages.pdf")
        var box = Self.mediaBox
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            Self.draw("Article", at: CGPoint(x: 40, y: 750), size: 18, font: "Helvetica-Bold", in: context)
            if index == 1 { Self.drawFigure(in: context) }
            context.endPDFPage()
        }
        context.closePDF()
        try body(try #require(PDFDocument(url: url)?.page(at: 1)))
    }

    private static func drawFigure(in context: CGContext) {
        // Panel letters and titles, the legend, then tick labels and panel
        // titles joined into one wide row, as PDFKit reads them.
        for (text, x) in [("a", 83), ("A>C", 120), ("A>G", 175), ("A>T", 230), ("C>A", 285), ("b", 330)] as [(String, CGFloat)] {
            draw(text, at: CGPoint(x: x, y: 734.4), size: 11, in: context)
        }
        draw("CH Matched non-CH", at: CGPoint(x: 422, y: 723.3), size: 7, in: context)
        draw("LoF Missense Synonymous", at: CGPoint(x: 380, y: 709.5), size: 8, in: context)
        draw("2 x 10-4", at: CGPoint(x: 99, y: 700), size: 14, in: context)
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 100, y: 480, width: 420, height: 215))
        context.setFillColor(gray: 0, alpha: 1)
        draw(caption, at: CGPoint(x: 40, y: 468), size: 8, in: context)
        for index in 0..<10 {
            draw("Running prose of the page under the legend goes on across the measure of the column here \(index)",
                 at: CGPoint(x: 40, y: 440 - CGFloat(index) * 12), size: 9, in: context)
        }
    }

    @Test("A row of tick labels under narrow rows of letters and titles is not the head")
    func tickLabelRowIsNotTheHead() throws {
        try withPage { page in
            let mask = try #require(PaperFigureRectRefiner.mask(for: page))
            // Whatever head the page has, it is not the figure's rows: "Article"
            // here has no rule under it, so the page may have none.
            let head = PaperFigureRectRefiner.runningHeadBounds(on: page, mask: mask)
            #expect(head == nil || head!.minY > 743)
        }
    }

    @Test("The crop reaches the figure's panel letters")
    func cropKeepsTheTopPanels() throws {
        try withPage { page in
            let crop = try #require(PaperFigureRectRefiner.figureCrop(forCaption: Self.caption, on: page))
            #expect(crop.y <= Self.lettersTop + 0.01)
        }
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, font: String = "Helvetica", in context: CGContext) {
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

/// A paper nobody has asked about has no figure index: the index is built the
/// first time something needs it. `focus_source_anchor` refused "Figure 1" of
/// such a paper as not found (2026-10-28, a freshly imported preprint with its
/// index still queued), though the caption was printed on the page.
@Suite("Chat points at a figure of an unindexed paper")
@MainActor
struct FocusAnchorUnindexedPaperTests {

    @Test("Figure 1 of a paper with no index is found by reading its captions")
    func figureOfUnindexedPaperIsIndexedOnDemand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusAnchorUnindexed_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("zara-holt-preprint.pdf")
        try SyntheticPaperPage.write(to: pdf)

        let storage = StorageService(storeRoot: root.appendingPathComponent("store", isDirectory: true))
        var paper = StudioArticle(
            url: "https://example.org/zara-holt-preprint",
            title: "A synthetic preprint",
            sourceType: .paper,
            localFilePath: pdf.path
        )
        paper.state = .ready
        try await storage.saveSource(paper)
        #expect(try await storage.paperFigures(sourceID: paper.id).isEmpty)

        let manager = ReviewSessionManager(storage: storage)
        manager.walkthroughFocusHandler = { _ in }
        manager.walkthroughReaderShowsSource = { _ in true }

        let result = await manager.focusSourceAnchorForTesting(
            arguments: ["source_id": paper.id, "figure_label": "Figure 1"]
        )

        #expect(!result.isError)
        #expect(!result.text.contains("was not found"))
        #expect(result.text.contains("Pointed the Reader at Figure 1"))
        let indexed = try await storage.paperFigures(sourceID: paper.id)
        #expect(indexed.map(\.figureLabel) == ["Figure 1"])
        #expect(indexed.first?.analysis == nil)
    }
}
