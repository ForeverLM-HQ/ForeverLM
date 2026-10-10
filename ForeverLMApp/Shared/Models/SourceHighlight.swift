import CoreGraphics
import Foundation

/// A passage the reader marked, with the note they wrote about it.
///
/// One row per marked passage in `source_highlights`; the note is optional, so
/// pressing Note and saving an empty field leaves a bare highlight. Every
/// reader family stores the same portable text-quote anchor, and PDFs carry an
/// extra page/quads anchor because PDFKit can paint those directly without
/// re-scanning the document text. A mark made over a web page's pictures
/// carries those pictures too (`imageAnchors`): a figure has no words to
/// quote, so the painter finds it by the picture itself.
struct SourceHighlight: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    /// The passage as it read when it was marked. Also the anchor's `exact`.
    /// Empty for a mark that is only pictures.
    var quote: String
    /// What the reader wrote. Empty means a bare highlight. Always the
    /// learner's own words: research writes `publicationUpdate` instead.
    var note: String
    var color: SourceHighlightColor
    var anchor: ReaderTextAnchor
    /// Present only for PDFs, where the selection has page geometry.
    var pdfAnchor: ReaderPDFAnchor?
    /// The pictures the selection covered, in page order. Empty for every
    /// text-only mark, and always empty beside a `pdfAnchor`: a PDF's
    /// figures are reached by the chat's figure tools, not by a drag.
    var imageAnchors: [ReaderImageAnchor] = []
    /// The chat this mark's note came from, when there is one: a What's New
    /// chat researching what has changed since the source was written, or a
    /// chat an assistant saved over MCP and linked here. The reader offers it
    /// from the mark. Nil for a mark the reader made and wrote on by hand.
    /// Not a foreign key: CloudKit can deliver the mark before the chat, and
    /// a deleted chat leaves the note standing on its own.
    var chatSessionID: String? = nil
    /// The papers and pages the note cites, in the order it names them: What's
    /// New lists what it found here, and the reader offers each one from the
    /// mark, to open or to add to the library. Empty for every other mark.
    var references: [SourceHighlightReference] = []
    /// What has been learned since the source was written, as What's New (or
    /// an assistant over MCP) put it: a headline sentence on its first line,
    /// then the detail, naming `references` by their citations. Empty for a
    /// mark nobody has researched. Kept apart from `note` so the learner's
    /// thinking and the literature's never overwrite each other, and so the
    /// reader can show the update as what it is rather than as a comment.
    var publicationUpdate: String = ""
    /// When `publicationUpdate` was last written; nil when there is none.
    var publicationUpdateAt: Date? = nil
    let createdAt: Date
    var updatedAt: Date

    var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPublicationUpdate: Bool {
        !publicationUpdate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sets or clears the since-publication update, stamping when it was
    /// written. Clearing it clears the stamp too.
    mutating func setPublicationUpdate(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        publicationUpdate = trimmed
        publicationUpdateAt = trimmed.isEmpty ? nil : date
    }

    /// The linked chat's id, or nil when there is none worth offering.
    var linkedChatID: String? {
        guard let id = chatSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }

    /// A mark with pictures and no words.
    var isPictureOnly: Bool {
        !imageAnchors.isEmpty && !Self.hasWords(quote)
    }

    /// Whether a passage says anything once whitespace and the characters
    /// that only shape text are set aside. Web pages put zero-width spaces
    /// and joiners between a figure and its caption, and a drag over the
    /// figure alone brings one along as its "text"; that is not a passage,
    /// and the mark it makes is a mark on the picture.
    static func hasWords(_ text: String) -> Bool {
        !text.trimmingCharacters(in: Self.shapingCharacters).isEmpty
    }

    private static let shapingCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        // U+200B zero width space, U+200C/U+200D non-joiner and joiner,
        // U+2060 word joiner, U+FEFF byte order mark.
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
        return set
    }()

    /// What the notes list and the chat chip call this mark when there are no
    /// words to show: the pictures' alt text, or "Picture".
    var pictureLabel: String {
        let alts = imageAnchors.map(\.displayLabel)
        guard let first = alts.first else { return "" }
        if alts.count == 1 { return first }
        return "\(alts.count) pictures"
    }

    /// The `quads_json` column: PDF quads (a JSON array) for a PDF mark, the
    /// pictures (a JSON object) for a web mark on pictures, `[]` otherwise.
    /// One geometry per reader family, in the column the schema already has,
    /// so a mark on a picture needs no schema bump and an older build reads
    /// the object as "no PDF quads".
    var geometryJSON: String {
        if let pdfAnchor { return pdfAnchor.quadsJSON }
        return ReaderImageAnchor.storedJSON(imageAnchors)
    }

    static func newID() -> String { "hl_\(UUID().uuidString.lowercased())" }
}

extension SourceHighlight: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceID, quote, note, color, anchor, pdfAnchor, imageAnchors, chatSessionID, references
        case publicationUpdate, publicationUpdateAt, createdAt, updatedAt
    }

    /// `imageAnchors` is read as optional so a record written before pictures
    /// could be marked decodes as a text-only mark, and `chatSessionID`,
    /// `references` and `publicationUpdate` so a record from before marks
    /// could link a chat, cite papers or carry an update decodes as one
    /// without.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        quote = try container.decode(String.self, forKey: .quote)
        note = try container.decode(String.self, forKey: .note)
        color = try container.decode(SourceHighlightColor.self, forKey: .color)
        anchor = try container.decode(ReaderTextAnchor.self, forKey: .anchor)
        pdfAnchor = try container.decodeIfPresent(ReaderPDFAnchor.self, forKey: .pdfAnchor)
        imageAnchors = try container.decodeIfPresent([ReaderImageAnchor].self, forKey: .imageAnchors) ?? []
        chatSessionID = try container.decodeIfPresent(String.self, forKey: .chatSessionID)
        references = try container.decodeIfPresent([SourceHighlightReference].self, forKey: .references) ?? []
        publicationUpdate = try container.decodeIfPresent(String.self, forKey: .publicationUpdate) ?? ""
        publicationUpdateAt = publicationUpdate.isEmpty
            ? nil
            : try container.decodeIfPresent(Date.self, forKey: .publicationUpdateAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(quote, forKey: .quote)
        try container.encode(note, forKey: .note)
        try container.encode(color, forKey: .color)
        try container.encode(anchor, forKey: .anchor)
        try container.encodeIfPresent(pdfAnchor, forKey: .pdfAnchor)
        // Left out when empty, so a text-only mark's record is byte for byte
        // what it was before pictures existed.
        if !imageAnchors.isEmpty {
            try container.encode(imageAnchors, forKey: .imageAnchors)
        }
        // Likewise: a mark with no chat encodes exactly as it did before
        // marks could carry one.
        try container.encodeIfPresent(linkedChatID, forKey: .chatSessionID)
        if !references.isEmpty {
            try container.encode(references, forKey: .references)
        }
        if hasPublicationUpdate {
            try container.encode(publicationUpdate, forKey: .publicationUpdate)
            try container.encodeIfPresent(publicationUpdateAt, forKey: .publicationUpdateAt)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - Cited papers

/// A paper or page a mark's note cites. The address is its identity, and a DOI
/// is kept as its doi.org link, the form the library's DOI matching reads
/// (`StudioViewModel.librarySourceID(forURL:)`); the citation is how the note
/// names it, which is what the reader shows on the mark.
struct SourceHighlightReference: Equatable, Hashable, Sendable {
    /// How the note names it: "Vozza et al., PNAS 2014".
    var citation: String
    /// The paper's own title, when the writer knew it; empty otherwise.
    var title: String
    /// Its doi.org link, or the page's address.
    var url: String

    init(citation: String, title: String = "", url: String) {
        self.citation = citation
        self.title = title
        self.url = url
    }

    /// The most one mark carries. What's New names a handful; a longer list
    /// belongs in the chat the research came from.
    static let maximumPerMark = 20
    static let maximumCitationLength = 200
    static let maximumTitleLength = 500

    /// A reference from what a writer supplied: how the note names the paper,
    /// and its DOI or its address. Nil when there is no citation, or nothing
    /// the reader could open: a DOI becomes its doi.org link, and an address
    /// must be an absolute http(s) one.
    static func make(citation: String, title: String? = nil, url: String? = nil, doi: String? = nil) -> SourceHighlightReference? {
        let citation = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !citation.isEmpty else { return nil }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let address: String
        if let doiLink = doiLink(doi) {
            address = doiLink
        } else if let web = webAddress(url) {
            // An address that is a DOI in disguise ("doi:10…", a bare DOI) is
            // stored as its link, so the library matches it the same way.
            address = doiLink(web) ?? web
        } else if let doiLink = doiLink(url) {
            address = doiLink
        } else {
            return nil
        }
        return SourceHighlightReference(
            citation: String(citation.prefix(maximumCitationLength)),
            title: String(title.prefix(maximumTitleLength)),
            url: address
        )
    }

    /// `https://doi.org/<doi>` for a DOI written bare, as `doi:10…`, or as a
    /// doi.org link. Nil for anything that is not a DOI.
    static func doiLink(_ raw: String?) -> String? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard text.hasPrefix("10."), let slash = text.firstIndex(of: "/"),
              text.index(after: slash) < text.endIndex,
              !text.contains(where: \.isWhitespace) else { return nil }
        return "https://doi.org/" + text
    }

    private static func webAddress(_ raw: String?) -> String? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return text
    }

    /// The `references_json` column: the list as JSON, or nil when empty.
    static func storedJSON(_ references: [SourceHighlightReference]) -> String? {
        guard !references.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(references) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The list a stored column holds; empty for NULL or anything unreadable.
    static func references(storedJSON: String?) -> [SourceHighlightReference] {
        guard let data = storedJSON?.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SourceHighlightReference].self, from: data)) ?? []
    }
}

extension SourceHighlightReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case citation, title, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        citation = try container.decode(String.self, forKey: .citation)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try container.decode(String.self, forKey: .url)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(citation, forKey: .citation)
        if !title.isEmpty {
            try container.encode(title, forKey: .title)
        }
        try container.encode(url, forKey: .url)
    }
}

// MARK: - Since-publication update layout

/// How the reader lays out a mark's since-publication update: its headline,
/// and the words around each paper it cites, with every citation the mark's
/// `references` names turned into that paper's number in the list below it.
///
/// Nothing here reads the text for meaning. The headline is the first line,
/// because that is how What's New is asked to write one; an update written as
/// one paragraph simply has none. A citation is found by the exact words the
/// reference itself records as how the note names it, and the brackets
/// around a group of them go with them: "channel (Bridges et al., Science
/// 2023)" reads "channel¹", while "Bridges et al., Science 2023 showed"
/// keeps its words and gains the number.
struct PublicationUpdateLayout: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case text(String)
        /// A cited paper, by its 1-based place in the mark's references, and
        /// the words that named it when they are part of the sentence. A
        /// citation that stood in brackets has none: its number says it.
        case citation(Int, words: String?)
    }

    /// The first line when the update has more after it, else nil.
    var headline: [Segment]?
    var body: [Segment]

    init(update: String, references: [SourceHighlightReference]) {
        let trimmed = update.trimmingCharacters(in: .whitespacesAndNewlines)
        let citations = references.map { $0.citation.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let newline = trimmed.firstIndex(of: "\n") {
            let first = trimmed[..<newline].trimmingCharacters(in: .whitespaces)
            let rest = trimmed[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !first.isEmpty, !rest.isEmpty {
                headline = Self.segments(first, citations: citations)
                body = Self.segments(rest, citations: citations)
                return
            }
        }
        headline = nil
        body = Self.segments(trimmed, citations: citations)
    }

    static func segments(_ text: String, citations: [String]) -> [Segment] {
        // Every place a citation's own words appear, earliest first, a longer
        // citation winning over one it contains.
        var matches: [(range: Range<String.Index>, number: Int)] = []
        for (offset, citation) in citations.enumerated() where !citation.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: citation, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                matches.append((found, offset + 1))
                searchStart = found.upperBound
            }
        }
        matches.sort {
            $0.range.lowerBound == $1.range.lowerBound
                ? text.distance(from: $0.range.lowerBound, to: $0.range.upperBound) > text.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
                : $0.range.lowerBound < $1.range.lowerBound
        }
        var segments: [Segment] = []
        var cursor = text.startIndex
        for match in matches where match.range.lowerBound >= cursor {
            if cursor < match.range.lowerBound {
                segments.append(.text(String(text[cursor..<match.range.lowerBound])))
            }
            segments.append(.citation(match.number, words: String(text[match.range])))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.text(String(text[cursor...])))
        }
        return dropCitationBrackets(segments)
    }

    /// "(¹; ²)" becomes "¹²", and the space before the bracket goes with it.
    /// A bracket holding anything besides citations and their separators is
    /// the writer's own and stays.
    private static func dropCitationBrackets(_ segments: [Segment]) -> [Segment] {
        var result = segments
        var index = 0
        while index < result.count {
            guard case .text(let before) = result[index], before.hasSuffix("("),
                  index + 1 < result.count, case .citation = result[index + 1] else {
                index += 1
                continue
            }
            // Walk the run: citation, separator, citation, …, then ")".
            var cursor = index + 1
            var separators: [Int] = []
            var closing: (index: Int, rest: String)?
            while cursor < result.count {
                if case .citation = result[cursor] {
                    cursor += 1
                    continue
                }
                guard case .text(let between) = result[cursor] else { break }
                let trimmed = between.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(")") {
                    closing = (cursor, String(between.drop { $0 == " " }.dropFirst()))
                    break
                }
                guard Self.isCitationSeparator(trimmed),
                      cursor + 1 < result.count, case .citation = result[cursor + 1] else { break }
                separators.append(cursor)
                cursor += 1
            }
            guard let closing else {
                index += 1
                continue
            }
            for position in (index + 1)..<closing.index {
                if case .citation(let number, _) = result[position] {
                    result[position] = .citation(number, words: nil)
                }
            }
            if closing.rest.isEmpty {
                result.remove(at: closing.index)
            } else {
                result[closing.index] = .text(closing.rest)
            }
            for separator in separators.reversed() {
                result.remove(at: separator)
            }
            var opened = String(before.dropLast())
            while opened.last == " " { opened.removeLast() }
            if opened.isEmpty {
                result.remove(at: index)
            } else {
                result[index] = .text(opened)
                index += 1
            }
        }
        return result
    }

    private static func isCitationSeparator(_ text: String) -> Bool {
        [";", ",", "and", "; ", ", "].contains(text) || text == "&"
    }
}

// MARK: - Picture anchor

/// A picture a mark covers, as the page described it.
///
/// A web page's picture has no text to quote, so the mark is anchored to the
/// picture itself: the URL the page resolved it from, its alt text and its
/// natural size. The reader re-finds it by URL first and by file name second —
/// a CDN rewrites the query and the size segment of a URL between two fetches
/// of the same page, and the file name is what survives — and paints an
/// outline around it, since the CSS highlight that tints words cannot tint a
/// picture. The text-quote anchor beside it still carries the words around
/// the picture (with an empty passage), so the mark keeps its place in the
/// notes list's reading order.
struct ReaderImageAnchor: Equatable, Sendable, Codable {
    /// The picture's URL as the page resolved it (`currentSrc`), absolute.
    var src: String
    var alt: String
    /// Natural size in pixels; 0 when the page did not know it.
    var width: Int
    var height: Int

    init(src: String, alt: String = "", width: Int = 0, height: Int = 0) {
        self.src = src.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alt = ReaderImageAnchor.cleanedAlt(alt)
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// The alt text, on one line, or "Picture" when the page gave none.
    var displayLabel: String {
        alt.isEmpty ? "Picture" : alt
    }

    /// The URL's last path component: what the reader matches on when the
    /// full URL has moved.
    var fileName: String {
        ReaderImageAnchor.fileName(of: src)
    }

    static func cleanedAlt(_ alt: String) -> String {
        alt.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func fileName(of src: String) -> String {
        guard let path = URLComponents(string: src)?.path else { return "" }
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return name.removingPercentEncoding ?? name
    }

    // MARK: Storage

    private struct Stored: Codable {
        var images: [ReaderImageAnchor]
    }

    /// The `quads_json` column's shape for pictures: `{"images":[…]}`, or `[]`
    /// when there are none — the array an older build and a PDF mark expect.
    static func storedJSON(_ anchors: [ReaderImageAnchor]) -> String {
        // Sorted keys: the same pictures always store the same text, so a
        // re-save is no change and two Macs never trade key orders.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !anchors.isEmpty,
              let data = try? encoder.encode(Stored(images: anchors)),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// The pictures a `quads_json` value names; empty for PDF quads, `[]`, or
    /// anything else.
    static func anchors(storedJSON: String) -> [ReaderImageAnchor] {
        guard storedJSON.first == "{",
              let data = storedJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.images.filter { !$0.src.isEmpty }
    }
}

// MARK: - Color

/// The marker colors offered in the composer. Stored as the raw string so a
/// database written by a build with more colors still loads here.
enum SourceHighlightColor: String, CaseIterable, Sendable, Codable {
    case yellow
    case green
    case blue
    case pink
    case purple

    static let `default` = SourceHighlightColor.yellow

    init(storedValue: String?) {
        self = SourceHighlightColor(rawValue: storedValue ?? "") ?? .default
    }

    /// The marker closest to a color another app painted with, by hue, so a
    /// mark brought over from Zotero or a PDF keeps its meaning: red and
    /// magenta read as pink, orange as yellow. A grey or near-white mark has
    /// no hue to go by and takes the default.
    init(nearestTo red: Double, green: Double, blue: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum
        guard maximum > 0, chroma / maximum >= 0.15 else {
            self = .default
            return
        }
        var hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / chroma)
        } else if maximum == green {
            hue = 60 * ((blue - red) / chroma + 2)
        } else {
            hue = 60 * ((red - green) / chroma + 4)
        }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<20: self = .pink
        case ..<75: self = .yellow
        case ..<165: self = .green
        case ..<245: self = .blue
        case ..<290: self = .purple
        default: self = .pink
        }
    }

    /// `#rrggbb`, as Zotero stores an annotation's color; nil for anything else.
    init?(hex: String?) {
        guard var digits = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            nearestTo: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// sRGB components used by every renderer: SwiftUI swatches, PDF
    /// annotations and the CSS the web readers paint with.
    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow: return (1.00, 0.85, 0.30)
        case .green: return (0.55, 0.88, 0.55)
        case .blue: return (0.55, 0.79, 1.00)
        case .pink: return (1.00, 0.66, 0.78)
        case .purple: return (0.78, 0.69, 1.00)
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }

    /// `rgba(...)` for the web readers' highlight painting.
    func cssColor(alpha: Double) -> String {
        let rgb = components
        let channel = { (value: Double) in Int((value * 255).rounded()) }
        return "rgba(\(channel(rgb.red)), \(channel(rgb.green)), \(channel(rgb.blue)), \(alpha))"
    }
}

// MARK: - PDF anchor

/// Where a marked passage sits on a PDF page, in PDFKit page coordinates.
struct ReaderPDFAnchor: Equatable, Sendable, Codable {
    var pageIndex: Int
    var quads: [Quad]

    struct Quad: Equatable, Sendable, Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init(pageIndex: Int, rects: [CGRect]) {
        self.pageIndex = pageIndex
        self.quads = rects.map(Quad.init)
    }

    var rects: [CGRect] { quads.map(\.rect) }

    var quadsJSON: String {
        guard let data = try? JSONEncoder().encode(quads),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    init?(pageIndex: Int, quadsJSON: String) {
        guard let data = quadsJSON.data(using: .utf8),
              let quads = try? JSONDecoder().decode([Quad].self, from: data),
              !quads.isEmpty else { return nil }
        self.pageIndex = pageIndex
        self.quads = quads
    }
}

// MARK: - Text anchor

/// A text-quote anchor: the passage itself plus a little of the text on either
/// side, and roughly where it was.
///
/// Every reader can produce and resolve one of these — the web readers over the
/// page's text content, the transcript readers over the string they display,
/// PDFs over the extracted page text — so notes survive a reader switching
/// engines, a source being re-fetched, and reflow, none of which a DOM path or
/// a raw character offset survives. The offset only breaks ties; a passage that
/// moved is still found by its own words.
struct ReaderTextAnchor: Equatable, Sendable, Codable {
    /// How much context is captured on each side. Long enough to disambiguate
    /// repeated sentences, short enough that a small edit nearby doesn't
    /// invalidate the anchor (context only scores candidates, never gates them).
    static let contextLength = 48

    var exact: String
    var prefix: String
    var suffix: String
    /// Character offset of `exact` in the normalized text at the time of
    /// marking. A hint for tie-breaking, not a requirement.
    var offset: Int

    init(exact: String, prefix: String = "", suffix: String = "", offset: Int = 0) {
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
        self.offset = max(0, offset)
    }

    var isEmpty: Bool {
        ReaderTextAnchor.normalize(exact).text.isEmpty
    }

    /// Builds an anchor for `range` within `text`.
    init(text: String, range: Range<String.Index>) {
        let exact = String(text[range])
        let prefixStart = text.index(
            range.lowerBound,
            offsetBy: -ReaderTextAnchor.contextLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let suffixEnd = text.index(
            range.upperBound,
            offsetBy: ReaderTextAnchor.contextLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        let normalizedHead = ReaderTextAnchor.normalize(String(text[text.startIndex..<range.lowerBound]))
        self.init(
            exact: exact,
            prefix: String(text[prefixStart..<range.lowerBound]),
            suffix: String(text[range.upperBound..<suffixEnd]),
            offset: normalizedHead.text.count
        )
    }
}

// MARK: Resolution

extension ReaderTextAnchor {
    /// Whitespace-collapsed text plus a map from each normalized character back
    /// to its index in the original.
    ///
    /// Readers disagree about whitespace for the same passage — PDF extraction
    /// inserts line breaks mid-sentence, HTML carries indentation into
    /// `textContent` — so all matching happens in this projection and results
    /// are mapped back through `indices`. They disagree about soft hyphens
    /// (U+00AD) too: a PDF page or a web page keeps the ones its layout put
    /// in a word, while the text a source keeps has none
    /// (`removingSoftHyphens()`), and a mark made in either is resolved in the
    /// other. The projection leaves them out.
    struct Normalized {
        var text: String
        /// `indices[i]` is where `text[i]` came from in the original string.
        var indices: [String.Index]
    }

    static func normalize(_ text: String) -> Normalized {
        var out = ""
        var indices: [String.Index] = []
        out.reserveCapacity(text.count)
        indices.reserveCapacity(text.count)

        var pendingSpaceIndex: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{00AD}" {
                // A soft hyphen is a place a word may break, not a character
                // of it: skipped, so "life\u{00AD}span" reads "lifespan" and a
                // run of whitespace around one is still one space.
            } else if character.isWhitespace || character.isNewline {
                // A run of whitespace becomes at most one space, and only once
                // some non-whitespace has been emitted, so the projection never
                // starts with padding the original had.
                if !out.isEmpty { pendingSpaceIndex = pendingSpaceIndex ?? index }
            } else {
                if let spaceIndex = pendingSpaceIndex {
                    out.append(" ")
                    indices.append(spaceIndex)
                    pendingSpaceIndex = nil
                }
                out.append(character)
                indices.append(index)
            }
            index = text.index(after: index)
        }
        return Normalized(text: out, indices: indices)
    }

    /// Finds this anchor's passage in `text`, or nil when it is no longer there.
    ///
    /// Scores every occurrence of the passage by how much of the recorded
    /// context still surrounds it and how near it is to the recorded offset, so
    /// a sentence repeated verbatim across a document still resolves to the
    /// copy that was actually marked.
    func resolve(in text: String) -> Range<String.Index>? {
        let haystack = ReaderTextAnchor.normalize(text)
        let needle = ReaderTextAnchor.normalize(exact).text
        guard !needle.isEmpty, !haystack.text.isEmpty else { return nil }

        let candidates = ReaderTextAnchor.occurrences(of: needle, in: haystack.text)
        guard !candidates.isEmpty else { return nil }

        let normalizedPrefix = ReaderTextAnchor.normalize(prefix).text
        let normalizedSuffix = ReaderTextAnchor.normalize(suffix).text
        let characters = Array(haystack.text)

        let best = candidates.max { lhs, rhs in
            let lhsScore = ReaderTextAnchor.score(
                at: lhs,
                needleLength: needle.count,
                characters: characters,
                prefix: normalizedPrefix,
                suffix: normalizedSuffix,
                expectedOffset: offset
            )
            let rhsScore = ReaderTextAnchor.score(
                at: rhs,
                needleLength: needle.count,
                characters: characters,
                prefix: normalizedPrefix,
                suffix: normalizedSuffix,
                expectedOffset: offset
            )
            return lhsScore < rhsScore
        }
        guard let start = best else { return nil }

        let end = start + needle.count
        guard end <= haystack.indices.count else { return nil }
        let lower = haystack.indices[start]
        // The upper bound is one past the last matched character, which is the
        // successor of that character's original index — not the next
        // normalized character's, which may sit beyond collapsed whitespace.
        let upper = text.index(after: haystack.indices[end - 1])
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private static func occurrences(of needle: String, in haystack: String) -> [Int] {
        var found: [Int] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [], range: searchStart..<haystack.endIndex) {
            found.append(haystack.distance(from: haystack.startIndex, to: range.lowerBound))
            searchStart = haystack.index(after: range.lowerBound)
            // A document that repeats one phrase hundreds of times is not worth
            // scoring exhaustively; the recorded offset picks among the first.
            if found.count >= 64 { break }
        }
        return found
    }

    /// Context agreement dominates; the offset only separates candidates whose
    /// surroundings are equally good (or equally gone).
    private static func score(
        at start: Int,
        needleLength: Int,
        characters: [Character],
        prefix: String,
        suffix: String,
        expectedOffset: Int
    ) -> Double {
        var score = 0.0

        if !prefix.isEmpty {
            let before = characters[max(0, start - prefix.count)..<start]
            score += 2.0 * trailingOverlapRatio(of: prefix, against: Array(before))
        }
        if !suffix.isEmpty {
            let afterStart = min(characters.count, start + needleLength)
            let afterEnd = min(characters.count, afterStart + suffix.count)
            let after = characters[afterStart..<afterEnd]
            score += 2.0 * leadingOverlapRatio(of: suffix, against: Array(after))
        }

        let drift = Double(abs(start - expectedOffset))
        score += 1.0 / (1.0 + drift / 500.0)
        return score
    }

    /// How much of `pattern`'s tail the candidate's preceding text reproduces.
    private static func trailingOverlapRatio(of pattern: String, against candidate: [Character]) -> Double {
        let patternCharacters = Array(pattern)
        guard !patternCharacters.isEmpty, !candidate.isEmpty else { return 0 }
        var matched = 0
        while matched < patternCharacters.count, matched < candidate.count,
              patternCharacters[patternCharacters.count - 1 - matched] == candidate[candidate.count - 1 - matched] {
            matched += 1
        }
        return Double(matched) / Double(patternCharacters.count)
    }

    /// How much of `pattern`'s head the candidate's following text reproduces.
    private static func leadingOverlapRatio(of pattern: String, against candidate: [Character]) -> Double {
        let patternCharacters = Array(pattern)
        guard !patternCharacters.isEmpty, !candidate.isEmpty else { return 0 }
        var matched = 0
        while matched < patternCharacters.count, matched < candidate.count,
              patternCharacters[matched] == candidate[matched] {
            matched += 1
        }
        return Double(matched) / Double(patternCharacters.count)
    }
}
