import CoreGraphics
import Foundation
import PDFKit

/// The reference list entry an in-text citation link lands on, read from the
/// paper itself: hovering a superscript like ³³ shows what paper 33 is without
/// scrolling to the back of the article (product owner, 2026-09-23: "hover over these
/// superscripts … and see a popup of what paper it is, rather than going all
/// the way down to the list of references").
///
/// A publisher's PDF links every citation to its reference entry, so the set of
/// places links land is the set of entry starts. One entry is the text from
/// where its link lands to where the next entry starts — layout, not string
/// parsing, decides where that is, so the reference style (numbered,
/// bracketed, author-year) does not matter. The same holds for an author's
/// affiliation superscript, and for a table link, which lands on its caption.
///
/// Work happens on a private copy of the document, off the main actor: finding
/// every link means reading every page's annotations once. Checked against
/// the papers in a real library (Cell Press, Nature, Science Advances, BMC,
/// Springer, Oxford, Frontiers): a PDF whose links name only a page, or only a
/// height, has nothing to show, and shows nothing.
actor PDFReferenceEntries {
    /// A place in the document a citation link lands on.
    struct Landing: Hashable, Sendable {
        let pageIndex: Int
        let point: CGPoint

        func hash(into hasher: inout Hasher) {
            hasher.combine(pageIndex)
            hasher.combine(point.x)
            hasher.combine(point.y)
        }
    }

    /// A link on a page, as the reader's PDF view sees it under the pointer.
    struct Link: Sendable {
        let pageIndex: Int
        let bounds: CGRect
    }

    /// A link's rectangle and where it lands, read from the file.
    struct Target: Sendable {
        let bounds: CGRect
        let landing: Landing
    }

    enum Origin: Sendable {
        case file(URL)
        case bytes(Data)
    }

    private let origin: Origin
    private var document: PDFDocument?
    /// Page index → the page's links and where they land, read once.
    private var targets: [Int: [Target]]?
    /// Page index → character indices where some link lands, ascending,
    /// resolved for a page the first time an entry on it is asked for.
    private var entryStarts: [Int: [Int]] = [:]
    /// What each landing previews, nil included, so hovering a figure link
    /// twice does not read the page twice.
    private var cache: [Landing: CitedEntry?] = [:]
    /// Entry starts found by number for a citation of a range ("5–7") whose
    /// middle entries no link lands on, by page; they end the entry before
    /// them as a link's landing does (`entries(for:)`).
    private var derivedLandings: [Int: [CGPoint]] = [:]

    init(_ origin: Origin) {
        self.origin = origin
    }

    func entry(for link: Link) -> String? {
        guard let document = loadedDocument() else { return nil }
        let targets = loadedTargets(in: document)
        guard let landing = Self.landing(of: link, in: targets) else { return nil }
        return record(at: landing, in: document, targets: targets)?.text
    }

    /// What a landing previews, read once: the entry's text and where on the
    /// file's pages that text is.
    private func record(at landing: Landing, in document: PDFDocument, targets: [Int: [Target]]) -> CitedEntry? {
        if let cached = cache[landing] { return cached }
        var landings = Self.landingsByPage(targets)
        for (pageIndex, points) in derivedLandings { landings[pageIndex, default: []] += points }
        for pageIndex in [landing.pageIndex, landing.pageIndex + 1] where entryStarts[pageIndex] == nil {
            guard let page = document.page(at: pageIndex) else { continue }
            entryStarts[pageIndex] = Self.entryStarts(on: page, landings: landings[pageIndex] ?? [])
        }
        let entry = Self.citedEntry(at: landing, in: document, entryStarts: entryStarts)
        cache[landing] = .some(entry)
        return entry
    }

    /// Every entry the citation under the pointer names, in order. A
    /// citation of a range ("5–7") or a list ("1,3–5") names each number in
    /// it, though the PDF links only some of them (an endpoint, or a range's
    /// first entry): the rest are found in the reference list by their
    /// numbers (`ReferenceCitation`). Any other link names the one entry it
    /// lands on.
    func entries(for link: Link) -> [CitedEntry] {
        guard let document = loadedDocument() else { return [] }
        let targets = loadedTargets(in: document)
        func single() -> [CitedEntry] {
            guard let landing = Self.landing(of: link, in: targets),
                  let entry = record(at: landing, in: document, targets: targets) else { return [] }
            return [entry]
        }
        guard let page = document.page(at: link.pageIndex) else { return [] }
        let boxes = Self.characterBoxes(on: page)
        guard let group = Self.citationGroup(around: link.bounds, on: page, boxes: boxes), group.numbers.count > 1 else {
            return single()
        }
        var anchors: [Int: Landing] = [:]
        for target in targets[link.pageIndex] ?? [] where target.bounds.insetBy(dx: -1, dy: -1).intersects(group.bounds) {
            if let own = Self.citationGroup(around: target.bounds, on: page, boxes: boxes), let first = own.numbers.first {
                anchors[first] = anchors[first] ?? target.landing
            }
        }
        guard !anchors.isEmpty else { return single() }
        // Numbers are counted on from an entry that prints its own number: a
        // list whose entries print none, or a link to a table's caption
        // ("Table 2, 3"), has no "6." to find.
        let numbered = anchors.filter { number, landing in
            record(at: landing, in: document, targets: targets)?.text
                .range(of: "^[\\[(]?\(number)[.\\])]", options: .regularExpression) != nil
        }
        var boxesByPage: [Int: [CGRect]] = [link.pageIndex: boxes]
        var derived: [Int: Landing] = [:]
        for number in group.numbers where anchors[number] == nil {
            if let landing = Self.numberedLanding(for: number, anchors: numbered, in: document, boxesByPage: &boxesByPage) {
                derived[number] = landing
            }
        }
        // An entry found by its number ends the one before it, and what was
        // read before it was known may have run on into it.
        for landing in derived.values where !(derivedLandings[landing.pageIndex] ?? []).contains(landing.point) {
            derivedLandings[landing.pageIndex, default: []].append(landing.point)
            entryStarts[landing.pageIndex] = nil
            cache = cache.filter { $0.key.pageIndex != landing.pageIndex && $0.key.pageIndex != landing.pageIndex - 1 }
        }
        var entries: [CitedEntry] = []
        for number in group.numbers {
            guard let landing = anchors[number] ?? derived[number],
                  var entry = record(at: landing, in: document, targets: targets) else { continue }
            entry.number = number
            entries.append(entry)
        }
        return entries.isEmpty ? single() : entries
    }

    /// Where a link lands, read from the file. PDFKit reports a link to a
    /// named destination as going to its own page, so a click on one would
    /// otherwise move nowhere.
    func landing(for link: Link) -> Landing? {
        guard let document = loadedDocument() else { return nil }
        return Self.landing(of: link, in: loadedTargets(in: document))
    }

    private func loadedDocument() -> PDFDocument? {
        if document == nil {
            switch origin {
            case .file(let url): document = PDFDocument(url: url)
            case .bytes(let data): document = PDFDocument(data: data)
            }
        }
        return document
    }

    private func loadedTargets(in document: PDFDocument) -> [Int: [Target]] {
        let targets = targets ?? Self.targets(in: document)
        self.targets = targets
        return targets
    }

    // MARK: Reading the document

    /// Where the link under the pointer lands: the file's link with the same
    /// rectangle on the same page.
    nonisolated static func landing(of link: Link, in targets: [Int: [Target]]) -> Landing? {
        targets[link.pageIndex]?.first { target in
            abs(target.bounds.minX - link.bounds.minX) < 1 && abs(target.bounds.minY - link.bounds.minY) < 1
                && abs(target.bounds.maxX - link.bounds.maxX) < 1 && abs(target.bounds.maxY - link.bounds.maxY) < 1
        }?.landing
    }

    nonisolated static func landingsByPage(_ targets: [Int: [Target]]) -> [Int: [CGPoint]] {
        let landings = Set(targets.values.joined().map(\.landing))
        return Dictionary(grouping: landings, by: \.pageIndex).mapValues { $0.map(\.point) }
    }

    /// Every internal link in the file with a point to land on, by the page
    /// the link sits on. Read from the PDF's own objects rather than through
    /// `PDFAnnotation`: publishers (Cell Press among them) link citations by
    /// *named* destination — `/Dest (bib33)` resolved through the catalog's
    /// name tree — and PDFKit reports such a link as going to its own page
    /// with no point. A link to a web address, or to a whole page (`/Fit`),
    /// cannot say which entry it means and is left out.
    nonisolated static func targets(in document: PDFDocument) -> [Int: [Target]] {
        guard let file = document.documentRef, let catalog = file.catalog else { return [:] }
        var pageIndexByObject: [CGPDFDictionaryRef: Int] = [:]
        var pages: [CGPDFPage] = []
        for number in 1...max(file.numberOfPages, 1) {
            guard let page = file.page(at: number) else { continue }
            if let dictionary = page.dictionary { pageIndexByObject[dictionary] = number - 1 }
            pages.append(page)
        }
        let named = NamedDestinations(catalog: catalog)
        func landing(_ object: CGPDFObjectRef) -> Destination? {
            switch CGPDFObjectGetType(object) {
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { return nil }
                return explicitLanding(array, pageIndexByObject: pageIndexByObject, pages: pages)
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?
                var inner: CGPDFObjectRef?
                guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary,
                      CGPDFDictionaryGetObject(dictionary, "D", &inner), let inner else { return nil }
                return landing(inner)
            case .string, .name:
                guard let key = pdfText(object), let resolved = named.object(for: key) else { return nil }
                return landing(resolved)
            default:
                return nil
            }
        }
        var targets: [Int: [Target]] = [:]
        var boxesByPage: [Int: [CGRect]] = [:]
        for (index, page) in pages.enumerated() {
            guard let dictionary = page.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { continue }
            for position in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, position, &annotation), let annotation,
                      pdfName(annotation, "Subtype") == "Link",
                      let bounds = pdfRect(annotation, "Rect") else { continue }
                var destination: CGPDFObjectRef?
                if !CGPDFDictionaryGetObject(annotation, "Dest", &destination) {
                    var action: CGPDFDictionaryRef?
                    guard CGPDFDictionaryGetDictionary(annotation, "A", &action), let action,
                          pdfName(action, "S") == "GoTo" else { continue }
                    CGPDFDictionaryGetObject(action, "D", &destination)
                }
                guard let destination, let reached = landing(destination) else { continue }
                var target = reached.landing
                if let band = reached.band {
                    // A band names a line but not its column: the link's own
                    // number says which entry on that line it means.
                    let boxes = boxesByPage[target.pageIndex] ?? {
                        let made = document.page(at: target.pageIndex).map(characterBoxes(on:)) ?? []
                        boxesByPage[target.pageIndex] = made
                        return made
                    }()
                    let number = document.page(at: index).flatMap { citedNumber(under: bounds, on: $0) }
                    guard let page = document.page(at: target.pageIndex),
                          let start = bandEntryStart(in: band, citing: number, on: page, boxes: boxes) else { continue }
                    target = Landing(pageIndex: target.pageIndex, point: CGPoint(x: boxes[start].minX, y: boxes[start].maxY))
                }
                targets[index, default: []].append(Target(bounds: bounds, landing: target))
            }
        }
        return targets
    }

    /// Where a destination leads. A page-wide rectangle names a line but no
    /// column, so it comes with the vertical range of that line.
    private struct Destination {
        let landing: Landing
        let band: ClosedRange<CGFloat>?
    }

    /// The number a citation link prints: the one digit run under it, nil for
    /// a link that prints none or several (an author-year citation, a range).
    private nonisolated static func citedNumber(under bounds: CGRect, on page: PDFPage) -> Int? {
        guard let text = page.selection(for: bounds)?.string else { return nil }
        let runs = text.split { !$0.isNumber }
        guard runs.count == 1 else { return nil }
        return Int(runs[0])
    }

    /// The first glyph of the entry a page-wide band points at. Each column
    /// with a line in the band offers one, and the one whose entry is
    /// numbered as the link is wins. With no number to go by, or no line so
    /// numbered, there is none: a band cannot tell an entry from a figure's
    /// caption or a paragraph, and text from the wrong place is worse than
    /// nothing.
    private nonisolated static func bandEntryStart(
        in band: ClosedRange<CGFloat>,
        citing number: Int?,
        on page: PDFPage,
        boxes: [CGRect]
    ) -> Int? {
        let slack: CGFloat = 2
        let inBand = boxes.enumerated().filter { !$0.element.isNull && $0.element.midY >= band.lowerBound - slack && $0.element.midY <= band.upperBound + slack }
        let starts = inBand.filter { index, box in
            !inBand.contains { other in
                other.offset != index && onLine(other.element, midY: box.midY)
                    && other.element.maxX > box.minX - columnGutter && other.element.minX < box.minX - 0.1
            }
        }
        // One per column, the line nearest the band's middle: columns are
        // further apart than any indent, and the line above may poke into the
        // band's edge.
        let middle = (band.lowerBound + band.upperBound) / 2
        var columns: [(offset: Int, element: CGRect)] = []
        for start in starts.sorted(by: { $0.element.minX < $1.element.minX }) {
            if let last = columns.last, start.element.minX - last.element.minX < 30 {
                if abs(start.element.midY - middle) < abs(last.element.midY - middle) {
                    columns[columns.count - 1] = start
                }
            } else {
                columns.append(start)
            }
        }
        guard let number else { return nil }
        let text = (page.string ?? "") as NSString
        // Its number is the digits it opens with ("13." or "[13]"); a PDF may
        // read the line with no space after them.
        return columns.first { column in
            var position = column.offset
            while position < text.length, [0x5B, 0x28].contains(text.character(at: position)) { position += 1 }
            var digits = ""
            while position < text.length, let scalar = Unicode.Scalar(text.character(at: position)), scalar.properties.numericType == .decimal {
                digits.unicodeScalars.append(scalar)
                position += 1
            }
            return digits == String(number)
        }?.offset
    }

    /// The tallest page-wide rectangle that still names a line: a body line is
    /// about 10 points, and a band of two lines is as loose as one may be.
    private nonisolated static let fullWidthLineHeight: CGFloat = 12

    /// `[page /XYZ left top zoom]` or `[page /FitR left bottom right top]`.
    private nonisolated static func explicitLanding(
        _ array: CGPDFArrayRef,
        pageIndexByObject: [CGPDFDictionaryRef: Int],
        pages: [CGPDFPage]
    ) -> Destination? {
        var pageDictionary: CGPDFDictionaryRef?
        guard CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetDictionary(array, 0, &pageDictionary), let pageDictionary,
              let pageIndex = pageIndexByObject[pageDictionary] else { return nil }
        var kind: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 1, &kind), let kind else { return nil }
        func number(_ index: Int) -> CGFloat? {
            var value: CGPDFReal = 0
            guard index < CGPDFArrayGetCount(array), CGPDFArrayGetNumber(array, index, &value) else { return nil }
            return value
        }
        // Only a destination with a left edge inside the page says which
        // column it means: one that names a height alone (`/FitH`, or `/XYZ`
        // with no left or a left at the page's edge) was seen landing on the
        // acknowledgements beside a supplement heading, and on a running head.
        let crop = pages[pageIndex].getBoxRect(.cropBox)
        let edge = crop.minX
        let corner: (left: CGFloat?, top: CGFloat?)
        switch String(cString: kind) {
        case "XYZ": corner = (number(2), number(3))
        case "FitR": corner = (number(2), number(5))
        default: return nil
        }
        guard let left = corner.left, let top = corner.top else { return nil }
        if left > edge + 1 { return Destination(landing: Landing(pageIndex: pageIndex, point: CGPoint(x: left, y: top)), band: nil) }
        // Springer Nature sets every entry's destination as a rectangle the
        // width of the page and the height of one line (`/FitR 0 747 596 736`,
        // its bottom and top written either way round): no column, but the
        // line is named, so the entry is the one whose first line sits in it,
        // in whichever column that is (`bandEntryStart`). A `/FitH` or `/XYZ`
        // at the edge names no band and stays rejected.
        guard String(cString: kind) == "FitR", let first = number(3), let second = number(5), let right = number(4),
              right >= crop.maxX - 1, abs(first - second) <= 2 * fullWidthLineHeight, first != second else { return nil }
        return Destination(
            landing: Landing(pageIndex: pageIndex, point: CGPoint(x: edge, y: max(first, second))),
            band: min(first, second)...max(first, second)
        )
    }

    /// The catalog's named destinations: the `/Names /Dests` name tree, and
    /// the older `/Dests` dictionary.
    private struct NamedDestinations {
        private var tree: [String: CGPDFObjectRef] = [:]
        private var legacy: CGPDFDictionaryRef?

        init(catalog: CGPDFDictionaryRef) {
            var names: CGPDFDictionaryRef?
            var root: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
               CGPDFDictionaryGetDictionary(names, "Dests", &root), let root {
                collect(root, depth: 0)
            }
            var dests: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Dests", &dests) { legacy = dests }
        }

        private mutating func collect(_ node: CGPDFDictionaryRef, depth: Int) {
            guard depth < 32 else { return }
            var pairs: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
                let count = CGPDFArrayGetCount(pairs)
                var position = 0
                while position + 1 < count {
                    var key: CGPDFObjectRef?
                    var value: CGPDFObjectRef?
                    if CGPDFArrayGetObject(pairs, position, &key), let key, let name = pdfText(key),
                       CGPDFArrayGetObject(pairs, position + 1, &value), let value {
                        tree[name] = value
                    }
                    position += 2
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                for position in 0..<CGPDFArrayGetCount(kids) {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, position, &kid), let kid { collect(kid, depth: depth + 1) }
                }
            }
        }

        func object(for name: String) -> CGPDFObjectRef? {
            if let found = tree[name] { return found }
            var object: CGPDFObjectRef?
            guard let legacy, CGPDFDictionaryGetObject(legacy, name, &object) else { return nil }
            return object
        }
    }

    private nonisolated static func pdfText(_ object: CGPDFObjectRef) -> String? {
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(object, .string, &string), let string {
            return CGPDFStringCopyTextString(string) as String?
        }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return String(cString: name) }
        return nil
    }

    private nonisolated static func pdfName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &name), let name else { return nil }
        return String(cString: name)
    }

    private nonisolated static func pdfRect(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values: [CGFloat] = []
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values.append(value)
        }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    /// The characters links land on, ascending: where the page's entries start.
    nonisolated static func entryStarts(on page: PDFPage, landings: [CGPoint]) -> [Int] {
        let boxes = characterBoxes(on: page)
        return Set(landings.compactMap { landingCharacter(at: $0, boxes: boxes) }).sorted()
    }

    /// Wider than any space between words, justified or not: a gap this wide
    /// on one line is the gutter between two columns.
    static let columnGutter: CGFloat = 9

    /// Each character's box on the page, indexed as the page's text is, and
    /// `.null` for whitespace, so a page's landings are resolved from one pass
    /// over it. `characterBounds(at:)` cannot be used: it counts no line
    /// breaks, so its index falls one further behind the text at every line.
    nonisolated static func characterBoxes(on page: PDFPage) -> [CGRect] {
        let text = (page.string ?? "") as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        return (0..<text.length).map { index in
            if let scalar = Unicode.Scalar(text.character(at: index)), whitespace.contains(scalar) {
                return .null
            }
            guard let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page) else { return .null }
            return box.width > 0 && box.height > 0 ? box : .null
        }
    }

    /// The first character of the entry a destination points at: the glyph
    /// that begins a line near the destination's top-left corner.
    ///
    /// Publishers place that corner loosely. Oxford puts it well short of the
    /// entry, and a few points above or inside its first line; others put it
    /// on the line's top. So the candidates are the glyphs that begin a line
    /// (none just before them on it) a little right of the corner and not far
    /// below it. Of those, the leftmost margin is the entries' — the lines
    /// further right are an entry's indented continuation, or the next
    /// column — and on it, the entry's first line is the one whose top is
    /// nearest the corner's height: in a list set tight, the entry above can
    /// sit within a few points of it too.
    nonisolated static func landingCharacter(at point: CGPoint, boxes: [CGRect]) -> Int? {
        let reach: CGFloat = 36
        let startSlack: CGFloat = 60
        let inside: CGFloat = 4
        let band = boxes.enumerated().filter { !$0.element.isNull && abs($0.element.midY - point.y) <= reach + 12 }
        let starts = band.filter { index, box in
            box.midY <= point.y + inside && box.midY >= point.y - reach
                && box.minX >= point.x - 2 && box.minX <= point.x + startSlack
                && !band.contains { other in
                    other.offset != index && onLine(other.element, midY: box.midY)
                        && other.element.maxX > box.minX - columnGutter && other.element.minX < box.minX - 0.1
                }
        }
        guard let margin = starts.map(\.element.minX).min() else { return nil }
        return starts
            .filter { $0.element.minX <= margin + 1.5 }
            .min { abs($0.element.maxY - point.y) < abs($1.element.maxY - point.y) }?
            .offset
    }

    private nonisolated static func onLine(_ box: CGRect, midY: CGFloat) -> Bool {
        abs(box.midY - midY) <= max(box.height / 2, 1)
    }

    /// Whether the entries on a page are set with hanging indents: the line
    /// after an entry's first starts further right than it did. Judged by the
    /// page's entries together, since one entry may be a single line.
    nonisolated static func listIsHanging(boxes: [CGRect], starts: [Int]) -> Bool {
        var indented = 0
        var flush = 0
        for start in starts where boxes.indices.contains(start) && !boxes[start].isNull {
            let first = boxes[start]
            // The next line down in reading order: the first glyph below this one.
            guard let next = boxes[(start + 1)...].first(where: { !$0.isNull && $0.maxY < first.minY - 0.5 }),
                  first.minY - next.maxY < 2 * first.height, abs(next.minX - first.minX) < 60 else { continue }
            if next.minX > first.minX + 2 {
                indented += 1
            } else if abs(next.minX - first.minX) <= 1.5 {
                flush += 1
            }
        }
        return indented > flush
    }

    /// The text of the entry that starts where `landing` points.
    ///
    /// Read in the page's reading order, it runs to the next place a link
    /// lands, or — since a cited range such as 13–15 links only its first
    /// entry — to the next line that starts at an entry's margin in a list set
    /// with hanging indents. The last entry on a page runs on to the top of the
    /// next page when the list continues there.
    ///
    /// Some journals (Nature, BMC, Science Advances) set the entry numbers in
    /// a column of their own, which PDFKit reads as a separate block: in
    /// reading order the entry is its number alone. Its first line is then
    /// much wider on the page than in the text, and the entry is read off the
    /// page instead — its column, from its line down to the next number.
    nonisolated static func entryText(at landing: Landing, in document: PDFDocument, entryStarts: [Int: [Int]]) -> String? {
        citedEntry(at: landing, in: document, entryStarts: entryStarts)?.text
    }

    /// The entry `entryText` reads, with the page characters its words are
    /// read from, so a highlight made on the entry can be anchored to them.
    nonisolated static func citedEntry(at landing: Landing, in document: PDFDocument, entryStarts: [Int: [Int]]) -> CitedEntry? {
        guard let page = document.page(at: landing.pageIndex) else { return nil }
        let boxes = characterBoxes(on: page)
        guard let start = landingCharacter(at: landing.point, boxes: boxes) else { return nil }
        let pageStarts = entryStarts[landing.pageIndex] ?? []
        let running = runningLines(of: landing.pageIndex, in: document)
        let visualLine = lineRun(from: start, boxes: boxes)
        var texts = readingOrderEntry(
            from: start, on: page, boxes: boxes, pageStarts: pageStarts, running: running,
            document: document, pageIndex: landing.pageIndex, entryStarts: entryStarts
        )
        // PDFKit may read a hanging number as a line of its own ("99.", then
        // the rest of the line), so the first line is every reading-order
        // line on its baseline. A number set in a column of its own is
        // followed in reading order by the next number, a line below.
        let firstLine = texts.first.map { first in
            texts.prefix { onLine($0.bounds, midY: first.bounds.midY) }.reduce(first.bounds) { $0.union($1.bounds) }
        }
        if let firstLine, visualLine.maxX - firstLine.maxX > 3 * columnGutter {
            texts = columnEntry(from: start, line: visualLine, on: page, boxes: boxes, pageStarts: pageStarts)
        }
        texts = linesBeforeAuthorEntry(texts)
        let text = joined(texts)
        // A figure link lands on a panel letter, not on anything worth showing.
        guard text.count >= minimumLength else { return nil }
        let pieces = texts.flatMap { line in
            line.characterRanges.map { CitedEntry.Piece(pageIndex: landing.pageIndex + (line.onNextPage ? 1 : 0), range: $0) }
        }
        return CitedEntry(
            number: nil,
            text: text.count > maximumLength ? String(text.prefix(maximumLength)) + "…" : text,
            pieces: pieces
        )
    }

    private nonisolated static func readingOrderEntry(
        from start: Int,
        on page: PDFPage,
        boxes: [CGRect],
        pageStarts: [Int],
        running: Set<String>,
        document: PDFDocument,
        pageIndex: Int,
        entryStarts: [Int: [Int]]
    ) -> [Line] {
        let hanging = listIsHanging(boxes: boxes, starts: pageStarts)
        let margins = hanging
            ? pageStarts.compactMap { boxes.indices.contains($0) && !boxes[$0].isNull ? boxes[$0].minX : nil }
            : []
        var entryLines: [Line]
        var reachedPageEnd = false
        if let next = pageStarts.first(where: { $0 > start }) {
            entryLines = lines(on: page, in: NSRange(location: start, length: next - start), leaving: running)
        } else {
            entryLines = linesBeforeGap(on: page, in: NSRange(location: start, length: page.numberOfCharacters - start), leaving: running)
            reachedPageEnd = true
        }
        let whole = entryLines.count
        entryLines = linesBeforeNextEntry(linesBeforeNumber(after: entryLines), margins: margins)
        // The list continues overleaf: an entry that ran on sits directly
        // above the next page's first entry, and the running head a gap above
        // that is left out.
        if reachedPageEnd, entryLines.count == whole,
           let nextPage = document.page(at: pageIndex + 1),
           let nextStarts = entryStarts[pageIndex + 1], let firstNext = nextStarts.first, firstNext > 0 {
            let tail = trailingLines(on: nextPage, before: firstNext, leaving: runningLines(of: pageIndex + 1, in: document))
            // Above that first linked entry there may be others nobody
            // cited; the tail stops at the first line on an entry margin.
            let nextBoxes = characterBoxes(on: nextPage)
            let nextMargins = hanging
                ? nextStarts.compactMap { nextBoxes.indices.contains($0) && !nextBoxes[$0].isNull ? nextBoxes[$0].minX : nil }
                : []
            entryLines += tail.prefix { line in
                !nextMargins.contains { abs(line.bounds.minX - $0) <= 1.5 }
            }.map { line in
                var onNext = line
                onNext.onNextPage = true
                return onNext
            }
        }
        return entryLines
    }

    /// The glyphs of `start`'s line from `start` rightwards, up to the column
    /// gutter: the entry's first line as it sits on the page. An entry number
    /// set in a column of its own can stand as far from its text as a gutter,
    /// so the gap after a run no wider than a number is allowed twice that.
    private nonisolated static func lineRun(from start: Int, boxes: [CGRect]) -> CGRect {
        let first = boxes[start]
        var run = first
        let line = boxes.filter { !$0.isNull && $0.minX >= first.minX - 1 && onLine($0, midY: first.midY) }
            .sorted { $0.minX < $1.minX }
        for box in line where box.minX > first.minX {
            let allowed = run.width < 20 ? 2 * columnGutter : columnGutter
            guard box.minX - run.maxX <= allowed else { break }
            run = run.union(box)
        }
        return run
    }

    /// The entry read off the page: the lines of its column below its first,
    /// until one starts at or left of the entry's own left edge (the next
    /// entry's number), holds another entry's start, or sits a gap below.
    private nonisolated static func columnEntry(
        from start: Int,
        line: CGRect,
        on page: PDFPage,
        boxes: [CGRect],
        pageStarts: [Int]
    ) -> [Line] {
        let startSet = Set(pageStarts)
        var column: [(index: Int, box: CGRect)] = []
        for (index, box) in boxes.enumerated()
        where !box.isNull && box.minX >= line.minX - 1 && box.maxY <= line.maxY + 0.5 {
            column.append((index, box))
        }
        column.sort { $0.box.midY > $1.box.midY }
        // Glyphs grouped into lines, top down.
        var rows: [[(index: Int, box: CGRect)]] = []
        for glyph in column {
            if let midY = rows.last?.first?.box.midY, onLine(glyph.box, midY: midY) {
                rows[rows.count - 1].append(glyph)
            } else {
                rows.append([glyph])
            }
        }
        // Each row as far as its column reaches: from its leftmost glyph to
        // the gutter, which leaves the next column out.
        func columnPart(_ row: [(index: Int, box: CGRect)]) -> [(index: Int, box: CGRect)] {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            guard var run = sorted.first?.box else { return [] }
            var part = [sorted[0]]
            for glyph in sorted.dropFirst() {
                let allowed = run.width < 20 ? 2 * columnGutter : columnGutter
                guard glyph.box.minX - run.maxX <= allowed else { break }
                run = run.union(glyph.box)
                part.append(glyph)
            }
            return part
        }
        guard let firstRow = rows.firstIndex(where: { $0.contains { $0.index == start } }) else { return [] }
        var bottom = line.minY
        var right = line.maxX
        var previous = line
        for row in rows[(firstRow + 1)...] {
            let part = columnPart(row)
            let bounds = part.reduce(CGRect.null) { $0.union($1.box) }
            guard !bounds.isNull else { continue }
            if previous.minY - bounds.maxY > 2 * max(previous.height, 1)
                || bounds.minX <= line.minX + 1.5
                || part.contains(where: { startSet.contains($0.index) }) {
                break
            }
            bottom = min(bottom, bounds.minY)
            right = max(right, bounds.maxX)
            previous = bounds
        }
        let area = CGRect(x: line.minX - 0.5, y: bottom + 0.5, width: right - line.minX + 1, height: line.maxY - bottom - 1)
        guard let selection = page.selection(for: area) else { return [] }
        return selection.selectionsByLine().compactMap { Self.line($0, on: page) }
    }

    /// Lines up to the one that starts the next numbered entry. The entry
    /// after may be one nobody cited, so no link lands on it and nothing else
    /// ends this one there: Nature Aging's ⁸ read on into entry 9, and
    /// Nature Metabolism's ¹⁶, last in its column, into the next column's
    /// numbers "17." and "18.", set in a block of their own.
    nonisolated static func linesBeforeNumber(after lines: [Line]) -> [Line] {
        func number(_ text: String) -> Int? {
            guard let range = text.range(of: #"^\[?\d{1,4}(?=[.\]]|$)"#, options: .regularExpression) else { return nil }
            return Int(text[range].trimmingCharacters(in: CharacterSet(charactersIn: "[")))
        }
        guard let first = lines.first, let own = number(first.text) else { return lines }
        var kept = lines.dropFirst().firstIndex { number($0.text) == own + 1 }.map { Array(lines[..<$0]) } ?? lines
        // An entry last in its column is followed by the page's number.
        while kept.count > 1, let last = kept.last, last.text.allSatisfy(\.isNumber) {
            kept.removeLast()
        }
        return kept
    }

    /// Lines up to the next author-year entry: one that opens with an author after a line that
    /// finished an entry, as the stored list splits it (`PaperReferenceParser.splitIntoEntries`).
    /// An entry nobody cites has no link landing on it to end the one before, so a flush list
    /// read on into it (product owner, 2026-11-08: "each individual citation should always have
    /// their own clickable link"). Only an entry that itself opens with an author is cut so.
    nonisolated static func linesBeforeAuthorEntry(_ lines: [Line]) -> [Line] {
        guard lines.count > 1, let first = lines.first,
              ReferenceEntryShape.opensWithAuthor(first.text) || ReferenceEntryShape.opensWithFullName(first.text) else {
            return lines
        }
        let texts = lines.map(\.text)
        for index in texts.indices.dropFirst() {
            let tail = Array(texts[max(0, index - 3)..<index])
            guard ReferenceEntryShape.looksFinished(tail) else { continue }
            let line = texts[index]
            if ReferenceEntryShape.opensWithAuthor(line)
                || (ReferenceEntryShape.endsWithYearOrAddress(tail) && ReferenceEntryShape.opensWithFullName(line)) {
                return Array(lines[..<index])
            }
        }
        return lines
    }

    /// Lines up to the next one that begins at an entry's margin — the left
    /// edge an entry's first line starts at, in whichever column. Only a list
    /// whose continuation lines are indented past that margin can be split
    /// this way, so a flush list passes no margins.
    private nonisolated static func linesBeforeNextEntry(_ lines: [Line], margins: [CGFloat]) -> [Line] {
        guard lines.count > 1, !margins.isEmpty else { return lines }
        func margin(of line: Line) -> CGFloat? {
            margins.filter { $0 <= line.bounds.minX + 1.5 }.max()
        }
        for index in lines.indices.dropFirst() {
            if let margin = margin(of: lines[index]), abs(lines[index].bounds.minX - margin) <= 1.5 {
                return Array(lines[..<index])
            }
        }
        return lines
    }

    /// Shorter than any reference or affiliation line.
    static let minimumLength = 8

    /// A reference entry is a few lines; anything longer ran into something
    /// that is not the list.
    static let maximumLength = 900

    struct Line {
        let text: String
        let bounds: CGRect
        /// Whether the page's text runs straight on into the next line with no
        /// space or break between: the typesetter hyphenated a word there,
        /// and PDFKit's text has already closed it up.
        let continuesWord: Bool
        /// The page characters the line is read from, as ranges of the
        /// page's text: what a highlight made on the entry's words is
        /// anchored to.
        var characterRanges: [NSRange] = []
        /// Whether the line sits on the page after the entry's first, where
        /// a list that ran past the foot of a page goes on.
        var onNextPage = false
    }

    /// A reference entry as a citation card shows it.
    struct CitedEntry: Sendable, Equatable {
        /// Its number in the reference list, for an entry named by number.
        var number: Int?
        let text: String
        /// The page characters the text is read from, in reading order, by
        /// page of the file (`Link.pageIndex`'s numbering).
        let pieces: [Piece]

        struct Piece: Sendable, Equatable {
            let pageIndex: Int
            let range: NSRange
        }
    }

    /// A line of a selection as a `Line`, its own line breaks made spaces.
    private nonisolated static func line(_ selection: PDFSelection, on page: PDFPage) -> Line? {
        // A line of accents alone is the spacing accent of a name like
        // "Ferna´ndez", which PDFKit reads as a line of its own, and belongs
        // to no entry.
        guard let raw = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.unicodeScalars.allSatisfy({ [.modifierSymbol, .nonspacingMark].contains($0.properties.generalCategory) })
        else { return nil }
        let count = selection.numberOfTextRanges(on: page)
        var continuesWord = false
        let ranges = (0..<count).map { selection.range(at: $0, on: page) }.filter { $0.location != NSNotFound && $0.length > 0 }
        if count > 0, let pageText = page.string as NSString? {
            let last = selection.range(at: count - 1, on: page)
            let end = NSMaxRange(last)
            if last.location != NSNotFound, last.length > 0, end < pageText.length,
               let before = Unicode.Scalar(pageText.character(at: end - 1)),
               let after = Unicode.Scalar(pageText.character(at: end)) {
                continuesWord = CharacterSet.letters.contains(before) && CharacterSet.letters.contains(after)
            }
        }
        return Line(
            text: raw.components(separatedBy: .newlines).joined(separator: " "),
            bounds: selection.bounds(for: page),
            continuesWord: continuesWord,
            characterRanges: ranges
        )
    }

    private nonisolated static func lines(on page: PDFPage, in range: NSRange, leaving running: Set<String> = []) -> [Line] {
        guard range.length > 0, let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().compactMap { part in
            guard let line = Self.line(part, on: page), !running.contains(runningKey(line.text, at: line.bounds)) else { return nil }
            return line
        }
    }

    /// The page's running heads and feet: lines that recur, in the same place,
    /// on a neighbouring page — two away as well, since a journal mirrors its
    /// heads between left and right pages. A reference that wraps to the next
    /// column is read past them, so they would land in the middle of an entry.
    nonisolated static func runningLines(of pageIndex: Int, in document: PDFDocument) -> Set<String> {
        func keys(_ index: Int) -> Set<String> {
            guard let page = document.page(at: index), let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
            return Set(selection.selectionsByLine().compactMap { line in
                // An entry's number alone ("89.") also recurs in place on
                // the next page; a running head has words.
                guard let raw = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw.unicodeScalars.filter(CharacterSet.letters.contains).count >= 2 else { return nil }
                return runningKey(raw.components(separatedBy: .newlines).joined(separator: " "), at: line.bounds(for: page))
            })
        }
        let own = keys(pageIndex)
        guard !own.isEmpty else { return [] }
        let neighbours = [pageIndex - 2, pageIndex - 1, pageIndex + 1, pageIndex + 2].reduce(into: Set<String>()) { $0.formUnion(keys($1)) }
        return own.intersection(neighbours)
    }

    /// A line compared by where it sits and by its text without digits, since
    /// a running foot carries the page number.
    private nonisolated static func runningKey(_ text: String, at bounds: CGRect) -> String {
        let letters = String(text.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) }.map(Character.init))
        return "\(Int(bounds.minX.rounded())),\(Int(bounds.minY.rounded())) \(letters)"
    }

    /// The lines of `range` up to a gap wider than two lines below the one
    /// before: that is the end of the list, or a footer. A jump back up the
    /// page is the next column and continues the entry.
    private nonisolated static func linesBeforeGap(on page: PDFPage, in range: NSRange, leaving running: Set<String>) -> [Line] {
        var kept: [Line] = []
        for line in lines(on: page, in: range, leaving: running) {
            if let previous = kept.last, previous.bounds.minY - line.bounds.maxY > 2 * max(previous.bounds.height, 1) {
                break
            }
            kept.append(line)
        }
        return kept
    }

    /// The lines directly above a page's first entry, walking up until a gap:
    /// the tail of an entry that began on the page before.
    private nonisolated static func trailingLines(on page: PDFPage, before character: Int, leaving running: Set<String>) -> [Line] {
        let all = lines(on: page, in: NSRange(location: 0, length: character), leaving: running)
        guard let firstEntry = lines(on: page, in: NSRange(location: character, length: 1)).first else { return [] }
        var kept: [Line] = []
        var below = firstEntry
        for line in all.reversed() {
            guard line.bounds.minY - below.bounds.maxY <= 2 * max(below.bounds.height, 1),
                  line.bounds.minY >= below.bounds.maxY - 1 else { break }
            kept.insert(line, at: 0)
            below = line
        }
        return kept
    }

    /// The DOI printed in a reference entry, if any: the first `10.` prefix
    /// with a suffix, up to the next space, less the sentence's closing
    /// punctuation (and a parenthesis the DOI did not open).
    nonisolated static func doi(inReferenceEntry text: String) -> String? {
        // A DOI is printable ASCII; anything else run on to it is the page's
        // text, not the DOI. Science sets soft hyphens in its DOIs and BMC
        // non-breaking ones, which are the DOI's own hyphens.
        let text = text.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2010}", with: "-")
        guard let range = text.range(of: #"10\.\d{4,9}/[!#-;=?-~]+"#, options: .regularExpression) else { return nil }
        var doi = String(text[range])
        while let last = doi.last {
            if ".,;:".contains(last) {
                doi.removeLast()
            } else if last == ")", doi.filter({ $0 == ")" }).count > doi.filter({ $0 == "(" }).count {
                doi.removeLast()
            } else {
                break
            }
        }
        return doi.contains("/") && !doi.hasSuffix("/") ? doi : nil
    }

    /// Lines joined into one paragraph. PDFKit's text has already closed up
    /// a word the typesetter hyphenated, but its lines still split it, so a
    /// line whose text runs straight on is joined without a space.
    nonisolated static func joined(_ lines: [Line]) -> String {
        var text = ""
        var continuesWord = false
        for line in lines {
            if continuesWord, !text.isEmpty {
                text += line.text
            } else {
                text = joined([text, line.text].filter { !$0.isEmpty })
            }
            continuesWord = line.continuesWord
        }
        return text
    }

    /// Line texts joined into one paragraph. A word hyphenated across a line
    /// break is closed back up; a hyphen before a capital is a real one
    /// ("Taylor-\nKing") and stays, joined without a space, as does a web
    /// address or DOI the line broke.
    nonisolated static func joined(_ lines: [String]) -> String {
        var text = ""
        for line in lines {
            guard !text.isEmpty else { text = line; continue }
            let lastWord = text.split(separator: " ").last.map(String.init) ?? ""
            if text.hasSuffix("-"), text.dropLast().last?.isLetter == true {
                if line.first?.isLowercase == true { text.removeLast() }
                text += line
            } else if lastWord.hasPrefix("http") || lastWord.hasPrefix("doi") || text.hasSuffix("/"),
                      !(text.hasSuffix(".") && line.first?.isUppercase == true) {
                // An address broken across lines — unless it ended its
                // sentence and the next line starts another.
                text += line
            } else if lastWord.range(of: #"10\.\d{4,9}/"#, options: .regularExpression) != nil,
                      let next = line.first,
                      next.isNumber || (lastWord.hasSuffix("-") && next.isLowercase),
                      lastWord.hasSuffix("-") || lastWord.hasSuffix(".") {
                // A DOI the line broke at a hyphen or a dot, as Science and
                // Cell Reports print them: "doi: 10.1016/j.celrep." then
                // "2016.10.061".
                text += line
            } else {
                text += " " + line
            }
        }
        return text
    }
}

// MARK: - Which library source an entry names

extension PDFReferenceEntries {
    /// A library source a reference entry may name: its id, the DOIs it is
    /// known by, and its title.
    struct LibraryCandidate: Sendable {
        let id: String
        let dois: [String]
        let title: String
    }

    /// The source a reference entry names: the one with the DOI the entry
    /// prints, else the one whose title the entry prints — the longest such,
    /// since a short title can sit inside a longer one. Nil when neither
    /// settles it; the Mac then asks Crossref, which the phone cannot.
    nonisolated static func librarySourceID(forEntry entry: String, in candidates: [LibraryCandidate]) -> String? {
        if let doi = doi(inReferenceEntry: entry)?.lowercased() {
            return candidates.first { candidate in
                candidate.dois.contains { bareDOI($0) == doi }
            }?.id
        }
        return candidates
            .filter { self.entry(entry, printsTitle: $0.title) }
            .max { $0.title.count < $1.title.count }?
            .id
    }

    /// Whether `title` is printed in a reference entry. Compared on letters and
    /// digits alone, so a word the page split across a line ("hu man") and
    /// Crossref's inline markup (`<i>E. coli</i>`) do not matter; a title too
    /// short to identify anything by containment never matches.
    nonisolated static func entry(_ entry: String, printsTitle title: String) -> Bool {
        // Markup is dropped from both sides: a reference list prints an
        // italicised species name as markup, and a tag left in would survive
        // the identity key as a stray letter and break the containment.
        let key = titleKey(title)
        guard key.count >= 16 else { return false }
        return titleKey(entry).contains(key)
    }

    /// Compatibility forms fold to their plain letters and digits too: a
    /// library title keeps a catalog's `H<sub>2</sub>O<sub>2</sub>` as "H₂O₂",
    /// which a reference list prints as "H2O2", and a PDF's "ﬁ" ligature is "fi".
    private nonisolated static func titleKey(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A DOI as stored — bare, or as a doi.org address — in lower case.
    private nonisolated static func bareDOI(_ value: String) -> String {
        var doi = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"]
        where doi.hasPrefix(prefix) {
            doi.removeFirst(prefix.count)
        }
        return doi
    }
}

/// What a reference entry's lines look like: where one opens and where one has finished. Shared
/// by the stored list's reader (`PaperReferenceParser`) and the citation card's (`PDFReferenceEntries`)
/// on the Mac and the iPhone, so the two split a list alike.
enum ReferenceEntryShape {
    /// A line that opens an author-year entry: a surname, then either a comma and initials
    /// ("Smith, J.", "van der Berg, A.B.", "Lee, K-H.") or initials without the comma
    /// ("Albamonte MS,", "Allen JF,").
    static let authorYearStart: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:\p{Lu}[\p{L}'\x{2019}\-]+(?:\s(?:de|van|von|der|den|la|le|del|di|da|el|al|bin|ibn|ten|ter|dos|das|du|\p{Lu}[\p{L}'\x{2019}\-]+)){0,3},\s+\p{Lu}[.\p{L}\-]{0,3}(?:[\s.,]|$)|(?:(?:de|van|von|der|den|la|le|del|di|da|el|al|bin|ibn|ten|ter|dos|das|du)\s)*\p{Lu}[\p{L}'\x{2019}\-]+\s\p{Lu}{1,3}[,.])"#
    )

    /// A line that opens an entry with its first author's initials before the surname, as
    /// machine-learning papers and Science print them ("J. Abramson, J. Adler, …",
    /// "C. D. Allis and T. Jenuwein.", "H. Abdine et al.", "L.Nestler,K.Parker"): the surname
    /// is followed by a comma, "and", "&" or "et al.".
    static let initialsFirstStart: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\p{Lu}\.(?:\s?-?\p{Lu}\.)*\s?(?:(?:de|van|von|der|den|la|le|del|di|da|du)\s)*\p{Lu}[\p{L}'\x{2019}\-]+(?:,|\s+(?:and|&)\s|\s+et\s+al\.)"#
    )

    static func opensWithAuthor(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return [authorYearStart, initialsFirstStart].contains { opener in
            opener?.firstMatch(in: line, range: range) != nil
        }
    }

    static let fullNameStart: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\p{Lu}[\p{Ll}'\x{2019}\-]+(?:\s(?:\p{Lu}\.?|\p{Lu}{2,3}|\p{Lu}[\p{Ll}'\x{2019}\-]+|de|van|von|der|den|la|le|del|di|da|du)){1,3},\s"#
    )

    /// "Justas Dauparas, …", "Karel HM van Wely, …", "Qiu Zhengqi, …".
    static func opensWithFullName(_ line: String) -> Bool {
        fullNameStart?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// An entry closed on its year ("…, 2021.", "(2021).") or on the address it ends with.
    static func endsWithYearOrAddress(_ lines: [String]) -> Bool {
        let text = lines.suffix(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if text.range(of: #"(?:19|20)\d{2}[a-z]?\)?\.$"#, options: .regularExpression) != nil { return true }
        guard let last = lines.last?.split(separator: " ").last else { return false }
        return last.hasPrefix("http") || last.range(of: #"10\.\d{4,9}/"#, options: .regularExpression) != nil
    }

    /// Whether the lines read as a whole reference: long enough, and ending where one ends.
    static func looksFinished(_ lines: [String]) -> Bool {
        let text = lines.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard text.count >= 25, let last = text.last else { return false }
        // An author's initials end a line inside the author list ("… A.M. Pham, R.L."), never
        // an entry: the next line is the next author ("Graham, S. Hess, and …"), not the next
        // entry. "U.S.A." is a journal's name, which may end one.
        if !text.hasSuffix("U.S.A."),
           let initials = text.range(of: #"(?:^|[\s,])\p{Lu}\.(?:-?\p{Lu}\.)*$"#, options: .regularExpression),
           // A letter after a number ("24, 39541 I.") is a misread page, not a name.
           text[..<initials.lowerBound].trimmingCharacters(in: .whitespaces).last?.isNumber != true {
            return false
        }
        return last.isNumber || ".)]\"'\u{201D}\u{2019}".contains(last)
    }
}
