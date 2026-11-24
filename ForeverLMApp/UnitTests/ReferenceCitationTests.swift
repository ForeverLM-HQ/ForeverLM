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

    @Test("Each number of a list linked on its own shows the entry its own link lands on")
    func eachNumberItsOwnLanding() async throws {
        // "6,7" with each number linked: the 7's link is entry 7's, though
        // the run it sits in begins with 6. The entries print no numbers, so
        // only the links can tell them apart.
        let paper = try Self.paper(citation: "6,7", style: .endpoints, numbered: false)
        for key in ["first", "last"] {
            let cited = await PDFReferenceEntries(.bytes(paper.data))
                .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links[key])))
            #expect(cited.map(\.number) == [6, 7])
            #expect(cited.first?.text.hasPrefix("Hart-Wells") == true)
            #expect(cited.last?.text.hasPrefix("Kim, S.") == true)
        }
    }

    @Test("A range's unlinked middle lands where the paper cites it alone, though no entry prints a number")
    func middleBorrowedFromItsOwnCitation() async throws {
        // "5–7" links 5 and 7 only, and nothing in the list says which entry
        // is 6; the paper's own "6", cited alone further on, lands on it.
        let paper = try Self.paper(citation: "5–7", style: .endpoints, numbered: false, alsoCited: [6])
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.map(\.number) == [5, 6, 7])
        #expect(cited.dropFirst().first?.text.hasPrefix("Hart-Wells") == true)
    }

    @Test("A link that covers its number's comma still lands on its own number")
    func linkOverItsComma() async throws {
        // MDPI's links over "[30,152]" take its comma.
        let paper = try Self.paper(citation: "6,7", style: .endpoints, numbered: false, linksTakeSeparator: true)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["last"])))
        #expect(cited.map(\.number) == [6, 7])
        #expect(cited.last?.text.hasPrefix("Kim, S.") == true)
    }

    @Test("A bracketed list's unlinked middle is found by its bracketed number")
    func bracketedListMiddle() async throws {
        let paper = try Self.paper(citation: "5–7", style: .endpoints, bracketedEntries: true)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.map(\.number) == [5, 6, 7])
        #expect(cited.dropFirst().first?.text.hasPrefix("[6] Hart-Wells") == true)
    }

    @Test("A link that lands one entry off shows the entry that prints its number")
    func landingOneOff() async throws {
        // BMC's link for "9" lands on entry 10; the list says which is 9.
        let paper = try Self.paper(citation: "5", style: .firstOnly, landsOneEntryLate: true)
        let cited = await PDFReferenceEntries(.bytes(paper.data))
            .entries(for: .init(pageIndex: 0, bounds: try #require(paper.links["first"])))
        #expect(cited.map { $0.text.prefix(12) } == ["5. Michikawa"])
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
    /// links land on have a destination. Unless `numbered`, the entries print
    /// no numbers; with `bracketedEntries` they print "[5]". `alsoCited` adds
    /// a citation of each number alone, linked, on a line of its own, and
    /// `linksTakeSeparator` stretches each endpoint's link over the comma or
    /// dash between them. With `landsOneEntryLate`, each link lands on the
    /// entry after its own.
    static func paper(
        citation: String,
        style: LinkStyle,
        bracketed: Bool = false,
        breakAfterSix: Bool = false,
        numbered: Bool = true,
        bracketedEntries: Bool = false,
        alsoCited: [Int] = [],
        linksTakeSeparator: Bool = false,
        landsOneEntryLate: Bool = false
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
        let firstLinkEnd = linksTakeSeparator ? min(firstEnd + 1, spans.count - 1) : firstEnd
        var lastStart = spans.count - 1
        while lastStart > 0, isDigit(lastStart - 1) { lastStart -= 1 }
        let lastLinkStart = linksTakeSeparator ? max(lastStart - 1, 0) : lastStart
        switch style {
        case .endpoints:
            links["first"] = rect(0, firstLinkEnd)
            links["last"] = rect(lastLinkStart, spans.count - 1)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["first"]!)
            context.setDestination("bib\(cited.last!)" as CFString, for: links["last"]!)
        case .wholeRange:
            links["whole"] = rect(0, spans.count - 1)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["whole"]!)
        case .firstOnly:
            links["first"] = rect(0, firstEnd)
            context.setDestination("bib\(cited.first!)" as CFString, for: links["first"]!)
        }
        var alsoBaseline: CGFloat = 660
        for number in alsoCited {
            let lead = "As shown before"
            draw(lead, body, x: 72, baseline: alsoBaseline)
            let x = 72 + width(lead, body)
            draw("\(number)", small, x: x, baseline: alsoBaseline + 5)
            let rect = CGRect(x: x, y: alsoBaseline + 4, width: width("\(number)", small), height: 7)
            context.setDestination("bib\(number)" as CFString, for: rect)
            draw(" in a second experiment.", body, x: x + width("\(number)", small) + 1, baseline: alsoBaseline)
            alsoBaseline -= 24
        }
        context.endPDFPage()

        context.beginPDFPage(nil)
        let landed = (style == .endpoints ? [cited.first!, cited.last!] : [cited.first!]) + alsoCited
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
            if landed.contains(entry.number - (landsOneEntryLate ? 1 : 0)) {
                context.addDestination("bib\(entry.number - (landsOneEntryLate ? 1 : 0))" as CFString, at: CGPoint(x: 70, y: baseline + 10))
            }
            for (index, line) in entry.lines.enumerated() {
                let label = bracketedEntries ? "[\(entry.number)]" : "\(entry.number)."
                let text = index == 0 && numbered ? "\(label) \(line)" : line
                draw(text, body, x: index == 0 ? 72 : 84, baseline: baseline)
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

@Suite("Citations a PDF prints but does not link")
struct PrintedReferenceCitationTests {
    @Test("A bracketed citation is found with every number it names, a range read whole")
    func bracketsFound() {
        let text = "slows down by an order of magnitude [26]\nand rises [3, 5–7]; see also [1,2]."
        #expect(ReferenceCitation.printed(in: text).map(\.numbers) == [[26], [3, 5, 6, 7], [1, 2]])
        let first = ReferenceCitation.printed(in: text)[0].range
        #expect((text as NSString).substring(with: first) == "[26]")
    }

    @Test("A bracket that reads no citation numbers is not a citation")
    func notCitations() {
        #expect(ReferenceCitation.printed(in: "[Ca2+] rose, [0] held, [12–8] ran backwards, [abc]").isEmpty)
    }

    @Test("Full-width brackets, and a space inside the brackets, still make a citation")
    func fullWidth() {
        #expect(ReferenceCitation.printed(in: "drift \u{FF3B}12\u{FF3D}. Then [ 5 ] again").map(\.numbers) == [[12], [5]])
        #expect(ReferenceCitation.printed(in: "Reference:\n\u{FF3B}1\u{FF3D}Maegawa S, Lu Y").isEmpty)
    }

    @Test("An entry of a bracketed reference list is not a citation of it; a citation wrapped to a new line is")
    func listEntriesLeftOut() {
        #expect(ReferenceCitation.printed(in: "References\n[12] Smith J. 2001. A title.").isEmpty)
        #expect(ReferenceCitation.printed(in: "tunnelling\n[26] and free-radical leak").map(\.numbers) == [[26]])
    }

    @Test("A numbered list, or one in citation order, is read by place; an alphabetical author-year list is not")
    func listOrder() {
        func index(_ labels: [String]) -> PaperReferenceIndex {
            PaperReferenceIndex(sourceID: "s", references: labels.enumerated().map {
                PaperReference(sourceID: "s", ordinal: $0.offset + 1, label: $0.element, text: $0.element)
            })
        }
        #expect(ReaderPDFReferencePreview.listsInCitationOrder(index(["1", "2", "3"])))
        #expect(ReaderPDFReferencePreview.listsInCitationOrder(index(["Jacobi 2015", "Lee 2003", "Buck 2016", "Adams 2001", "Zhou 2008", "Chen 2010"])))
        #expect(!ReaderPDFReferencePreview.listsInCitationOrder(index(["Adams 2001", "Buck 2016", "Chen 2010", "Jacobi 2015", "Lee 2003", "Zhou 2008"])))
        #expect(!ReaderPDFReferencePreview.listsInCitationOrder(index([])))
    }
}
