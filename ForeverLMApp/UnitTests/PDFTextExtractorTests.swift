import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("PDF Text Extractor")
struct PDFTextExtractorTests {
    @Test("Dropped PDF staging preserves a safe human filename")
    func droppedPaperFilename() {
        #expect(PaperDropStager.safePDFFilename("Putting epigenetic aging clocks on trial.pdf") == "Putting epigenetic aging clocks on trial.pdf")
        #expect(PaperDropStager.safePDFFilename("../Unsafe:Paper.PDF") == "Unsafe Paper.pdf")
        #expect(PaperDropStager.safePDFFilename(nil) == "Dropped Paper.pdf")
    }

    @Test("Provider-owned PDF data is staged in an isolated directory")
    func droppedPaperDataStaging() async throws {
        let bytes = Data("%PDF-test-payload".utf8)
        let staged = try await PaperDropStager.stage(
            data: bytes,
            suggestedName: "Readable Paper.pdf"
        )
        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }

        #expect(staged.displayName == "Readable Paper.pdf")
        #expect(try Data(contentsOf: staged.url) == bytes)
        #expect(staged.url.deletingLastPathComponent().lastPathComponent.hasPrefix("ForeverLM-Paper-Drop-"))
    }

    @Test("Unnamed PDF data is staged under the title the PDF carries")
    func droppedPaperDataStagingUsesEmbeddedTitle() async throws {
        let titled = try Self.makePDFData(title: "Loss of the Y Chromosome: A Review")
        let staged = try await PaperDropStager.stage(data: titled, suggestedName: nil)
        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }
        #expect(staged.displayName == "Loss of the Y Chromosome A Review.pdf")
        #expect(staged.url.lastPathComponent == staged.displayName)
        #expect(try Data(contentsOf: staged.url) == titled)

        // A typesetter's job tag is not a title, so the placeholder stays.
        let tagged = try Self.makePDFData(title: "CMET4035_grabs 1..1")
        let stagedTagged = try await PaperDropStager.stage(data: tagged, suggestedName: nil)
        defer { try? FileManager.default.removeItem(at: stagedTagged.url.deletingLastPathComponent()) }
        #expect(stagedTagged.displayName == "Dropped Paper.pdf")

        // A real filename from the provider always wins over the embedded title.
        let named = try await PaperDropStager.stage(data: titled, suggestedName: "From Finder.pdf")
        defer { try? FileManager.default.removeItem(at: named.url.deletingLastPathComponent()) }
        #expect(named.displayName == "From Finder.pdf")
    }

    @Test("Publisher production tags are never taken as a paper title")
    func publisherProductionTagsAreNotTitles() {
        let tags = [
            "CMET4035_grabs 1..1",
            "CMET4035_main 1..12",
            "1-s2.0-S0278584626002848-main",
            "Microsoft Word - revision3_final.docx",
            "PowerPoint - Figure 2.pptx",
            "manuscript_v4.tex",
            "NIHMS1234567_supplement",
            "S0278584626002848",
            "doi:10.1016/j.cmet.2025.04.002",
            "Untitled",
            "Layout 1",
        ]
        for tag in tags {
            #expect(StudioViewModel.titleLooksLikePublisherProductionTag(tag), "\(tag)")
            #expect(!StudioViewModel.isUsablePDFTitle(tag), "\(tag)")
            #expect(StudioViewModel.titleNeedsResolution(tag, domain: "Local PDF", url: "/Papers/x.pdf"), "\(tag)")
        }

        let titles = [
            "NAD depletion in skeletal muscle does not compromise muscle function or accelerate aging",
            "Loss of the Y Chromosome: A Review of Molecular Mechanisms",
            "p53 and cancer",
            "COVID-19 vaccines: 2 years on",
            "H5N1 in dairy cattle",
            "COVID-19",
            "A 2024 update on GLP-1 receptor agonists",
            "Attention Is All You Need",
        ]
        for title in titles {
            #expect(!StudioViewModel.titleLooksLikePublisherProductionTag(title), "\(title)")
            #expect(StudioViewModel.isUsablePDFTitle(title), "\(title)")
            #expect(!StudioViewModel.titleNeedsResolution(title, domain: "Local PDF", url: "/Papers/x.pdf"), "\(title)")
        }
    }

    @Test("A same-named Papers file only dedups when it is the same bytes")
    func paperDestinationPathAvoidsAdoptingAnotherPaper() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ForeverLM-DestTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let papers = root.appendingPathComponent("Papers", isDirectory: true)
        try fm.createDirectory(at: papers, withIntermediateDirectories: true)

        let first = root.appendingPathComponent("first.pdf")
        let second = root.appendingPathComponent("second.pdf")
        try Data("%PDF first paper".utf8).write(to: first)
        try Data("%PDF second paper".utf8).write(to: second)
        let preferred = papers.appendingPathComponent("Dropped Paper.pdf").path

        // Nothing there yet: the preferred name is used.
        #expect(StudioViewModel.paperDestinationPath(preferred: preferred, source: first.path, fileManager: fm) == preferred)
        try fm.copyItem(atPath: first.path, toPath: preferred)

        // The same bytes again: same path, so the import dedups onto that row.
        #expect(StudioViewModel.paperDestinationPath(preferred: preferred, source: first.path, fileManager: fm) == preferred)

        // A different paper under the same name moves to a numbered sibling.
        let sibling = papers.appendingPathComponent("Dropped Paper 2.pdf").path
        #expect(StudioViewModel.paperDestinationPath(preferred: preferred, source: second.path, fileManager: fm) == sibling)
        try fm.copyItem(atPath: second.path, toPath: sibling)

        // Re-importing the second paper finds its own sibling rather than a third.
        #expect(StudioViewModel.paperDestinationPath(preferred: preferred, source: second.path, fileManager: fm) == sibling)

        // A file already inside Papers imports onto itself.
        #expect(StudioViewModel.paperDestinationPath(preferred: preferred, source: preferred, fileManager: fm) == preferred)
    }

    private static func makePDFData(title: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "PDFTextExtractorTests", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw NSError(domain: "PDFTextExtractorTests", code: 2)
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test("Structural figure labels map to their physical page captions")
    func figureCaptionRecords() {
        let text = """
        Results
        Fig. 3 | Predictive validity changes the expected discovery yield.
        Ordinary prose mentioning figure skating is not a caption.
        FIGURE S2. Sensitivity analysis for the alternate assumptions.
        Figure 4A — Financial value by validation strategy.
        Figure 3-4. Regeneration of NAD+ by lactate dehydrogenase.
        FIGURE 3–5 Fermentation in mammals and yeast.
        """

        let records = PDFTextExtractor.figureCaptionRecords(in: text)
        #expect(records.map(\.label) == ["Figure 3", "Figure S2", "Figure 4A", "Figure 3-4", "Figure 3–5"])
        #expect(records[0].caption.hasPrefix("Fig. 3"))
        #expect(records[1].caption.hasPrefix("FIGURE S2"))
        #expect(records[2].caption.hasPrefix("Figure 4A"))
    }

    @Test("Extended Data and Supplementary captions are figures of their own, and a reference tail is still not one")
    func extendedDataCaptionsAreIndexed() {
        // Nature prints Extended Data at the back of the same PDF; before index
        // version 2 these lines were skipped and every such figure was lost.
        let text = """
        Extended Data Fig. 1 | Correlation matrix of metabolites associated with
        Extended Data Fig. 2). We observed distinct age-related plasticity
        EXTENDED DATA FIGURE 3 | Elevated NADH/NAD+ ratio drives 2-HG accumulation.
        Supplementary Figure 2. Sensitivity analysis for the alternate assumptions.
        Supplementary Fig. 4a shows the same effect in the replicative model.
        Supplemental Figure 1: Antibody validation.
        Fig. 2 | A mitochondrial electron surplus induces sleep.
        """
        let records = PDFTextExtractor.figureCaptionRecords(in: text)
        #expect(records.map(\.label) == [
            "Extended Data Figure 1", "Extended Data Figure 3", "Supplementary Figure 2", "Supplemental Figure 1", "Figure 2",
        ])
        #expect(records[0].caption.hasPrefix("Extended Data Fig. 1 |"))
        #expect(PaperFigureCaptionTitle.title(from: records[0].caption) == "Correlation matrix of metabolites associated with")
    }

    @Test("A figure reference that opens a line is not indexed as the figure")
    func lineOpeningReferencesAreNotCaptions() {
        // Extracted page text of Nature's 2025 sleep-pressure paper, the page
        // before Figure 2: the "Fig. 2)" lines are the tails of "(Extended
        // Data Fig. 2)" references broken across lines. Indexing them put
        // "Figure 2" on the wrong page twice over, and the duplicate row is
        // what the index table refuses.
        let text = """
        Fig. 2) offers unbiased support for the hypothesis that sleep and aerobic
        Fig. 4d) made NADH-derived electrons in dFBNs redundant and pre-
        Fig. 2). However, it remains ambiguous whether the upregulation of
        Figure 2 shows the same effect in the replicative model.
        Fig. 3e–h), and it was also undetectable in a combined analysis of all
        Fig. 2 | A mitochondrial electron surplus induces sleep. a, Proton-pumping
        Figure 3. Regeneration of NAD+ by lactate dehydrogenase.
        FIGURE 3–5 Fermentation in mammals and yeast.
        Figure 4
        """
        let records = PDFTextExtractor.figureCaptionRecords(in: text)
        #expect(records.map(\.label) == ["Figure 2", "Figure 3", "Figure 3–5", "Figure 4"])
        #expect(records.first?.caption.hasPrefix("Fig. 2 | A mitochondrial") == true)
    }

    @Test("One label printed twice on a page indexes once")
    func duplicateLabelOnOnePageIndexesOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureExtractorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("paper.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let pages: [[String]] = [
            ["Figure 2 | Predictive validity by discovery phase.", "Figure 2 | Predictive validity by discovery phase (continued)."],
            ["Figure 3 | Financial value by validation strategy."],
        ]
        for lines in pages {
            context.beginPDFPage(nil)
            for (row, text) in lines.enumerated() {
                context.textPosition = CGPoint(x: 72, y: 680 - CGFloat(row) * 40)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
                    )
                )
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()

        let document = try #require(PDFDocument(url: pdfURL))
        let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<document.pageCount)
        #expect(indexed.map(\.figureLabel) == ["Figure 2", "Figure 3"])
        #expect(indexed.map(\.pageIndex) == [0, 1])
        #expect(indexed.first?.caption.hasSuffix("phase.") == true)
    }

    @Test("A caption read from text alone runs on until its title sentence closes")
    func captionRunsOnUntilItsTitleCloses() {
        // Fig. 1 of the cardiac-sodium paper as its page prints it: the title
        // wraps twice, with a hyphen at the second break, before the panel
        // descriptions begin. Until 2026-09-21 the record kept the first line.
        let text = """
        Time (min) Time (min)
        Fig. 1 | Intracellular Na elevation and contractility in isolated Langendorff
        perfused rat hearts transiently exposed to 75 μM ouabain and 150 nM para-
        aminoblebbistatin (PAB). a Time-courses of intracellular Na in the absence of PAB
        and b corresponding left ventricular developed pressure (LVDP) measured before
        utilization can also be induced by acute elevation of [Na]i via phar-
        """
        let records = PDFTextExtractor.figureCaptionRecords(in: text)
        #expect(records.count == 1)
        #expect(records[0].label == "Figure 1")
        // Stops once the title sentence has closed; the page's line breaks are kept.
        #expect(records[0].caption == """
        Fig. 1 | Intracellular Na elevation and contractility in isolated Langendorff
        perfused rat hearts transiently exposed to 75 μM ouabain and 150 nM para-
        aminoblebbistatin (PAB). a Time-courses of intracellular Na in the absence of PAB
        """)
        #expect(PaperFigureCaptionTitle.title(from: records[0].caption)
                == "Intracellular Na elevation and contractility in isolated Langendorff perfused rat hearts transiently exposed to 75 μM ouabain and 150 nM para-aminoblebbistatin (PAB)")
        // A caption whose title closes on its own line stays that line.
        let closed = PDFTextExtractor.figureCaptionRecords(in: "Fig. 3 | Predictive validity changes the yield.\nOrdinary prose follows it.")
        #expect(closed.map(\.caption) == ["Fig. 3 | Predictive validity changes the yield."])
        // A lone number under a caption is a folio, not caption.
        let folio = PDFTextExtractor.figureCaptionRecords(in: "Figure 2 | Survival after\n8\ninfluenza infection.")
        #expect(folio.map(\.caption) == ["Figure 2 | Survival after"])
    }

    @Test("A caption read from the page is its whole paragraph, set in its own face, and stops where the body's face begins")
    func captionParagraphIsReadByFont() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureCaptionParagraph_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("paper.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        // Caption lines at 7 pt, one line pitch apart; then a gap and the body at 8.2 pt.
        let lines: [(String, CGFloat, CGFloat)] = [
            ("Fig. 1 | Intracellular Na elevation and contractility in isolated Langendorff", 7, 420),
            ("perfused rat hearts transiently exposed to 75 μM ouabain and 150 nM para-", 7, 410),
            ("aminoblebbistatin (PAB). a Time-courses of intracellular Na in the absence of PAB", 7, 400),
            ("and b corresponding left ventricular developed pressure (LVDP) measured before", 7, 390),
            ("(baseline), during ouabain treatment, and after washout.", 7, 380),
            ("utilization can also be induced by acute elevation of [Na]i via phar-", 8.2, 350),
            ("macological inhibition of the Na/K ATPase (NKA) with ouabain.", 8.2, 340),
        ]
        context.beginPDFPage(nil)
        for (text, size, y) in lines {
            context.textPosition = CGPoint(x: 40, y: y)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
                )
            )
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(url: pdfURL))
        let page = try #require(document.page(at: 0))
        let records = PDFTextExtractor.figureCaptionRecords(on: page)
        #expect(records.count == 1)
        let caption = try #require(records.first?.caption)
        #expect(caption.hasPrefix("Fig. 1 | Intracellular Na elevation"))
        #expect(caption.hasSuffix("during ouabain treatment, and after washout."))
        #expect(!caption.contains("utilization"))
        #expect(caption.components(separatedBy: "\n").count == 5)
        // The stored caption is still a literal piece of the page's text, so
        // its first line can be found on the page.
        #expect(page.string?.contains(caption) == true)
        #expect(PaperFigureRectRefiner.captionBounds(of: caption, on: page) != nil)
        // The title reads across the breaks, hyphen closed up.
        #expect(PaperFigureCaptionTitle.title(from: caption)
                == "Intracellular Na elevation and contractility in isolated Langendorff perfused rat hearts transiently exposed to 75 μM ouabain and 150 nM para-aminoblebbistatin (PAB)")
        let indexed = PDFTextExtractor.indexedFigures(from: document, pages: 0..<1)
        #expect(indexed.map(\.caption) == [caption])
    }

    @Test("Figure IDs are stable and page-specific")
    func stableFigureIdentity() {
        let first = PaperFigureIndexContract.figureID(
            sourceID: "paper-1",
            figureLabel: "Figure 2",
            pageIndex: 4
        )
        let same = PaperFigureIndexContract.figureID(
            sourceID: "paper-1",
            figureLabel: "figure 2",
            pageIndex: 4
        )
        let otherPage = PaperFigureIndexContract.figureID(
            sourceID: "paper-1",
            figureLabel: "Figure 2",
            pageIndex: 5
        )

        #expect(first == same)
        #expect(first != otherPage)
        #expect(first.hasPrefix("fig_"))
    }

    @Test("A structural figure caption indexes its physical PDF page and writes nothing")
    func indexedFigureRecordsPhysicalPage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureExtractorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("paper.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for text in ["Introduction", "Figure 2 | Predictive validity by discovery phase."] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 680)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
                )
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        let document = try #require(PDFDocument(url: pdfURL))
        let indexed = PDFTextExtractor.indexedFigures(
            from: document,
            pages: 0..<document.pageCount
        )

        let figure = try #require(indexed.first)
        #expect(indexed.count == 1)
        #expect(figure.figureLabel == "Figure 2")
        #expect(figure.pageIndex == 1)

        // Indexing is pure: the only new file in the directory is the PDF that
        // was put there to be read.
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(written == ["paper.pdf"])

        // Pixels are produced on demand instead, straight out of the document.
        let rendered = try #require(
            PDFTextExtractor.pageJPEGData(from: document, pageIndex: figure.pageIndex)
        )
        #expect(rendered.count > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["paper.pdf"])

        // Canonical text carries a portable page reference, not a local path.
        let text = PDFTextExtractor.textWithFigureReferences(
            from: document,
            pages: 0..<document.pageCount
        )
        #expect(text.contains("## Figures"))
        #expect(text.contains("- Figure 2 — page 2"))
        #expect(!text.contains("file://"))
    }

    @Test("The figure image sweep removes only directories this app generated")
    func figureImageSweepIsNarrow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperFigureSweepTests_\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        // Generated: nested exactly as indexing wrote it.
        let generated = root
            .appendingPathComponent("Papers/Figures/some-source-id", isDirectory: true)
        try fm.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: generated.appendingPathComponent("page-0001.jpg"))
        try Data("jpeg".utf8).write(to: generated.appendingPathComponent("page-0014.jpg"))

        // Somebody's own folder that happens to be called Figures.
        let personal = root
            .appendingPathComponent("Courses/Stats/Figures/my-notes", isDirectory: true)
        try fm.createDirectory(at: personal, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: personal.appendingPathComponent("scan.png"))
        try Data("jpeg".utf8).write(to: personal.appendingPathComponent("page-0002.jpg"))

        // An ordinary source file that must survive untouched.
        let paper = root.appendingPathComponent("Papers/paper.pdf")
        try Data("%PDF".utf8).write(to: paper)

        let removed = await PaperFigureImageSweeper.sweep(roots: [root.path])

        #expect(removed == 1)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Papers/Figures").path))
        #expect(fm.fileExists(atPath: paper.path))
        #expect(fm.fileExists(atPath: personal.appendingPathComponent("scan.png").path))
        #expect(fm.fileExists(atPath: personal.appendingPathComponent("page-0002.jpg").path))

        // Running again finds nothing left to do.
        #expect(await PaperFigureImageSweeper.sweep(roots: [root.path]) == 0)
    }
}
