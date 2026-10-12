import AppKit
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("ReaderPageNavigation")
struct ReaderPageNavigationTests {
    private let navigation = ReaderPageNavigation(currentPage: 129, pageCount: 1532)

    @Test("The label is one-based, in the numbering the learner types back")
    func label() {
        #expect(navigation.label == "130 of 1532")
        #expect(ReaderPageNavigation(currentPage: 0, pageCount: 1).label == "1 of 1")
    }

    @Test("A typed page number becomes the document's page index")
    func entries() {
        #expect(navigation.pageIndex(forEntry: "1") == 0)
        #expect(navigation.pageIndex(forEntry: " 1362 ") == 1361)
        #expect(navigation.pageIndex(forEntry: "1,379") == 1378)
        #expect(navigation.pageIndex(forEntry: "1532") == 1531)
    }

    @Test("Anything that is not a page of the document is not a jump")
    func rejectedEntries() {
        #expect(navigation.pageIndex(forEntry: "0") == nil)
        #expect(navigation.pageIndex(forEntry: "1533") == nil)
        #expect(navigation.pageIndex(forEntry: "-3") == nil)
        #expect(navigation.pageIndex(forEntry: "") == nil)
        #expect(navigation.pageIndex(forEntry: "p. 12") == nil)
        #expect(navigation.pageIndex(forEntry: "12.5") == nil)
    }
}

@Suite("BookPageMap")
struct BookPageMapTests {
    private let map = BookPageMap(chapters: [
        .init(sourceID: "intro", title: "The Path to Biological Numeracy", path: "/b/01.pdf", pageCount: 20),
        .init(sourceID: "size", title: "1) Size & Geometry", path: "/b/02.pdf", pageCount: 69),
        .init(sourceID: "empty", title: "Missing", path: "/b/03.pdf", pageCount: 0),
        .init(sourceID: "rates", title: "4) Rates & Durations", path: "/b/05.pdf", pageCount: 79),
    ])

    @Test("Chapters occupy contiguous page runs and a chapter without pages is left out")
    func contiguousRanges() {
        #expect(map.chapters.map(\.pageRange) == [0..<20, 20..<89, 89..<168])
        #expect(map.pageCount == 168)
        #expect(map.chapter(forSourceID: "empty") == nil)
        #expect(BookPageMap(chapters: []).isEmpty)
    }

    @Test("A page of the book turns back into a page of its chapter")
    func positions() {
        #expect(map.position(ofPage: 0) == .init(chapter: map.chapters[0], pageInChapter: 0))
        #expect(map.position(ofPage: 19)?.pageInChapter == 19)
        #expect(map.position(ofPage: 20) == .init(chapter: map.chapters[1], pageInChapter: 0))
        #expect(map.position(ofPage: 100)?.chapter.sourceID == "rates")
        #expect(map.position(ofPage: 100)?.pageInChapter == 11)
        #expect(map.position(ofPage: 168) == nil)
        #expect(map.position(ofPage: -1) == nil)
    }

    @Test("A chapter opens at its saved page when that page still exists, else at its start")
    func resumePage() {
        #expect(map.page(forSourceID: "rates") == 89)
        #expect(map.page(forSourceID: "rates", chapterPage: 0) == 89)
        #expect(map.page(forSourceID: "rates", chapterPage: 11) == 100)
        #expect(map.page(forSourceID: "rates", chapterPage: 79) == 89)
        #expect(map.page(forSourceID: "size", chapterPage: -3) == 20)
        #expect(map.page(forSourceID: "unknown", chapterPage: 2) == nil)
    }

    @Test("Contents navigation marks the chapter holding the current page")
    func navigation() {
        let navigation = map.navigation(currentPage: 25)
        #expect(navigation?.items.map(\.id) == ["intro", "size", "rates"])
        #expect(navigation?.items.map(\.title) == [
            "The Path to Biological Numeracy", "1) Size & Geometry", "4) Rates & Durations",
        ])
        #expect(navigation?.currentItem?.id == "size")
        #expect(navigation?.previousItem?.id == "intro")
        #expect(navigation?.nextItem?.id == "rates")
        #expect(navigation?.positionLabel == "2 of 3")
        #expect(map.navigation(currentPage: nil)?.currentItem == nil)
        #expect(map.navigation(currentPage: 500)?.currentItem == nil)
    }

    @Test("A book of one chapter has no contents to navigate")
    func singleChapter() {
        let single = BookPageMap(chapters: [
            .init(sourceID: "only", title: "Only", path: "/b/01.pdf", pageCount: 5),
        ])
        #expect(single.navigation(currentPage: 2) == nil)
        #expect(single.sections == [PDFDocumentSection(sourceID: "only", pageRange: 0..<5)])
    }

    @Test("Sections hand each page's notes to the chapter it came from")
    func sections() {
        #expect(map.sections.map(\.sourceID) == ["intro", "size", "rates"])
        #expect(map.sections[2].pageRange == 89..<168)
    }
}

@Suite("BookPDFAssembly")
struct BookPDFAssemblyTests {
    /// A PDF with one line of real, extractable text per page.
    private static func textPDF(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            ).draw(at: CGPoint(x: 20, y: 100))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    private func assembled() throws -> (BookPDFAssembly, PDFDocument, PDFDocument) {
        let first = try Self.textPDF(pages: ["alpha one", "alpha two"])
        let second = try Self.textPDF(pages: ["beta one", "beta two", "beta three"])
        let assembly = try #require(BookPDFAssembly.assemble([
            .init(sourceID: "a", title: "A", path: "/a.pdf", document: first),
            .init(sourceID: "b", title: "B", path: "/b.pdf", document: second),
        ]))
        return (assembly, first, second)
    }

    @Test("Chapter pages are copied in order and the chapter documents stay whole")
    func assemblesInOrder() throws {
        let (assembly, first, second) = try assembled()
        #expect(assembly.document.pageCount == 5)
        #expect(assembly.map.chapters.map(\.pageRange) == [0..<2, 2..<5])
        #expect(assembly.document.page(at: 3)?.string?.contains("beta two") == true)
        #expect(assembly.document.page(at: 3)?.document === assembly.document)
        #expect(first.pageCount == 2)
        #expect(second.pageCount == 3)
        #expect(second.page(at: 1)?.document === second)
        #expect(BookPDFAssembly.assemble([]) == nil)
    }

    @Test("Find covers the whole book")
    func findSpansChapters() throws {
        let (assembly, _, _) = try assembled()
        let matches = assembly.document.findString("one", withOptions: [.caseInsensitive])
        let pages = matches.compactMap { $0.pages.first }.map { assembly.document.index(for: $0) }
        #expect(pages == [0, 2])
    }

    @Test("A note made in a chapter is anchored in that chapter's own pages")
    func anchorsAreChapterRelative() throws {
        let (assembly, _, _) = try assembled()
        let selection = try #require(
            assembly.document.findString("beta two", withOptions: [.caseInsensitive]).first
        )
        let chapter = assembly.map.chapters[1]

        let inChapter = try #require(ReaderPDFHighlightSupport.anchors(
            for: selection,
            in: assembly.document,
            pageRange: chapter.pageRange
        ))
        #expect(inChapter.pdf.pageIndex == 1)
        // "beta one" collapsed, plus the page break: where page two's text begins.
        #expect(inChapter.text.offset == "beta one".count + 1)
        #expect(inChapter.text.exact == "beta two")

        let inBook = try #require(ReaderPDFHighlightSupport.anchors(
            for: selection,
            in: assembly.document
        ))
        #expect(inBook.pdf.pageIndex == 3)
        #expect(inBook.text.offset == "alpha one".count + 1 + "alpha two".count + 1 + "beta one".count + 1)

        // A selection outside the chapter's pages is not the chapter's note.
        #expect(ReaderPDFHighlightSupport.anchors(
            for: selection,
            in: assembly.document,
            pageRange: assembly.map.chapters[0].pageRange
        ) == nil)
    }

    @Test("A chapter's saved note paints onto its page of the book, and re-anchors within the chapter")
    func paintsWithinChapter() throws {
        let (assembly, _, _) = try assembled()
        let chapter = assembly.map.chapters[1]
        let stored = SourceHighlight(
            id: "hl_stored",
            sourceID: "b",
            quote: "beta two",
            note: "",
            color: .yellow,
            anchor: ReaderTextAnchor(exact: "beta two"),
            pdfAnchor: ReaderPDFAnchor(pageIndex: 1, rects: [CGRect(x: 20, y: 100, width: 60, height: 14)]),
            createdAt: Date(),
            updatedAt: Date()
        )
        // Quads that no longer match their page fall back to the chapter's text.
        let stale = SourceHighlight(
            id: "hl_stale",
            sourceID: "b",
            quote: "beta three",
            note: "",
            color: .green,
            anchor: ReaderTextAnchor(exact: "beta three"),
            pdfAnchor: ReaderPDFAnchor(pageIndex: 1, rects: [CGRect(x: 20, y: 100, width: 60, height: 14)]),
            createdAt: Date(),
            updatedAt: Date()
        )

        let painted = ReaderPDFHighlightSupport.paint(
            [stored, stale],
            into: assembly.document,
            pageRange: chapter.pageRange
        )
        let pages = painted.compactMap { $0.page }.map { assembly.document.index(for: $0) }
        #expect(pages.contains(3))
        #expect(pages.contains(4))
        #expect(!pages.contains(1))
        #expect(painted.allSatisfy { ReaderPDFHighlightSupport.isNoteAnnotation($0) })
        #expect(painted.map { ReaderPDFHighlightSupport.highlightID(for: $0) }.contains("hl_stale"))

        ReaderPDFHighlightSupport.remove(painted)
        #expect(painted.allSatisfy { $0.page == nil })
    }
}

@Suite("BookSectionIndex")
struct BookSectionIndexTests {
    private typealias Line = BookSectionIndex.Line

    private func body(_ count: Int = 20) -> [Line] {
        (0..<count).map { _ in Line(text: "Water is a polar material and its molecules carry a dipole.", pointSize: 11) }
    }

    @Test("Large headings past the chapter's first page become its sections, in page order")
    func headingsBecomeSections() {
        let pages: [[Line]] = [
            [Line(text: "Chapter 3: Energies and Forces", pointSize: 24)] + body(),
            body(),
            [Line(text: "What is the energy of a", pointSize: 18),
             Line(text: "hydrogen bond?", pointSize: 18)] + body(),
            body(),
            [Line(text: "What is the energy scale associated with the hydrophobic effect?", pointSize: 18),
             Line(text: "203", pointSize: 11)] + body(),
        ]
        #expect(BookSectionIndex.headingSections(pages: pages) == [
            BookChapterSection(title: "What is the energy of a hydrogen bond?", pageInChapter: 2),
            BookChapterSection(title: "What is the energy scale associated with the hydrophobic effect?", pageInChapter: 4),
        ])
    }

    @Test("A running head, a page number and a lone heading are not a table of contents")
    func noiseIsDropped() {
        let runningHead = Line(text: "Cell Biology by the Numbers", pointSize: 16)
        let pages: [[Line]] = [body(), [runningHead] + body(), [runningHead] + body(), [runningHead] + body(),
                               [Line(text: "204", pointSize: 20)] + body()]
        #expect(BookSectionIndex.headingSections(pages: pages).isEmpty)
        let lone: [[Line]] = [body(), [Line(text: "Only one heading here", pointSize: 18)] + body()]
        #expect(BookSectionIndex.headingSections(pages: lone).isEmpty)
    }

    @Test("Of two heading sizes, the larger that opens two sections is the section level")
    func oneLevel() {
        let pages: [[Line]] = [
            body(),
            [Line(text: "How big are viruses?", pointSize: 18), Line(text: "Capsid geometry", pointSize: 15)] + body(),
            [Line(text: "Envelope sizes", pointSize: 15)] + body(),
            [Line(text: "How big is a yeast cell?", pointSize: 18)] + body(),
        ]
        #expect(BookSectionIndex.headingSections(pages: pages).map(\.title) == [
            "How big are viruses?", "How big is a yeast cell?",
        ])
    }

    @Test("Sections are listed under their chapter at pages of the book, and the one being read is marked")
    func navigationSections() {
        let map = BookPageMap(chapters: [
            .init(sourceID: "intro", title: "Intro", path: "/b/01.pdf", pageCount: 20),
            .init(sourceID: "energy", title: "3) Energies and Forces", path: "/b/04.pdf", pageCount: 61),
        ])
        let sections = ["energy": [
            BookChapterSection(title: "Thermal energy", pageInChapter: 2),
            BookChapterSection(title: "Hydrogen bonds", pageInChapter: 7),
            BookChapterSection(title: "Past the end", pageInChapter: 61),
        ]]
        let before = map.navigation(currentPage: 21, sections: sections)
        #expect(before?.items[1].sections.map(\.pageIndex) == [22, 27])
        #expect(before?.items[0].sections.isEmpty == true)
        #expect(before?.currentSectionID == nil)
        let reading = map.navigation(currentPage: 30, sections: sections)
        #expect(reading?.currentSectionID == reading?.items[1].sections[1].id)
        #expect(map.navigation(currentPage: 5, sections: sections)?.currentSectionID == nil)
    }

    @Test("A chapter file's own bookmarks are its sections")
    func outlineSections() throws {
        let document = PDFDocument()
        for _ in 0..<4 { document.insert(PDFPage(), at: document.pageCount) }
        let root = PDFOutline()
        for (index, title) in [(1, "First"), (3, "Second")] {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: try #require(document.page(at: index)), at: .zero)
            root.insertChild(item, at: root.numberOfChildren)
        }
        document.outlineRoot = root
        #expect(BookSectionIndex.outlineSections(of: document) == [
            BookChapterSection(title: "First", pageInChapter: 1),
            BookChapterSection(title: "Second", pageInChapter: 3),
        ])
    }

    @Test("Import keeps the bookmarks one level below each chapter, relative to its first page")
    func importSectionEntries() {
        let entries: [(title: String, pageIndex: Int, depth: Int)] = [
            ("Part I", 0, 0),
            ("Chapter 1", 0, 1), ("1.1", 2, 2), ("1.1.1", 3, 3), ("1.2", 6, 2),
            ("Chapter 2", 10, 1), ("2.1", 12, 2),
        ]
        let first = StudioViewModel.pdfChapterSectionEntries(entries, pages: 0...9)
        #expect(first.map { $0.title } == ["1.1", "1.2"])
        #expect(first.map { $0.pageIndex } == [2, 6])
        let second = StudioViewModel.pdfChapterSectionEntries(entries, pages: 10...14)
        #expect(second.isEmpty) // one section is not a list
        let flat: [(title: String, pageIndex: Int, depth: Int)] = [("A", 3, 0), ("B", 5, 0)]
        let fromFlat = StudioViewModel.pdfChapterSectionEntries(flat, pages: 2...8)
        #expect(fromFlat.map { $0.title } == ["A", "B"])
        #expect(fromFlat.map { $0.pageIndex } == [1, 3])
    }

    @Test("A chapter split from a book without bookmarks keeps its sections on disk")
    func chapterOutlineSurvivesTheWrite() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSectionIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Drawn by Core Graphics with no outline: the case PDFKit loses an
        // outline in when the opened document itself is rewritten.
        let bookURL = folder.appendingPathComponent("book.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try #require(CGContext(bookURL as CFURL, mediaBox: &mediaBox, nil))
        for index in 0..<8 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "book page \(index)", attributes: [.font: NSFont.systemFont(ofSize: 14)])
                .draw(at: CGPoint(x: 20, y: 100))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let book = try #require(PDFDocument(url: bookURL))
        #expect(book.outlineRoot == nil)

        let chapterPath = folder.appendingPathComponent("01 Chapter.pdf").path
        #expect(StudioViewModel.writePDFChapter(
            pages: 2...6,
            of: book,
            sections: [(title: "Water", pageIndex: 1), (title: "Ions", pageIndex: 3)],
            toFile: chapterPath
        ))

        let chapter = try #require(PDFDocument(url: URL(fileURLWithPath: chapterPath)))
        #expect(chapter.pageCount == 5)
        #expect(chapter.page(at: 0)?.string?.contains("book page 2") == true)
        #expect(BookSectionIndex.outlineSections(of: chapter) == [
            BookChapterSection(title: "Water", pageInChapter: 1),
            BookChapterSection(title: "Ions", pageInChapter: 3),
        ])
    }
}
