import AppKit
import CoreText
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Scanned Book Text Layer")
struct ScannedBookTextLayerTests {
    private static let scannedLines = [
        "The phospholipid bilayer is extremely",
        "impermeable to ions including potassium",
        "and sodium in living cells.",
    ]

    private static let typesetText = """
        This page was typeset rather than scanned, so it carries its own text \
        layer with well over twenty five words of embedded text that PDFKit \
        reads directly, and no OCR should ever touch it during a book import \
        because its words are already there for search and highlights.
        """

    /// A two-page book: page 0 is only a picture of print, as a scanner makes
    /// it; page 1 is typeset text. It has an outline entry on each page. A
    /// `sideways` scan is stored on a landscape page with the print turned a
    /// quarter, and the page's rotation of 90 shows it upright, as scanners do.
    private static func makeBook(sideways: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannedBookTextLayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawn = directory.appendingPathComponent("drawn.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 432, height: 648)
        let context = try #require(CGContext(drawn as CFURL, mediaBox: &mediaBox, nil))

        let scan = try picture(of: scannedLines, size: CGSize(width: 1296, height: 1944))
        if sideways {
            var landscape = CGRect(x: 0, y: 0, width: 648, height: 432)
            context.beginPDFPage([
                kCGPDFContextMediaBox: Data(bytes: &landscape, count: MemoryLayout<CGRect>.size),
            ] as CFDictionary)
            context.translateBy(x: 648, y: 0)
            context.rotate(by: .pi / 2)
            context.draw(scan, in: mediaBox)
        } else {
            context.beginPDFPage(nil)
            context.draw(scan, in: mediaBox)
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributed = NSAttributedString(
            string: typesetText,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0),
            CGPath(rect: mediaBox.insetBy(dx: 40, dy: 40), transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
        context.endPDFPage()
        // Written by Core Graphics: PDFKit on macOS 27 does not save an
        // outline given to a document that had none.
        let chapters = ["Chapter 1: The Membrane", "Chapter 2: Typeset"].enumerated().map { index, title in
            [kCGPDFOutlineTitle: title, kCGPDFOutlineDestination: index + 1] as CFDictionary
        }
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: chapters] as CFDictionary)
        context.closePDF()

        let document = try #require(PDFDocument(url: drawn))
        #expect(document.outlineRoot?.numberOfChildren == 2)
        if sideways { document.page(at: 0)?.rotation = 90 }
        let book = directory.appendingPathComponent("book.pdf")
        #expect(document.write(to: book))
        return book
    }

    /// Black print on white at a size OCR reads reliably, as a bitmap with no text.
    private static func picture(of lines: [String], size: CGSize) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Times New Roman" as CFString, 56, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 90, y: size.height - 200 - CGFloat(index) * 90)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return try #require(context.makeImage())
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @Test("Only a page with no text of its own is read by OCR")
    func onlyTextlessPagesAreRead() throws {
        let book = try Self.makeBook()
        defer { try? FileManager.default.removeItem(at: book.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: book))
        #expect(ScannedPDFTextLayer.pageIndicesNeedingOCR(in: document) == [0])

        var reported: [(Int, Int)] = []
        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { reported.append(($0, $1)) }
        defer { pages.discardPictures() }
        #expect(pages.pageCount == 2)
        #expect(Array(pages.lines.keys) == [0])
        #expect(reported.map(\.0) == [1] && reported.map(\.1) == [1])
        let read = Self.normalized(pages.lines[0]?.map(\.text).joined(separator: " "))
        #expect(read.contains("phospholipid bilayer"))
        #expect(read.contains("impermeable"))
        #expect(FileManager.default.fileExists(atPath: pages.pictureURL(forPage: 0).path))
        for line in pages.lines[0] ?? [] {
            #expect(line.x >= 0 && line.y >= 0 && line.x + line.width <= 1.0001 && line.y + line.height <= 1.0001)
        }
    }

    @Test("A book made as a PDF is not a scan, whatever its picture pages print")
    func bookMadeAsPDFIsNotRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannedBookTextLayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A cover that is a picture of print, then four typeset pages.
        let book = directory.appendingPathComponent("ebook.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 432, height: 648)
        let context = try #require(CGContext(book as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.draw(try Self.picture(of: Self.scannedLines, size: CGSize(width: 1296, height: 1944)), in: mediaBox)
        context.endPDFPage()
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for _ in 0..<4 {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(NSAttributedString(
                    string: Self.typesetText,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )),
                CFRange(location: 0, length: 0),
                CGPath(rect: mediaBox.insetBy(dx: 40, dy: 40), transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()

        let document = try #require(PDFDocument(url: book))
        #expect(ScannedPDFTextLayer.pageIndicesNeedingOCR(in: document).isEmpty)
        var reported = 0
        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { _, _ in reported += 1 }
        defer { pages.discardPictures() }
        #expect(pages.lines.isEmpty)
        #expect(reported == 0)
        #expect(!FileManager.default.fileExists(atPath: pages.pictureDirectory.path))
    }

    @Test("A book is a scan when at least half its pages carry no text of their own")
    func scanIsDecidedForTheWholeBook() {
        #expect(ScannedPDFTextLayer.isScan(pageCount: 2, textlessPageCount: 1))
        #expect(ScannedPDFTextLayer.isScan(pageCount: 400, textlessPageCount: 396))
        #expect(!ScannedPDFTextLayer.isScan(pageCount: 156, textlessPageCount: 7))
        #expect(!ScannedPDFTextLayer.isScan(pageCount: 0, textlessPageCount: 0))
    }

    @Test("A typeset page with few words is not given a second copy of its text")
    func sparseTypesetPageIsLeftAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScannedBookTextLayerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = directory.appendingPathComponent("opener.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 432, height: 648)
        let context = try #require(CGContext(book as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Chapter Three: The Membrane",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        context.textPosition = CGPoint(x: 40, y: 500)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(url: book))
        #expect(ScannedPDFTextLayer.pageIndicesNeedingOCR(in: document) == [0])
        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { _, _ in }
        defer { pages.discardPictures() }
        #expect(pages.lines.isEmpty)
    }

    @Test("The text layer makes a scanned page read as its text and leaves the rest of the book as it was")
    func textLayerReadsAsPageText() throws {
        let book = try Self.makeBook()
        defer { try? FileManager.default.removeItem(at: book.deletingLastPathComponent()) }
        let before = try #require(PDFDocument(url: book))
        let typesetBefore = before.page(at: 1)?.string
        let scannedBefore = Self.normalized(before.page(at: 0)?.string)
        #expect(scannedBefore.isEmpty)

        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { _, _ in }
        defer { pages.discardPictures() }
        try ScannedPDFTextLayer.writeTextLayer(pages.lines, intoPDFAt: book)

        let after = try #require(PDFDocument(url: book))
        #expect(after.pageCount == 2)
        let scannedText = Self.normalized(after.page(at: 0)?.string)
        #expect(scannedText.contains("phospholipid bilayer is extremely"))
        #expect(scannedText.contains("sodium in living cells"))
        #expect(after.page(at: 1)?.string == typesetBefore)
        #expect(after.findString("impermeable", withOptions: .caseInsensitive).count == 1)

        let outline = try #require(after.outlineRoot)
        #expect(outline.numberOfChildren == 2)
        #expect(outline.child(at: 0)?.label == "Chapter 1: The Membrane")
        #expect(outline.child(at: 0)?.destination?.page.map { after.index(for: $0) } == 0)
        #expect(outline.child(at: 1)?.destination?.page.map { after.index(for: $0) } == 1)
    }

    @Test("Proofread lines are what the layer says, each over the print it was read from")
    func proofreadLinesAreWritten() throws {
        let book = try Self.makeBook()
        defer { try? FileManager.default.removeItem(at: book.deletingLastPathComponent()) }
        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { _, _ in }
        defer { pages.discardPictures() }
        var lines = try #require(pages.lines[0])
        let first = try #require(lines.indices.first)
        lines[first].text = "K⁺ permeability rises 10⁻⁷ M"
        try ScannedPDFTextLayer.writeTextLayer([0: lines], intoPDFAt: book)

        let document = try #require(PDFDocument(url: book))
        let page = try #require(document.page(at: 0))
        #expect((page.string ?? "").contains("K⁺ permeability rises 10⁻⁷ M"))
        let selection = try #require(document.findString("permeability", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        let printed = CGRect(
            x: lines[first].x * 432, y: lines[first].y * 648,
            width: lines[first].width * 432, height: lines[first].height * 648
        )
        #expect(printed.insetBy(dx: -4, dy: -4).contains(CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    @Test("A sideways scan keeps its rotation and its layer reads in line order")
    func sidewaysScanReadsAsText() throws {
        let book = try Self.makeBook(sideways: true)
        defer { try? FileManager.default.removeItem(at: book.deletingLastPathComponent()) }
        let pages = try ScannedPDFTextLayer.recognizeUnreadablePages(pdfPath: book.path) { _, _ in }
        defer { pages.discardPictures() }
        let read = Self.normalized(pages.lines[0]?.map(\.text).joined(separator: " "))
        #expect(read.contains("phospholipid bilayer"))
        try ScannedPDFTextLayer.writeTextLayer(pages.lines, intoPDFAt: book)
        let page = try #require(PDFDocument(url: book)?.page(at: 0))
        #expect(page.rotation == 90)
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 648, height: 432))
        #expect(Self.normalized(page.string).contains("phospholipid bilayer is extremely"))
    }

    @Test("Points on the page as shown map to the page's own corners for every rotation")
    func shownToPageTransformMapsCorners() {
        let box = CGRect(x: 10, y: 20, width: 600, height: 800)
        func corners(_ rotation: Int) -> [CGPoint] {
            let shown = ScannedPDFTextLayer.shownSize(of: box, rotation: rotation)
            let transform = ScannedPDFTextLayer.shownToPageTransform(mediaBox: box, rotation: rotation)
            // Shown bottom-left, bottom-right, top-left.
            return [
                CGPoint(x: 0, y: 0),
                CGPoint(x: shown.width, y: 0),
                CGPoint(x: 0, y: shown.height),
            ].map { $0.applying(transform) }
        }
        let bottomLeft = CGPoint(x: 10, y: 20), bottomRight = CGPoint(x: 610, y: 20)
        let topLeft = CGPoint(x: 10, y: 820), topRight = CGPoint(x: 610, y: 820)
        #expect(corners(0) == [bottomLeft, bottomRight, topLeft])
        // Turned a quarter clockwise, the page's bottom-right corner is shown at the bottom left.
        #expect(corners(90) == [bottomRight, topRight, bottomLeft])
        #expect(corners(180) == [topRight, topLeft, bottomRight])
        #expect(corners(270) == [topLeft, bottomLeft, topRight])
        #expect(ScannedPDFTextLayer.shownSize(of: box, rotation: 90) == CGSize(width: 800, height: 600))
        #expect(ScannedPDFTextLayer.shownSize(of: box, rotation: -90) == CGSize(width: 800, height: 600))
    }
}

@Suite("Scanned Page Proofreading")
struct ScannedPageProofreadingTests {
    private static let lines = [
        RecognizedPDFLine(text: "ions including K+209 [13.2]. Yet, as shown", x: 0.1, y: 0.8, width: 0.8, height: 0.02),
        RecognizedPDFLine(text: "on exposure to 10-7 M valinomycin.?° Ling and", x: 0.1, y: 0.77, width: 0.8, height: 0.02),
        RecognizedPDFLine(text: "Ochsenfeld saw in this remarkable discovery", x: 0.1, y: 0.74, width: 0.8, height: 0.02),
    ]

    @Test("The model's fixes replace only the lines it names, and the lines keep their places")
    func fixesReplaceNamedLines() throws {
        let reply = """
            {"fixes": {"0": "ions including K⁺²⁰⁹ [13.2]. Yet, as shown", "1": "on exposure to 10⁻⁷ M valinomycin.²¹⁰ Ling and"}}
            """
        let corrected = try ScannedPageProofreading.applying(reply: reply, to: Self.lines)
        #expect(corrected.map(\.text) == [
            "ions including K⁺²⁰⁹ [13.2]. Yet, as shown",
            "on exposure to 10⁻⁷ M valinomycin.²¹⁰ Ling and",
            "Ochsenfeld saw in this remarkable discovery",
        ])
        #expect(corrected.map(\.y) == Self.lines.map(\.y))
    }

    @Test("No fixes leaves the page as OCR read it, and a fenced reply is read")
    func emptyAndFencedReplies() throws {
        #expect(try ScannedPageProofreading.applying(reply: #"{"fixes": {}}"#, to: Self.lines) == Self.lines)
        let fenced = "```json\n{\"fixes\": {\"2\": \"Ochsenfeld saw in this remarkable discovery\"}}\n```"
        #expect(try ScannedPageProofreading.applying(reply: fenced, to: Self.lines) == Self.lines)
    }

    @Test("A reply that names a missing line, empties or splits one, or is not JSON is refused")
    func badRepliesAreRefused() {
        for reply in [
            #"{"fixes": {"3": "a fourth line"}}"#,
            #"{"fixes": {"-1": "before the page"}}"#,
            #"{"fixes": {"first": "not a number"}}"#,
            #"{"fixes": {"1": "   "}}"#,
            #"{"fixes": {"1": "one line\nbecame two"}}"#,
            "The page looks right to me.",
            #"{"lines": ["ions including K⁺"]}"#,
        ] {
            #expect(throws: (any Error).self, "accepted: \(reply)") {
                try ScannedPageProofreading.applying(reply: reply, to: Self.lines)
            }
        }
    }

    @Test("The request numbers each OCR line from zero and names the page")
    func userPromptNumbersLines() {
        let prompt = ScannedPageProofreading.userPrompt(
            bookTitle: "Life at the Cell", pageIndex: 149, pageCount: 400, lines: Self.lines
        )
        #expect(prompt.contains("Book: Life at the Cell"))
        #expect(prompt.contains("Page 150 of 400"))
        #expect(prompt.contains("\n0\tions including K+209 [13.2]. Yet, as shown"))
        #expect(prompt.contains("\n2\tOchsenfeld saw in this remarkable discovery"))
    }

    @Test("Scanned Page Proofreading is background image work for books")
    func taskIsBackgroundVisionWork() {
        let task = AITask.scannedPageProofreading
        #expect(task.requiresVision)
        #expect(task.usesMultimodalBackgroundModelDefault)
        #expect(task.defaultPrompt == Prompts.scannedPageProofreading)
        #expect(task.usageNeed == .needed)
        #expect(AITask.advancedTasks.contains(task))
        #expect(AIBackupModels.slot(for: task) == "background.images")
    }
}
