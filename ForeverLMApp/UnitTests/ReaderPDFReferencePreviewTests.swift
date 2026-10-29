import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Reader PDF reference preview")
struct ReaderPDFReferencePreviewTests {
    @Test("A citation linked by named destination previews its own entry, ending where the next begins")
    func namedDestinationCitation() throws {
        let document = try Self.paper(numbers: .inline)
        #expect(try Self.entry(ofLink: 0, in: document) == "1. Smith, A., and Lee, B. (2020). Segmenting the shapes of mitochondrial networks. Nat. Methods 17, 101-109.")
        let second = try #require(try Self.entry(ofLink: 1, in: document))
        #expect(second.hasPrefix("2. Jones"))
        #expect(second.hasSuffix("Cell 7, 1-9."))
    }

    @Test("An uncited entry after a cited one is split off at the hanging-indent margin")
    func uncitedNeighbourIsSplitOff() throws {
        let document = try Self.paper(numbers: .inline)
        let second = try #require(try Self.entry(ofLink: 1, in: document))
        #expect(!second.contains("Brown"))
        #expect(!second.contains("footer"))
    }

    @Test("Entry numbers set in a column of their own still preview the whole entry")
    func numberColumn() throws {
        let document = try Self.paper(numbers: .column)
        let first = try #require(try Self.entry(ofLink: 0, in: document))
        #expect(first.hasPrefix("1."))
        #expect(first.contains("Smith"))
        #expect(first.contains("mitochondrial networks"))
        #expect(!first.contains("Jones"))
    }

    @Test("A link to a web address, or to a height alone at the page's edge, lands nowhere")
    func nonCitationLinksHaveNoTarget() throws {
        let document = try Self.paper(numbers: .inline)
        let targets = PDFReferenceEntries.targets(in: document)
        // Two citations; the web link and the edge-only destination are left out.
        #expect(targets[0]?.count == 2)
    }

    @Test("A word hyphenated across a line closes up; a hyphen before a capital stays")
    func joinedLines() {
        #expect(PDFReferenceEntries.joined(["the biologi-", "cally relevant"]) == "the biologically relevant")
        #expect(PDFReferenceEntries.joined(["Hart-", "Wells, A."]) == "Hart-Wells, A.")
        #expect(PDFReferenceEntries.joined(["one", "two"]) == "one two")
        #expect(PDFReferenceEntries.joined(["Cell Rep. 17, 1–9 (2016). doi: 10.1016/j.celrep.", "2016.10.061; pmid: 27851967"]) == "Cell Rep. 17, 1–9 (2016). doi: 10.1016/j.celrep.2016.10.061; pmid: 27851967")
        #expect(PDFReferenceEntries.joined(["https://doi.org/10.1186/s13059-017-", "1382-0."]) == "https://doi.org/10.1186/s13059-017-1382-0.")
        #expect(PDFReferenceEntries.joined(["Nat. Methods 16, 999 (2019). doi: 10.1038/s41592-019-", "0547-z"]) == "Nat. Methods 16, 999 (2019). doi: 10.1038/s41592-019-0547-z")
        // A DOI that ends its sentence leaves the next line's words apart.
        #expect(PDFReferenceEntries.joined(["https://doi.org/10.1016/j.cell.2014.11.021.", "Published online"]) == "https://doi.org/10.1016/j.cell.2014.11.021. Published online")
        #expect(PDFReferenceEntries.joined(["Biol. (2025) doi:10.1101/2025.01.28.635306.", "Zachariah, R., et al., 2009."]) == "Biol. (2025) doi:10.1101/2025.01.28.635306. Zachariah, R., et al., 2009.")
    }

    @Test("The DOI a reference entry prints is read without the sentence's closing punctuation")
    func doiInEntry() {
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "Cell Host Microbe 13, 129–142. https://doi.org/10.1016/j.chom.2013.01.008.") == "10.1016/j.chom.2013.01.008")
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "(see doi:10.1002/(SICI)1097-0177(200001)217:1<2::AID-DVDY2>3.0.CO;2-8)") == "10.1002/(SICI)1097-0177(200001)217:1")
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "Nat. Methods 22, 1742–1752 (2025).") == nil)
    }

    @Test("A DOI keeps the hyphens a journal typesets in it and stops at text that is not ASCII")
    func doiTypesetting() {
        // Science's soft hyphens, BMC's non-breaking ones.
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "Genome Biol. 21, 294 (2020). doi: 10.1186/s13059-\u{00AD}020-\u{00AD}02210-\u{00AD}0; pmid: 1") == "10.1186/s13059-020-02210-0")
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "https://doi.org/10.1186/s13024\u{2011}016\u{2011}0099-y") == "10.1186/s13024-016-0099-y")
        // A spacing accent from the next entry's first line ("Ferna´ndez").
        #expect(PDFReferenceEntries.doi(inReferenceEntry: "Nature 558, 136–140. https://doi.org/10.1038/s41586-018-0162-7.´") == "10.1038/s41586-018-0162-7")
    }

    @Test("An entry stops at the line that starts the next number, cited or not, and leaves the page number out")
    func entryStopsAtNextNumber() {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat) -> PDFReferenceEntries.Line {
            PDFReferenceEntries.Line(text: text, bounds: CGRect(x: x, y: y, width: 200, height: 8), continuesWord: false)
        }
        // Nature Metabolism: the last entry in a column, then the next
        // column's numbers set in a block of their own.
        let lastInColumn = [
            line("16.", 39, 66), line("Bahat, A., MacVicar, T. & Langer, T. Metabolism and innate", 56, 66),
            line("immunity meet at the mitochondria. Front. Cell Dev. Biol. 9,", 56, 56),
            line("720490 (2021).", 56, 45), line("17.", 306, 733), line("18.", 306, 711),
        ]
        #expect(PDFReferenceEntries.linesBeforeNumber(after: lastInColumn).map(\.text).last == "720490 (2021).")
        let beforeFooter = [line("1. Kirkland, J. L. & Tchkonia, T. Cellular senescence.", 39, 80), line("EBioMedicine 21, 21–28 (2017).", 56, 70), line("754", 290, 30)]
        #expect(PDFReferenceEntries.linesBeforeNumber(after: beforeFooter).count == 2)
        // A number that is not the next entry's stays.
        let volume = [line("[4] Lee, S. Nat. Cell Biol.", 39, 80), line("5 (2019), 94–101.", 56, 70)]
        #expect(PDFReferenceEntries.linesBeforeNumber(after: volume).count == 2)
    }

    @Test("A title is printed in an entry whatever the spacing, line splits and markup")
    func titlePrintedInEntry() {
        let entry = "33. Chandrasekaran, S.N., et al. (2024). Morphological map of under- and over-expression of genes in hu man cells. Nat. Methods 22, 1742–1752."
        #expect(SlideCitationService.referenceEntry(entry, printsTitle: "Morphological map of under- and over-expression of genes in human cells"))
        #expect(SlideCitationService.referenceEntry("Kleene KC. 2001. Growth of <i>E. coli</i> in broth culture media. Mech Dev.", printsTitle: "Growth of <i>E. coli</i> in broth culture media"))
        #expect(!SlideCitationService.referenceEntry(entry, printsTitle: "Morphological map of genes in mouse cells"))
        // Too short to name a paper by containment.
        #expect(!SlideCitationService.referenceEntry(entry, printsTitle: "Nat. Methods"))
    }

    @Test("A citation in a paper the reader assembled from its file previews its entry, read from that file")
    func assembledDocumentCitation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try ["first", "second"].map { name in
            let url = directory.appendingPathComponent("\(name).pdf")
            try Self.paperData(numbers: .inline).write(to: url)
            return url.path
        }
        // Every local PDF opens assembled, a lone paper as a book of one
        // chapter: an in-memory document with no file of its own.
        let inputs = try paths.enumerated().map { index, path in
            BookPDFAssembly.Input(
                sourceID: "src_\(index)", title: "Paper \(index)", path: path,
                document: try #require(PDFDocument(url: URL(fileURLWithPath: path)))
            )
        }
        let assembly = try #require(BookPDFAssembly.assemble(inputs))
        #expect(assembly.document.documentURL == nil)

        // The second chapter's body page is page 2 of the book, page 0 of its file.
        let bookPage = try #require(assembly.document.page(at: 2))
        let link = try #require(bookPage.annotations.filter { $0.type == "Link" }.min { $0.bounds.minX < $1.bounds.minX })
        let chapter = try #require(ReaderPDFReferencePreview.chapter(
            ofPage: 2, in: assembly.map.chapters, documentPageCount: assembly.document.pageCount
        ))
        #expect(chapter.path == paths[1])
        let entries = PDFReferenceEntries(.file(URL(fileURLWithPath: chapter.path)))
        let entry = await entries.entry(for: .init(pageIndex: 2 - chapter.pageRange.lowerBound, bounds: link.bounds))
        #expect(entry?.hasPrefix("1. Smith") == true)

        // Chapters that do not fill the document are another document's.
        #expect(ReaderPDFReferencePreview.chapter(ofPage: 2, in: assembly.map.chapters, documentPageCount: 5) == nil)
    }

    @Test("An entry names the library source with the DOI it prints, else the one whose title it prints")
    func librarySourceForEntry() {
        let candidates = [
            PDFReferenceEntries.LibraryCandidate(id: "bobkova", dois: ["https://doi.org/10.1073/PNAS.1516131112"], title: "Something else"),
            PDFReferenceEntries.LibraryCandidate(id: "short", dois: [], title: "Organelle dynamics in living cells"),
            PDFReferenceEntries.LibraryCandidate(id: "long", dois: [], title: "Live imaging of organelle dynamics in living cells"),
        ]
        let withDOI = "35. Bobkova, N.V., et al. (2015). Exogenous Hsp70 delays senescence. Proc. Natl. Acad. Sci. USA 112, 16006–16011. https://doi.org/10.1073/pnas.1516131112."
        #expect(PDFReferenceEntries.librarySourceID(forEntry: withDOI, in: candidates) == "bobkova")
        // A DOI the library lacks is not matched by title instead.
        #expect(PDFReferenceEntries.librarySourceID(forEntry: "Doe, J. Live imaging of organelle dynamics in living cells. https://doi.org/10.1016/j.cell.2020.01.001", in: candidates) == nil)
        #expect(PDFReferenceEntries.librarySourceID(forEntry: "2. Jones, C. (2021). Live imaging of organelle dy namics in living cells. Cell 7, 1-9.", in: candidates) == "long")
        #expect(PDFReferenceEntries.librarySourceID(forEntry: "3. Brown, D. (2019). An entry that nobody cites.", in: candidates) == nil)
    }

    @MainActor
    @Test("Clicking a citation in an assembled paper in the reader's PDF view shows the card with its entry")
    func clickShowsCardInAssembledPaper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try ["first", "second"].map { name in
            let url = directory.appendingPathComponent("\(name).pdf")
            try Self.paperData(numbers: .inline).write(to: url)
            return url.path
        }
        let inputs = try paths.enumerated().map { index, path in
            BookPDFAssembly.Input(
                sourceID: "src_\(index)", title: "Paper \(index)", path: path,
                document: try #require(PDFDocument(url: URL(fileURLWithPath: path)))
            )
        }
        let assembly = try #require(BookPDFAssembly.assemble(inputs))

        // On screen but invisible: a popover needs a window to show from.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let pdfView = FindablePDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        pdfView.displayMode = .singlePage
        pdfView.autoScales = true
        pdfView.document = assembly.document
        window.contentView = pdfView
        window.orderFrontRegardless()
        defer { window.close() }
        let preview = ReaderPDFReferencePreview()
        preview.attach(to: pdfView)
        preview.chapterFiles = assembly.map.chapters
        defer { preview.detach() }

        let bookPage = try #require(assembly.document.page(at: 2))
        pdfView.go(to: bookPage)
        pdfView.layoutDocumentView()
        let link = try #require(bookPage.annotations.filter { $0.type == "Link" }.min { $0.bounds.minX < $1.bounds.minX })
        #expect(pdfView.linkClicked?(link) == true)

        // The card only opens on an entry read from the chapter's file; the
        // entry's text is checked by assembledDocumentCitation above.
        var popover: NSWindow?
        for _ in 0..<100 where popover == nil {
            try await Task.sleep(for: .milliseconds(20))
            popover = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        #expect(popover != nil)
        // The pointer leaving the page for the card, or a click moving focus
        // onto it, reads to the reader as the pointer leaving: a card opened
        // by a click stays.
        let exit = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        pdfView.mouseExited(with: exit)
        try await Task.sleep(for: .milliseconds(600))
        #expect(popover?.isVisible == true)
    }

    @Test("A citation linked by a page-wide band of one line reads the entry in the column its number names")
    func pageWideBandCitation() async throws {
        let paper = Self.bandPaper(rightColumnNumbers: [1, 2, 3])
        let entries = PDFReferenceEntries(.bytes(paper.data))
        let entry = try #require(await entries.entry(for: .init(pageIndex: 0, bounds: paper.link)))
        // The left column has a line in the same band; the entry is the
        // right column's, numbered as the link is.
        #expect(entry.hasPrefix("2. Jones"))
        #expect(!entry.contains("Methods"))
        let landing = try #require(await entries.landing(for: .init(pageIndex: 0, bounds: paper.link)))
        #expect(landing.point.x > 300)
    }

    @Test("A page-wide band with no line numbered as the link shows nothing rather than another column's text")
    func pageWideBandWithoutMatchingNumber() async throws {
        let paper = Self.bandPaper(rightColumnNumbers: [1, 3, 4])
        let entries = PDFReferenceEntries(.bytes(paper.data))
        #expect(await entries.entry(for: .init(pageIndex: 0, bounds: paper.link)) == nil)
    }

    @Test("A page-wide band as tall as a paragraph names no line")
    func pageWideBandTooTall() throws {
        let paper = Self.bandPaper(rightColumnNumbers: [1, 2, 3], bandHeight: 200)
        let document = try #require(PDFDocument(data: paper.data))
        #expect(PDFReferenceEntries.targets(in: document)[0] == nil)
    }

    // MARK: Fixture

    private static func entry(ofLink index: Int, in document: PDFDocument) throws -> String? {
        let targets = PDFReferenceEntries.targets(in: document)
        let links = try #require(targets[0]).sorted { $0.bounds.minX < $1.bounds.minX }
        guard links.indices.contains(index) else { return nil }
        let landing = links[index].landing
        let landings = PDFReferenceEntries.landingsByPage(targets)
        var starts: [Int: [Int]] = [:]
        for pageIndex in [landing.pageIndex, landing.pageIndex + 1] {
            guard let page = document.page(at: pageIndex) else { continue }
            starts[pageIndex] = PDFReferenceEntries.entryStarts(on: page, landings: landings[pageIndex] ?? [])
        }
        return PDFReferenceEntries.entryText(at: landing, in: document, entryStarts: starts)
    }

    enum Numbers { case inline, column }

    /// Two pages: body text citing 1 and 2 (by named destination, as Cell
    /// Press links them), a web link, and a link to a height at the page's
    /// edge; then a reference list with hanging indents whose first entry
    /// wraps, whose third entry nobody cites, and whose page ends in a footer.
    private static func paper(numbers: Numbers) throws -> PDFDocument {
        try #require(PDFDocument(data: try paperData(numbers: numbers)))
    }

    private static func paperData(numbers: Numbers) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func draw(_ text: String, x: CGFloat, baseline: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }

        context.beginPDFPage(nil)
        draw("Deep learning methods have improved feature extraction 1 2 but most, see the site and above.", x: 72, baseline: 700)
        context.setDestination("bib1" as CFString, for: CGRect(x: 346, y: 698, width: 6, height: 12))
        context.setDestination("bib2" as CFString, for: CGRect(x: 356, y: 698, width: 6, height: 12))
        context.setURL(URL(string: "https://example.org")! as CFURL, for: CGRect(x: 420, y: 698, width: 20, height: 12))
        context.setDestination("edge" as CFString, for: CGRect(x: 470, y: 698, width: 30, height: 12))
        context.endPDFPage()

        context.beginPDFPage(nil)
        let entries: [(number: String, lines: [String])] = [
            ("1.", ["Smith, A., and Lee, B. (2020). Segmenting the shapes of", "mitochondrial networks. Nat. Methods 17, 101-109."]),
            ("2.", ["Jones, C. (2021). Live imaging of organelle dynamics.", "Cell 7, 1-9."]),
            ("3.", ["Brown, D. (2019). An entry that nobody cites.", "Science 1, 2-3."]),
        ]
        var baseline: CGFloat = 700
        for (index, entry) in entries.enumerated() {
            if index < 2 {
                context.addDestination("bib\(index + 1)" as CFString, at: CGPoint(x: 70, y: baseline + 10))
            }
            for (lineIndex, line) in entry.lines.enumerated() {
                switch numbers {
                case .inline:
                    draw(lineIndex == 0 ? "\(entry.number) \(line)" : line, x: lineIndex == 0 ? 72 : 84, baseline: baseline)
                case .column:
                    if lineIndex == 0 { draw(entry.number, x: 72, baseline: baseline) }
                    draw(line, x: 88, baseline: baseline)
                }
                baseline -= 12
            }
            baseline -= 4
        }
        context.addDestination("edge" as CFString, at: CGPoint(x: 0, y: 700))
        draw("Cell Reports footer 17", x: 72, baseline: 80)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// One page of two columns set on shared baselines: methods text on the
    /// left, a numbered reference list on the right, and above them a link
    /// over the number 2 to the named destination `bib2`, which is a
    /// rectangle the width of the page and the height of the line numbered 2
    /// (its edges written top first, as Springer Nature writes them).
    private static func bandPaper(rightColumnNumbers: [Int], bandHeight: CGFloat = 12) -> (data: Data, link: CGRect) {
        let names = ["Smith, A. Segmenting shapes.", "Jones, C. Live imaging of organelles.", "Brown, D. Another entry.", "Green, E. Last entry."]
        var content = "BT /F1 10 Tf 72 740 Td (Citing reference) Tj ET\nBT /F1 10 Tf 200 740 Td (2) Tj ET\n"
        var lineOfTwo: CGFloat = 0
        for (index, number) in rightColumnNumbers.enumerated() {
            let baseline = CGFloat(400 - 12 * index)
            content += "BT /F1 10 Tf 72 \(baseline) Td (Methods text in the left column \(index).) Tj ET\n"
            content += "BT /F1 10 Tf 320 \(baseline) Td (\(number). \(names[number - 1])) Tj ET\n"
            if number == 2 { lineOfTwo = baseline }
        }
        let top = lineOfTwo + 9
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests 6 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [7 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Names [(bib2) << /D [3 0 R /FitR 0 \(top) 612 \(top - bandHeight)] >>] >>",
            "<< /Type /Annot /Subtype /Link /Rect [199 738 206 750] /Border [0 0 0] /Dest (bib2) >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return (Data(pdf.utf8), CGRect(x: 199, y: 738, width: 7, height: 12))
    }
}
