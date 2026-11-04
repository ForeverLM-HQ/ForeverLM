import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Reference citation numbers")
struct ReferenceCitationTests {
    @Test("A range names every number in it, whatever dash the typesetter used")
    func rangeNamesEveryNumber() {
        #expect(ReferenceCitation.numbers(in: "5–7") == [5, 6, 7])
        #expect(ReferenceCitation.numbers(in: "5-7") == [5, 6, 7])
        #expect(ReferenceCitation.numbers(in: "5—7") == [5, 6, 7])
        #expect(ReferenceCitation.numbers(in: "5\u{2212}7") == [5, 6, 7])
        #expect(ReferenceCitation.numbers(in: "5\u{2009}–\u{2009}7") == [5, 6, 7])
        #expect(ReferenceCitation.numbers(in: "1–25")?.count == 25)
    }

    @Test("A list names each number, and a mixed one both its numbers and its ranges, in order")
    func listsAndMixed() {
        #expect(ReferenceCitation.numbers(in: "11,12") == [11, 12])
        #expect(ReferenceCitation.numbers(in: "11, 12") == [11, 12])
        #expect(ReferenceCitation.numbers(in: "1,3–5") == [1, 3, 4, 5])
        #expect(ReferenceCitation.numbers(in: "1–3,5,7–8") == [1, 2, 3, 5, 7, 8])
        #expect(ReferenceCitation.numbers(in: "12") == [12])
        // Each number once, in the order it was named.
        #expect(ReferenceCitation.numbers(in: "3,3,2–4") == [3, 2, 4])
    }

    @Test("Text that is not a citation by number names nothing")
    func notACitation() {
        #expect(ReferenceCitation.numbers(in: "") == nil)
        #expect(ReferenceCitation.numbers(in: "Smith 2019") == nil)
        #expect(ReferenceCitation.numbers(in: "2019") == nil)
        #expect(ReferenceCitation.numbers(in: "7–5") == nil)
        #expect(ReferenceCitation.numbers(in: "5,") == nil)
        #expect(ReferenceCitation.numbers(in: "5-7-9") == nil)
        #expect(ReferenceCitation.numbers(in: "0") == nil)
        #expect(ReferenceCitation.numbers(in: "1–1500") == nil)
    }

    @Test("A range too wide to be read as every number names its two ends")
    func hugeRange() {
        #expect(ReferenceCitation.numbers(in: "1–300") == [1, 300])
    }
}

@Suite("Citations of a range or a list")
struct RangeCitationEntriesTests {
    enum LinkStyle { case endpoints, wholeRange, firstOnly }

    @Test("5–7 with an endpoint linked each shows entries 5, 6 and 7, whichever endpoint is pointed at")
    func endpointsLinked() async throws {
        for key in ["first", "last"] {
            let paper = try Self.paper(citation: "5–7", style: .endpoints)
            let entries = PDFReferenceEntries(.bytes(paper.data))
            let cited = await entries.entries(for: .init(pageIndex: 0, bounds: try #require(paper.links[key])))
            #expect(cited.map(\.number) == [5, 6, 7])
            #expect(cited.map { $0.text.prefix(3) } == ["5. ", "6. ", "7. "])
        }
    }

    @Test("5–7 linked as one link, or by its first number only, shows every entry too")
    func wholeRangeAndFirstOnly() async throws {
        for (style, key) in [(LinkStyle.wholeRange, "whole"), (.firstOnly, "first")] {
            let paper = try Self.paper(citation: "5–7", style: style)
            let entries = PDFReferenceEntries(.bytes(paper.data))
            let cited = await entries.entries(for: .init(pageIndex: 0, bounds: try #require(paper.links[key])))
            #expect(cited.map(\.number) == [5, 6, 7])
        }
    }

    @Test("A hyphen range, and a citation set in the body's size between brackets, read the same")
    func hyphenAndBrackets() async throws {
        let hyphen = try Self.paper(citation: "5-7", style: .endpoints)
        let hyphenCited = await PDFReferenceEntries(.bytes(hyphen.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(hyphen.links["first"])))
        #expect(hyphenCited.map(\.number) == [5, 6, 7])
        let bracket = try Self.paper(citation: "5, 6", style: .endpoints, bracketed: true)
        let bracketCited = await PDFReferenceEntries(.bytes(bracket.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(bracket.links["last"])))
        #expect(bracketCited.map(\.number) == [5, 6])
    }

    @Test("A mixed list names its ranges' middles and skips what it does not name")
    func mixedList() async throws {
        let paper = try Self.paper(citation: "1,3–5", style: .firstOnly)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.map(\.number) == [1, 3, 4, 5])
    }

    @Test("Each entry stops where the next begins, and none runs on into the entry after the range")
    func entriesStopAtTheirNumbers() async throws {
        let paper = try Self.paper(citation: "5–7", style: .endpoints)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        let five = try #require(cited.first)
        #expect(five.text.hasSuffix("Science 286, 774-779."))
        #expect(!five.text.contains("6."))
        let seven = try #require(cited.last)
        #expect(seven.text.hasSuffix("Cell 9, 99-100."))
        #expect(!seven.text.contains("White"))
    }

    @Test("A list that goes on past the foot of a page is still read in order")
    func listBreaksAcrossPages() async throws {
        let paper = try Self.paper(citation: "5–7", style: .endpoints, breakAfterSix: true)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.map(\.number) == [5, 6, 7])
        #expect(cited.last?.pieces.first?.pageIndex == 2)
    }

    @Test("A single number is the one entry its link lands on, with no number of its own")
    func singleNumber() async throws {
        let paper = try Self.paper(citation: "5", style: .firstOnly)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.count == 1)
        #expect(cited.first?.number == nil)
        #expect(cited.first?.text.hasPrefix("5. Michikawa") == true)
    }

    @Test("An entry carries the page characters its text is read from")
    func entryCarriesItsCharacters() async throws {
        let paper = try Self.paper(citation: "5", style: .firstOnly)
        let document = try #require(PDFDocument(data: paper.data))
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        let entry = try #require(cited.first)
        let words = entry.pieces.map { piece -> String in
            let text = (document.page(at: piece.pageIndex)?.string ?? "") as NSString
            return text.substring(with: piece.range)
        }.joined(separator: " ")
        #expect(words.contains("Mazzucchelli"))
        #expect(words.contains("774-779"))
    }

    // MARK: Fixture

    struct Paper {
        let data: Data
        let links: [String: CGRect]
    }

    /// Page 0: a sentence with a superscript citation (or a bracketed one set
    /// in the body's size) linked as `style` says. Then the reference list,
    /// entries 1 to 9 with hanging indents, of which only the numbers the
    /// links land on have a destination.
    static func paper(
        citation: String,
        style: LinkStyle,
        bracketed: Bool = false,
        breakAfterSix: Bool = false
    ) throws -> Paper {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let body = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let small = CTFontCreateWithName("Helvetica" as CFString, bracketed ? 10 : 6.5, nil)
        func width(_ text: String, _ font: CTFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        func draw(_ text: String, _ font: CTFont, x: CGFloat, baseline: CGFloat) {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        }
        let cited = try #require(ReferenceCitation.numbers(in: citation))
        var links: [String: CGRect] = [:]
        context.beginPDFPage(nil)
        let lead = "Proteins are imported into the organelle"
        draw(lead, body, x: 72, baseline: 700)
        var x = 72 + width(lead, body)
        if bracketed {
            draw(" [", body, x: x, baseline: 700)
            x += width(" [", body)
        }
        // One character at a time, so each part's rectangle is known.
        var spans: [(text: String, rect: CGRect)] = []
        for character in citation {
            let text = String(character)
            let advance = width(text, small)
            let baseline: CGFloat = bracketed ? 700 : 705
            draw(text, small, x: x, baseline: baseline)
            spans.append((text, CGRect(x: x, y: baseline - 1, width: advance, height: 7)))
            x += advance
        }
        if bracketed {
            draw("]", body, x: x, baseline: 700)
            x += width("]", body)
        }
        draw(" and then it folds.", body, x: x + 1, baseline: 700)
        func isDigit(_ index: Int) -> Bool { spans[index].text.first?.isNumber == true }
        func rect(_ from: Int, _ to: Int) -> CGRect { spans[from...to].map(\.rect).reduce(CGRect.null) { $0.union($1) } }
        var firstEnd = 0
        while firstEnd + 1 < spans.count, isDigit(firstEnd + 1) { firstEnd += 1 }
        var lastStart = spans.count - 1
        while lastStart > 0, isDigit(lastStart - 1) { lastStart -= 1 }
        switch style {
        case .endpoints:
            links["first"] = rect(0, firstEnd)
            links["last"] = rect(lastStart, spans.count - 1)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["first"]!)
            context.setDestination("bib\(cited.last!)" as CFString, for: links["last"]!)
        case .wholeRange:
            links["whole"] = rect(0, spans.count - 1)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["whole"]!)
        case .firstOnly:
            links["first"] = rect(0, firstEnd)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["first"]!)
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        let landed = style == .endpoints ? [cited.first!, cited.last!] : [cited.first!]
        let references: [(number: Int, lines: [String])] = [
            (1, ["Smith, A. and Lee, B. (2020). Segmenting the shapes of", "mitochondrial networks. Nat. Methods 17, 101-109."]),
            (2, ["Jones, C. (2021). Live imaging of organelle dynamics.", "Cell 7, 1-9."]),
            (3, ["Brown, D. (2019). An entry that nobody cites.", "Science 1, 2-3."]),
            (4, ["Green, E. (2018). Import of precursor proteins into", "mitochondria. J. Biol. Chem. 4, 5-6."]),
            (5, ["Michikawa, Y., Mazzucchelli, F. (1999). Aging-dependent large", "accumulation of point mutations. Science 286, 774-779."]),
            (6, ["Hart-Wells, A. (2002). A middle entry that is not linked.", "Nature 3, 30-31."]),
            (7, ["Kim, S. and Park, J. (2005). The last cited entry in the", "range. Cell 9, 99-100."]),
            (8, ["White, F. (2007). Not cited at all.", "Mol. Cell 1, 1-2."]),
            (9, ["Black, G. (2008). Also not cited.", "EMBO J. 2, 3-4."]),
        ]
        var baseline: CGFloat = 700
        for entry in references {
            if landed.contains(entry.number) {
                context.addDestination("bib\(entry.number)" as CFString, at: CGPoint(x: 70, y: baseline + 10))
            }
            for (index, line) in entry.lines.enumerated() {
                draw(index == 0 ? "\(entry.number). \(line)" : line, body, x: index == 0 ? 72 : 84, baseline: baseline)
                baseline -= 12
            }
            baseline -= 4
            if breakAfterSix, entry.number == 6 {
                context.endPDFPage()
                context.beginPDFPage(nil)
                baseline = 700
            }
        }
        context.endPDFPage()
        context.closePDF()
        return Paper(data: data as Data, links: links)
    }
}
