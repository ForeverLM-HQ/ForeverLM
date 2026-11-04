import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Reference card highlights")
struct ReaderReferenceHighlightsTests {
    private static let firstLine = "5. Michikawa, Y., Mazzucchelli, F. (1999). Aging-dependent large accumulation of the biologi-"
    private static let secondLine = "cally relevant thing. Science 286."
    private static let display = "5. Michikawa, Y., Mazzucchelli, F. (1999). Aging-dependent large accumulation of the biologically relevant thing. Science 286."

    private static func map() -> ReferenceTextMap {
        ReferenceTextMap(display: display, pieces: [
            (pageIndex: 3, range: NSRange(location: 100, length: (firstLine as NSString).length), text: firstLine),
            (pageIndex: 3, range: NSRange(location: 200, length: (secondLine as NSString).length), text: secondLine),
        ])
    }

    private static func location(of word: String, inLine line: String, at start: Int) -> Int {
        start + (line as NSString).range(of: word).location
    }

    @Test("Words selected on the card are the same words on the page's own line")
    func selectionInOneLine() {
        let shown = Self.display as NSString
        let runs = Self.map().pageRuns(forDisplayRange: shown.range(of: "Mazzucchelli, F."))
        #expect(runs.count == 1)
        #expect(runs.first?.pageIndex == 3)
        #expect(runs.first?.range == NSRange(location: Self.location(of: "Mazzucchelli, F.", inLine: Self.firstLine, at: 100), length: 16))
    }

    @Test("A word the typesetter hyphenated across a line is two stretches of the page, hyphen included")
    func selectionAcrossAHyphenatedLine() {
        let shown = Self.display as NSString
        let runs = Self.map().pageRuns(forDisplayRange: shown.range(of: "biologically relevant"))
        #expect(runs.map(\.range) == [
            NSRange(location: Self.location(of: "biologi-", inLine: Self.firstLine, at: 100), length: 8),
            NSRange(location: 200, length: ("cally relevant" as NSString).length),
        ])
    }

    @Test("Highlights on the page show on the card, a hyphenated word as one stretch")
    func pageMarksShowOnTheCard() {
        let shown = Self.display as NSString
        let marks: [(pageIndex: Int, range: NSRange, value: String)] = [
            (3, NSRange(location: Self.location(of: "Mazzucchelli", inLine: Self.firstLine, at: 100), length: 12), "yellow"),
            (3, NSRange(location: Self.location(of: "biologi-", inLine: Self.firstLine, at: 100), length: 8), "green"),
            (3, NSRange(location: 200, length: 5), "green"),
        ]
        let shownMarks = Self.map().displayRanges(marking: marks, in: Self.display)
        #expect(shownMarks.map { shown.substring(with: $0.range) } == ["Mazzucchelli", "biologically"])
        #expect(shownMarks.map(\.value) == ["yellow", "green"])
    }

    @Test("Neighbouring marks of one colour join over the space between their words")
    func neighbouringMarksJoin() {
        let marks: [(pageIndex: Int, range: NSRange, value: String)] = [
            (3, NSRange(location: Self.location(of: "Michikawa,", inLine: Self.firstLine, at: 100), length: 10), "yellow"),
            (3, NSRange(location: Self.location(of: "Y.,", inLine: Self.firstLine, at: 100), length: 3), "yellow"),
        ]
        let shownMarks = Self.map().displayRanges(marking: marks, in: Self.display)
        #expect(shownMarks.count == 1)
        #expect(shownMarks.first.map { (Self.display as NSString).substring(with: $0.range) } == "Michikawa, Y.,")
    }

    @Test("Text that is not the page's is not placed on it")
    func unrelatedTextIsNotPlaced() {
        let map = ReferenceTextMap(display: "zzzzzz", pieces: [
            (pageIndex: 0, range: NSRange(location: 0, length: 5), text: "Hello"),
        ])
        #expect(!map.isPlaced)
        #expect(map.pageRuns(forDisplayRange: NSRange(location: 0, length: 6)).isEmpty)
    }

    @Test("The words picked on the card make the selection of those words on a real page, and a painted highlight shows back on the card")
    func realPage() async throws {
        let data = try Self.pageData()
        let document = try #require(PDFDocument(data: data))
        let target = try #require(PDFReferenceEntries.targets(in: document)[0]?.first)
        let cited = try #require(await PDFReferenceEntries(.bytes(data)).entries(for: .init(pageIndex: 0, bounds: target.bounds)).first)
        let pieces = cited.pieces.map { piece -> (pageIndex: Int, range: NSRange, text: String) in
            let text = (document.page(at: piece.pageIndex)?.string ?? "") as NSString
            return (piece.pageIndex, piece.range, text.substring(with: piece.range))
        }
        let map = ReferenceTextMap(display: cited.text, pieces: pieces)
        #expect(map.isPlaced)
        let shown = cited.text as NSString
        var selection: PDFSelection?
        for run in map.pageRuns(forDisplayRange: shown.range(of: "accumulation of point mutations")) {
            guard let part = document.page(at: run.pageIndex)?.selection(for: run.range) else { continue }
            if let selection { selection.add(part) } else { selection = part }
        }
        let words = selection?.string?.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        #expect(words == "accumulation of point mutations")

        // What the reader paints for a highlight is a rectangle over the line.
        let page = try #require(document.page(at: 1))
        let painted = try #require(page.selection(for: (page.string! as NSString).range(of: "Mazzucchelli")))
        let rect = painted.bounds(for: page)
        let under = try #require(page.selection(for: rect.insetBy(dx: 0, dy: rect.height * 0.25)))
        let marks = (0..<under.numberOfTextRanges(on: page)).map { (pageIndex: 1, range: under.range(at: $0, on: page), value: 1) }
        let back = map.displayRanges(marking: marks, in: cited.text)
        #expect(back.count == 1)
        #expect(back.first.map { shown.substring(with: $0.range) }?.contains("Mazzucchelli") == true)
    }

    /// Page 0 cites entry 5 by named destination; page 1 lists entries 4 to 6.
    private static func pageData() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let body = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let small = CTFontCreateWithName("Helvetica" as CFString, 6.5, nil)
        func draw(_ text: String, _ font: CTFont, x: CGFloat, baseline: CGFloat) {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        }
        context.beginPDFPage(nil)
        draw("Proteins are imported into the organelle", body, x: 72, baseline: 700)
        draw("5", small, x: 300, baseline: 705)
        context.setDestination("bib5" as CFString, for: CGRect(x: 300, y: 704, width: 4, height: 7))
        context.endPDFPage()
        context.beginPDFPage(nil)
        let entries: [(Int, [String])] = [
            (4, ["Green, E. (2018). Import of precursor proteins into", "mitochondria. J. Biol. Chem. 4, 5-6."]),
            (5, ["Michikawa, Y., Mazzucchelli, F. (1999). Aging-dependent large", "accumulation of point mutations. Science 286, 774-779."]),
            (6, ["Hart-Wells, A. (2002). A middle entry.", "Nature 3, 30-31."]),
        ]
        var baseline: CGFloat = 700
        for (number, lines) in entries {
            if number == 5 { context.addDestination("bib5" as CFString, at: CGPoint(x: 70, y: baseline + 10)) }
            for (index, line) in lines.enumerated() {
                draw(index == 0 ? "\(number). \(line)" : line, body, x: index == 0 ? 72 : 84, baseline: baseline)
                baseline -= 12
            }
            baseline -= 4
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

@Suite("Reference links")
struct ReaderReferenceLinkTests {
    @Test("An entry's printed DOI is its link, without the sentence's closing punctuation")
    func printedDOI() {
        let entry = "11. Michikawa, Y. Science 286, 774–779 (1999). https://doi.org/10.1126/science.286.5440.774."
        #expect(ReaderReferenceLink.printed(inReferenceEntry: entry)?.absoluteString == "https://doi.org/10.1126/science.286.5440.774")
    }

    @Test("An entry with no DOI but a web address links to that address")
    func printedAddress() {
        let entry = "3. Example Lab. Methods handbook. (2020). Available at https://example.org/handbook/methods)."
        #expect(ReaderReferenceLink.printed(inReferenceEntry: entry)?.absoluteString == "https://example.org/handbook/methods")
    }

    @Test("An entry that prints neither has no link of its own")
    func nothingPrinted() {
        #expect(ReaderReferenceLink.printed(inReferenceEntry: "2. Jones, C. (2021). Live imaging of organelle dynamics. Cell 7, 1-9.") == nil)
    }

    @Test("A link is said without its scheme")
    func displayText() throws {
        #expect(ReaderReferenceLink.displayText(for: try #require(URL(string: "https://doi.org/10.1016/j.cell.2020.01.001"))) == "doi.org/10.1016/j.cell.2020.01.001")
        #expect(ReaderReferenceLink.displayText(for: try #require(URL(string: "http://www.example.org/"))) == "example.org")
    }
}

@Suite("A citation under a highlight")
struct ReaderPDFLinkHitTestTests {
    /// A page with a citation link and a web link, each in a sentence.
    private static func page() throws -> PDFPage {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "imported into the organelle 4 and more", attributes: [.font: font])), context)
        context.setDestination("bib4" as CFString, for: CGRect(x: 200, y: 698, width: 6, height: 12))
        context.setURL(try #require(URL(string: "https://example.org")) as CFURL, for: CGRect(x: 300, y: 698, width: 20, height: 12))
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data)?.page(at: 0))
    }

    private static func highlight(on page: PDFPage, mine: Bool) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 697, width: 300, height: 13), forType: .highlight, withProperties: nil)
        if mine { annotation.userName = ReaderPDFHighlightSupport.annotationPrefix + "hl_test" }
        page.addAnnotation(annotation)
        return annotation
    }

    @Test("A citation is found under a highlight the reader painted, though PDFKit answers the highlight")
    func citationUnderHighlight() throws {
        let page = try Self.page()
        let citation = try #require(page.annotations.first { $0.type == "Link" && $0.url == nil })
        let point = CGPoint(x: citation.bounds.midX, y: citation.bounds.midY)
        #expect(ReaderPDFLinkHitTest.link(at: point, on: page)?.coveredByMark == false)
        let mark = Self.highlight(on: page, mine: true)
        #expect(page.annotation(at: point) === mark)
        let hit = try #require(ReaderPDFLinkHitTest.link(at: point, on: page))
        #expect(hit.annotation === citation)
        #expect(hit.coveredByMark)
    }

    @Test("A highlight the document brought covers a link no more than the reader's own")
    func documentsOwnHighlight() throws {
        let page = try Self.page()
        let citation = try #require(page.annotations.first { $0.type == "Link" && $0.url == nil })
        _ = Self.highlight(on: page, mine: false)
        let hit = ReaderPDFLinkHitTest.link(at: CGPoint(x: citation.bounds.midX, y: citation.bounds.midY), on: page)
        #expect(hit?.annotation === citation)
    }

    @Test("Elsewhere on the highlight there is no link, so the click still opens the highlight")
    func restOfHighlight() throws {
        let page = try Self.page()
        _ = Self.highlight(on: page, mine: true)
        #expect(ReaderPDFLinkHitTest.link(at: CGPoint(x: 100, y: 703), on: page) == nil)
    }

    @Test("A web link under a highlight is found with its address, which PDFKit would not follow")
    func webLinkUnderHighlight() throws {
        let page = try Self.page()
        let web = try #require(page.annotations.first { $0.type == "Link" && $0.url != nil })
        _ = Self.highlight(on: page, mine: true)
        let hit = try #require(ReaderPDFLinkHitTest.link(at: CGPoint(x: web.bounds.midX, y: web.bounds.midY), on: page))
        #expect(hit.annotation === web)
        #expect(ReaderPDFLinkHitTest.externalURL(of: hit.annotation)?.absoluteString == "https://example.org")
    }

    @Test("Another kind of annotation over a link keeps its precedence")
    func otherAnnotationOverLink() throws {
        let page = try Self.page()
        let citation = try #require(page.annotations.first { $0.type == "Link" && $0.url == nil })
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 72, y: 697, width: 300, height: 13), forType: .freeText, withProperties: nil))
        #expect(ReaderPDFLinkHitTest.link(at: CGPoint(x: citation.bounds.midX, y: citation.bounds.midY), on: page) == nil)
    }
}
