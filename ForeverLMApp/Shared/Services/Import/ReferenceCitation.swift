import CoreGraphics
import Foundation
import PDFKit

/// The reference numbers an in-text citation names. A superscript or bracket
/// reads "5", "5–7", "11,12" or "1,3–5"; a range is a citation of every number
/// in it, so clicking "5–7" shows entries 5, 6 and 7, not the two a publisher's
/// PDF happens to link (product owner, 2026-11-04: "when i click 5-7, it should
/// show 5 6 and 7; not just 5 and 7").
enum ReferenceCitation {
    /// The widest range read as every number in it. A wider one is most
    /// likely a misread, and names only its two ends.
    static let widestRange = 100

    /// The largest reference number read as one.
    static let largestNumber = 999

    /// The numbers `text` names, in the order it names them, each once; nil
    /// when the text is not a citation by number (words, a year, an author and
    /// year, a descending range).
    static func numbers(in text: String) -> [Int]? {
        let folded = String(text.unicodeScalars.compactMap { scalar -> Character? in
            if dashes.contains(scalar) { return "-" }
            if spacing.contains(scalar) { return nil }
            return Character(scalar)
        })
        guard !folded.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in folded.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" }) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let first = number(ends[0]) else { return nil }
            if ends.count == 1 {
                numbers.append(first)
                continue
            }
            guard let last = number(ends[1]), last >= first else { return nil }
            if last - first <= widestRange {
                numbers.append(contentsOf: first...last)
            } else {
                numbers.append(contentsOf: [first, last])
            }
        }
        var seen = Set<Int>()
        return numbers.filter { seen.insert($0).inserted }
    }

    private static func number(_ digits: Substring) -> Int? {
        guard (1...3).contains(digits.count), digits.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }),
              let value = Int(digits), value >= 1, value <= largestNumber else { return nil }
        return value
    }

    /// Hyphen-minus and every other dash a typesetter sets a range with.
    private static let dashes: Set<Unicode.Scalar> = [
        "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}", "\u{FE63}", "\u{FF0D}",
    ]

    /// The spaces a list may carry between its numbers.
    private static let spacing: Set<Unicode.Scalar> = [
        " ", "\u{00A0}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{2006}", "\u{2005}", "\u{2004}", "\u{2002}", "\u{2003}", "\u{200B}",
    ]

    /// Whether a page character may be part of a citation's numbers.
    static func isCitationCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal || scalar == "," || scalar == ";" || dashes.contains(scalar)
    }

    static func isSpacing(_ scalar: Unicode.Scalar) -> Bool {
        spacing.contains(scalar)
    }

    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "," || scalar == ";" || dashes.contains(scalar)
    }
}

// MARK: - Reading a citation off the page

extension PDFReferenceEntries {
    /// A run of citation numbers on a page: the numbers it names and where it
    /// sits.
    struct CitationGroup: Sendable {
        let numbers: [Int]
        let bounds: CGRect
    }

    /// The citation a link sits in. A link covers a superscript's digits, or
    /// only one number of a run ("5" and "7" of "5–7", each linked on its
    /// own), so the run is read outwards from the link's own characters over
    /// the digits, separators and dashes next to them that are set the same
    /// size on the same line. Nil when the link's own characters are not a
    /// citation by number (a "Fig. 2", a table link, an author and year).
    nonisolated static func citationGroup(around bounds: CGRect, on page: PDFPage, boxes: [CGRect]) -> CitationGroup? {
        let text = (page.string ?? "") as NSString
        guard text.length == boxes.count else { return nil }
        let own = boxes.indices.filter { index in
            let box = boxes[index]
            return !box.isNull && box.midX >= bounds.minX - 0.5 && box.midX <= bounds.maxX + 0.5
                && box.midY >= bounds.minY - 0.5 && box.midY <= bounds.maxY + 0.5
        }
        guard let low = own.min(), let high = own.max() else { return nil }
        func scalar(_ index: Int) -> Unicode.Scalar? {
            index >= 0 && index < text.length ? Unicode.Scalar(text.character(at: index)) : nil
        }
        // Everything the link covers is a citation's own, or nothing is.
        for index in low...high {
            guard let character = scalar(index), ReferenceCitation.isCitationCharacter(character) || ReferenceCitation.isSpacing(character) else {
                return nil
            }
        }
        guard let reference = own.first(where: { scalar($0).map { $0.properties.numericType == .decimal } == true }).map({ boxes[$0] }) else {
            return nil
        }
        // Whether the character at `index` is set like the citation's own: a
        // digit as tall as its digits, a separator on its line.
        func isSameRun(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, !boxes[index].isNull, let character = scalar(index),
                  ReferenceCitation.isCitationCharacter(character) else { return false }
            let box = boxes[index]
            if character.properties.numericType == .decimal {
                // Body-text digits beside a superscript ("5 2019") are not part of it.
                let ratio = box.height / max(reference.height, 0.1)
                return ratio > 0.7 && ratio < 1.4 && abs(box.midY - reference.midY) <= max(reference.height * 0.5, 2)
            }
            return abs(box.midY - reference.midY) <= max(reference.height, 2)
        }
        var first = low
        var last = high
        // Rightwards.
        var index = high + 1
        while index < text.length {
            if let character = scalar(index), ReferenceCitation.isSpacing(character) {
                // A space inside a list ("1, 2") follows a separator and
                // precedes a number.
                guard let before = scalar(last), ReferenceCitation.isSeparator(before), isSameRun(index + 1),
                      boxes[index + 1].minX - boxes[last].maxX <= reference.height * 2.5 else { break }
                last = index + 1
                index += 2
                continue
            }
            guard isSameRun(index), boxes[index].minX - boxes[last].maxX <= reference.height * 1.2,
                  boxes[index].minX >= boxes[last].minX - 0.5 else { break }
            last = index
            index += 1
        }
        // Leftwards.
        index = low - 1
        while index >= 0 {
            if let character = scalar(index), ReferenceCitation.isSpacing(character) {
                guard let after = scalar(index - 1), ReferenceCitation.isSeparator(after), isSameRun(index - 1),
                      boxes[first].minX - boxes[index - 1].maxX <= reference.height * 2.5 else { break }
                first = index - 1
                index -= 2
                continue
            }
            guard isSameRun(index), boxes[first].minX - boxes[index].maxX <= reference.height * 1.2,
                  boxes[index].maxX <= boxes[first].maxX + 0.5 else { break }
            first = index
            index -= 1
        }
        // A separator at an end belongs to the words around the citation
        // ("…cells,5" ends after its 5; a stray dash opens nothing).
        while first < last, let character = scalar(first), ReferenceCitation.isSeparator(character) { first += 1 }
        while last > first, let character = scalar(last), ReferenceCitation.isSeparator(character) { last -= 1 }
        let run = text.substring(with: NSRange(location: first, length: last - first + 1))
        guard let numbers = ReferenceCitation.numbers(in: run) else { return nil }
        let group = (first...last).reduce(CGRect.null) { union, position in
            boxes[position].isNull ? union : union.union(boxes[position])
        }
        return CitationGroup(numbers: numbers, bounds: group)
    }

    /// Where the entry numbered `number` starts, for a number no link lands
    /// on: the line in the reference list that begins "6." or "[6]", searched
    /// from the nearest entry whose landing is known, in the direction of the
    /// number, over the pages a list can reach in a few entries. A line that
    /// begins with the number only counts at the margin the known entry
    /// starts at, when it sits on the same page.
    nonisolated static func numberedLanding(
        for number: Int,
        anchors: [Int: Landing],
        in document: PDFDocument,
        boxesByPage: inout [Int: [CGRect]]
    ) -> Landing? {
        let before = anchors.filter { $0.key < number }.max { $0.key < $1.key }
        let after = anchors.filter { $0.key > number }.min { $0.key < $1.key }
        guard let reference = before ?? after else { return nil }
        let forward = before != nil
        let start = reference.value
        let reach = 3
        let pageIndexes = forward
            ? Array(start.pageIndex...(start.pageIndex + reach))
            : Array(((start.pageIndex - reach)...start.pageIndex).reversed())
        guard let pattern = try? NSRegularExpression(
            pattern: #"^[ \t]*[\[(]?(\#(number))[.\])](?!\d)"#, options: [.anchorsMatchLines]
        ) else { return nil }
        for pageIndex in pageIndexes {
            guard pageIndex >= 0, let page = document.page(at: pageIndex), let string = page.string else { continue }
            let boxes: [CGRect]
            if let known = boxesByPage[pageIndex] {
                boxes = known
            } else {
                boxes = characterBoxes(on: page)
                boxesByPage[pageIndex] = boxes
            }
            let text = string as NSString
            guard boxes.count == text.length else { continue }
            var candidates = pattern.matches(in: string, range: NSRange(location: 0, length: text.length))
                .map { $0.range(at: 1).location }
                .filter { boxes[$0].isNull == false }
            if pageIndex == start.pageIndex, let origin = landingCharacter(at: start.point, boxes: boxes) {
                // On the known entry's own page the wanted one lies beyond it
                // (or before it, searching back), never on the other side, and
                // starts at the same margin when more than one line begins so.
                candidates = candidates.filter { forward ? $0 > origin : $0 < origin }
                let margin = candidates.filter { abs(boxes[$0].minX - boxes[origin].minX) <= 3 }
                if !margin.isEmpty { candidates = margin }
            }
            let chosen = forward ? candidates.first : candidates.last
            if let chosen {
                let box = boxes[chosen]
                return Landing(pageIndex: pageIndex, point: CGPoint(x: box.minX, y: box.maxY))
            }
        }
        return nil
    }
}
