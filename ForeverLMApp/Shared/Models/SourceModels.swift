// Source status, type and metadata-field models, moved out of Models.swift.

import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Typed status flags stored as sentinel strings in
/// `StudioArticle.errorMessage`. The raw values match the stored strings, so
/// the persisted representation (SQLite `sources.error_message`, and therefore
/// CloudKit sync) is the same. These are distinct from genuine free-text error
/// messages: `StudioArticle.statusFlag` is non-nil only when `errorMessage`
/// exactly equals one of these flags.
enum SourceStatusFlag: String {
    case paywall            // source is behind a paywall; needs a PDF attachment
    case confirmPodcast     // a podcast match was found and awaits user confirmation
    case needsTranscript    // podcast match confirmed but no transcript is available yet
}

enum StudioSourceType: String, Codable {
    case article       // web article, blog post, newsletter (LLM-confirmed)
    case paper         // academic paper
    case podcast       // podcast transcript
    case book          // book chapter PDF
    case course        // course material PDF
    case meeting       // recurring meeting session with transcript/notes/chat artifacts
    case video         // YouTube, Zoom recording, read.ai, etc.
    case xPost         // X/Twitter post
    case manual        // manually added URL
    case unclassified  // web URL awaiting LLM classification (article vs paper)

    /// The families a search filter offers. `manual` and `unclassified` are
    /// storage states of a web page, not kinds of source a reader would name,
    /// so they are not listed; `article` covers them. Offering them made an
    /// assistant sweep the library one family at a time to be thorough.
    static let searchFamilyNames: [String] = ["article", "paper", "podcast", "book", "course", "meeting", "video", "xPost"]

    /// The stored `source_type` values one search family covers, or nil when
    /// the name is not a source type at all. The raw storage states are still
    /// accepted and fold into the article family, so an old schema keeps working.
    static func searchFamily(named name: String) -> [String]? {
        guard let type = StudioSourceType(rawValue: name) else { return nil }
        switch type {
        case .article, .manual, .unclassified:
            return [StudioSourceType.article, .manual, .unclassified].map(\.rawValue)
        default:
            return [type.rawValue]
        }
    }

    /// The SF Symbol a row uses for a source of this type, the one the
    /// sidebar's family icons and the chat's context rows share.
    var symbolName: String {
        switch self {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost: return "bubble.left"
        case .manual: return "link"
        }
    }
}

// MARK: - Metadata Visibility

/// Individual metadata fields that can be shown or hidden per source type.
enum SourceMetadataField: String, CaseIterable, Codable, Hashable {
    case author
    case domain      // website domain or show name
    case date        // date added
    case readTime    // estimated source length in minutes
    case format      // PDF / EPUB badge
    case journal     // papers only
    case year        // papers only
    case kind        // books: category (textbook, etc.)
    case subtitle    // books: subtitle; courses: code · instructors · institution
    case edition     // books only

    var displayName: String {
        switch self {
        case .author:   return "Author"
        case .domain:   return "Source"
        case .date:     return "Date"
        case .readTime: return "Est. Time"
        case .format:   return "Format"
        case .journal:  return "Journal"
        case .year:     return "Year"
        case .kind:     return "Category"
        case .subtitle: return "Details"
        case .edition:  return "Edition"
        }
    }

    var icon: String {
        switch self {
        case .author:   return "person"
        case .domain:   return "globe"
        case .date:     return "calendar"
        case .readTime: return "clock"
        case .format:   return "doc"
        case .journal:  return "building.columns"
        case .year:     return "number"
        case .kind:     return "tag"
        case .subtitle: return "info.circle"
        case .edition:  return "books.vertical"
        }
    }

    func displayName(for sourceType: StudioSourceType) -> String {
        if self == .subtitle, sourceType == .book {
            return "Subtitle"
        }
        // A meeting's "author" is whoever presented it.
        if self == .author, sourceType == .meeting {
            return "Presenter"
        }
        if self == .domain, sourceType == .video {
            return "Channel"
        }
        return displayName
    }

    func icon(for sourceType: StudioSourceType) -> String {
        if self == .subtitle, sourceType == .book {
            return "text.quote"
        }
        if self == .author, sourceType == .meeting {
            return "person.wave.2"
        }
        return icon
    }
}

/// Persisted per-source-type metadata visibility. All fields visible by default; only hidden
/// fields are stored. Conforms to `RawRepresentable<String>` for use with `@AppStorage`.
struct MetadataVisibilitySettings: RawRepresentable, Equatable {
    private var hidden: [String: Set<String>]

    init() { hidden = [:] }

    init?(rawValue: String) {
        self.hidden = [:]
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        self.hidden = decoded.mapValues { Set($0) }
    }

    var rawValue: String {
        let simplified = hidden.mapValues { Array($0) }
        guard let data = try? JSONEncoder().encode(simplified) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func isVisible(_ field: SourceMetadataField, for sourceType: StudioSourceType) -> Bool {
        !(hidden[sourceType.rawValue]?.contains(field.rawValue) ?? false)
    }

    mutating func toggle(_ field: SourceMetadataField, for sourceType: StudioSourceType) {
        var set = hidden[sourceType.rawValue] ?? []
        if set.contains(field.rawValue) {
            set.remove(field.rawValue)
        } else {
            set.insert(field.rawValue)
        }
        hidden[sourceType.rawValue] = set.isEmpty ? nil : set
    }
}

/// Which browser or service an article was discovered from.
enum DiscoveryOrigin: String, Codable {
    case safari
    case chrome
    case brave
    case applePodcasts
    case localBooks
    case localCourses
    case localMeetings
    case googleDriveMeetings
    case readAI
    /// A Zoom cloud recording, added from its share or play link.
    case zoom
    case localPapers
    case youtubePlaylist
    case xBookmarks
    case manual
    /// Added by a user-built plugin over MCP (an ingest-scoped OAuth
    /// client). The specific plugin is recorded in
    /// `StudioArticle.connectorLabel`, never inferred from tool arguments.
    case plugin = "connector"
}

enum SourceStatus: String, Codable {
    case active
    case archived
}

enum SourceIdentity {
    static func stableID(for url: String) -> String {
        let key = "source:v1:\(URLNormalizer.normalize(url))"
        let digest = SHA256.hash(data: Data(key.utf8))
        return "src_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A file captured on the iPhone or the web, from the lowercase hex sha256 of its bytes
    /// (docs/cloudkit-schema-design.md D47): the same bytes captured twice are one source. The Mac's
    /// own file imports keep their path-based ids and carry the `file:` work key instead, so a capture
    /// of a PDF this Mac already holds is found by lookup before it is minted.
    static func fileID(sha256 fileHash: String) -> String {
        SyncIdentity.sourceFileID(sha256Hex: fileHash.lowercased())
    }
}

extension AIUsageSource {
    init(source: StudioArticle) {
        self.init(
            id: source.id,
            type: source.sourceType == .podcast ? "podcast_episode" : source.sourceType.rawValue,
            title: source.title
        )
    }

    init(id: String, sourceType: StudioSourceType, title: String) {
        self.init(
            id: id,
            type: sourceType == .podcast ? "podcast_episode" : sourceType.rawValue,
            title: title
        )
    }
}

/// Where the learner left off inside an EPUB: which chapter file, and how far down
/// it. The third encoding of `sources.reading_position_locator`; `relativePath` is
/// required, which is what keeps it from decoding an article or video locator.
/// Turns a reader's saved *resume locator* back into a 0...1 depth, the currency
/// `source_activity_days.max_fraction` is kept in.
///
/// Every reader already persists a position on each scroll or page turn so it can
/// resume where the learner left off. That position is also the cheapest honest
/// answer to "how much of this actually landed", and until this existed the depth
/// ledger simply never heard about reading — only the audio player ever wrote a
/// fraction, so the Schedule had to fall back on "it was opened" and call that
/// done.
///
/// A locator only qualifies when its fraction covers the *whole* source. Book
/// chapters are separate sources whose locator is scoped to that chapter's file,
/// so those count; a PDF page index carries no total and is supplied directly by
/// the reader instead.
enum SourceProgressDepth {
    static func fraction(locator: String?) -> Double? {
        guard let locator, !locator.isEmpty else { return nil }
        if let article = ArticleReadingPositionLocator(encoded: locator) {
            return article.webScrollFraction
        }
        if let video = VideoWatchProgress(encoded: locator) {
            return video.fractionWatched
        }
        if let chapter = EPUBReadingPositionLocator(encoded: locator) {
            return chapter.scrollFraction
        }
        return nil
    }

    /// Depth implied by landing on a zero-based page index. The last page is a
    /// full read: a PDF's final page is its end, however little of it is text.
    static func fraction(pageIndex: Int, pageCount: Int) -> Double? {
        guard pageIndex >= 0, pageCount > 0 else { return nil }
        guard pageCount > 1 else { return 1 }
        return min(max(Double(pageIndex) / Double(pageCount - 1), 0), 1)
    }
}

struct EPUBReadingPositionLocator: Codable, Equatable {
    let relativePath: String
    let scrollFraction: Double

    init(relativePath: String, scrollFraction: Double) {
        self.relativePath = relativePath
        let clamped = min(max(scrollFraction, 0), 1)
        self.scrollFraction = (clamped * 10_000).rounded() / 10_000
    }

    init?(encoded: String?) {
        guard let encoded,
              let data = encoded.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              !decoded.relativePath.isEmpty else { return nil }
        self = decoded
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    /// The named references every ingestion path decodes. A lookup table rather
    /// than the full HTML5 entity set: these are the names real sources emit —
    /// smart quotes, dashes, the accented Latin letters in author names, and the
    /// typographic and math symbols that survive a web extraction.
    private static let htmlNamedCharacterReferences: [String: String] = [
        // `&nbsp;` deliberately becomes a plain space: extracted text is reflowed
        // for reading, and a no-break space there only produces odd line breaks.
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">",
        // `&shy;` is the soft hyphen, and decodes to it as `&#173;` always has.
        // The text a source keeps drops it where that text is derived
        // (`removingSoftHyphens()`), not here: a decoded attribute or address
        // stays what it says.
        "shy": "\u{00AD}",
        "quot": "\"", "apos": "'",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "minus": "\u{2212}",
        "hellip": "\u{2026}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "sbquo": "\u{201A}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "bdquo": "\u{201E}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "bull": "\u{2022}", "middot": "\u{00B7}",
        "prime": "\u{2032}", "Prime": "\u{2033}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "sect": "\u{00A7}", "para": "\u{00B6}",
        "thinsp": " ", "ensp": " ", "emsp": " ",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "micro": "\u{00B5}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "approx": "\u{2248}", "asymp": "\u{2248}", "equiv": "\u{2261}",
        "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}",
        "tilde": "\u{02DC}", "infin": "\u{221E}", "radic": "\u{221A}",
        "sum": "\u{2211}", "prod": "\u{220F}", "int": "\u{222B}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}",
        "darr": "\u{2193}", "harr": "\u{2194}",
        "euro": "\u{20AC}", "pound": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}", "Atilde": "\u{00C3}",
        "Auml": "\u{00C4}", "Aring": "\u{00C5}", "AElig": "\u{00C6}",
        "Ccedil": "\u{00C7}", "Egrave": "\u{00C8}", "Eacute": "\u{00C9}", "Ecirc": "\u{00CA}",
        "Euml": "\u{00CB}", "Igrave": "\u{00CC}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}",
        "Iuml": "\u{00CF}", "Ntilde": "\u{00D1}",
        "Ograve": "\u{00D2}", "Oacute": "\u{00D3}", "Ocirc": "\u{00D4}", "Otilde": "\u{00D5}",
        "Ouml": "\u{00D6}", "Oslash": "\u{00D8}",
        "Ugrave": "\u{00D9}", "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}", "Uuml": "\u{00DC}",
        "Yacute": "\u{00DD}", "szlig": "\u{00DF}",
        "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "auml": "\u{00E4}", "aring": "\u{00E5}", "aelig": "\u{00E6}",
        "ccedil": "\u{00E7}", "egrave": "\u{00E8}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}",
        "euml": "\u{00EB}", "igrave": "\u{00EC}", "iacute": "\u{00ED}", "icirc": "\u{00EE}",
        "iuml": "\u{00EF}", "ntilde": "\u{00F1}",
        "ograve": "\u{00F2}", "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}",
        "ouml": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}",
        "yacute": "\u{00FD}", "yuml": "\u{00FF}",
    ]

    /// The longest reference body this scanner will consider (`#x1F600` and the
    /// longest name both fit well inside it). A bare `&` in prose must not send
    /// the scan hunting for a semicolon through the rest of a 120k-character
    /// article.
    private static let maxHTMLCharacterReferenceBodyLength = 12

    /// Decodes HTML character references — named (`&ldquo;`) and numeric
    /// (`&#8220;`, `&#x201C;`) — into the characters they stand for.
    ///
    /// Exactly one level, in a single left-to-right scan. The pass-per-entity
    /// implementation this replaced substituted `&amp;` before the named table
    /// and then re-read its own output, which got both ends of the problem
    /// wrong: `&amp;ldquo;` — text that means the literal characters `&ldquo;` —
    /// came out as a curly quote, while a doubly escaped `&amp;amp;` was left
    /// holding a visible `&amp;`. A scan cannot re-read what it has written, so
    /// neither is possible. Use `decodingDoubleEscapedHTMLCharacterReferences()`
    /// where the upstream really does escape twice.
    func decodingHTMLCharacterReferences() -> String {
        guard contains("&") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var cursor = startIndex
        while cursor < endIndex {
            guard let ampersand = self[cursor...].firstIndex(of: "&") else {
                result.append(contentsOf: self[cursor...])
                break
            }
            result.append(contentsOf: self[cursor..<ampersand])
            let bodyStart = index(after: ampersand)
            let window = self[bodyStart...].prefix(Self.maxHTMLCharacterReferenceBodyLength)
            if let semicolon = window.firstIndex(of: ";"),
               let decoded = Self.decodedHTMLCharacterReference(self[bodyStart..<semicolon]) {
                result.append(decoded)
                cursor = index(after: semicolon)
            } else {
                // Not a reference — a bare ampersand in prose, or a name this
                // table does not carry. Either way it stays as written.
                result.append("&")
                cursor = bodyStart
            }
        }
        return result
    }

    /// Two decoding levels, for upstreams that escape an already-escaped string.
    /// YouTube's timed-text XML is the app's live example: a literal `&` arrives
    /// as `&amp;amp;` and an apostrophe as `&amp;#39;`.
    func decodingDoubleEscapedHTMLCharacterReferences() -> String {
        decodingHTMLCharacterReferences().decodingHTMLCharacterReferences()
    }

    /// A title as the library keeps and draws it: character references
    /// decoded, then the inline markup a catalog wrote into it folded into
    /// text, so `H<sub>2</sub>O<sub>2</sub>` reads `H₂O₂`, and its soft hyphens
    /// dropped. A title is drawn as text everywhere — rows, the chat's Sources
    /// list, the MCP tools — so it is kept as text. See `foldingInlineMarkup()`
    /// and `removingSoftHyphens()`.
    func decodingTitleMarkup() -> String {
        decodingHTMLCharacterReferences().foldingInlineMarkup().removingSoftHyphens()
    }

    /// The text without U+00AD SOFT HYPHEN.
    ///
    /// A soft hyphen is a hyphenation hint for whatever lays the text out,
    /// never a character a reader sees: a web page writes `&shy;` where a long
    /// word may break, and a publisher's PDF keeps one where its typesetter
    /// could break a word, often right after a real hyphen
    /// ("regeneration-\u{00AD}associated"). Left in the text a source keeps,
    /// it splits the word it sits in — "life\u{00AD}span" is not "lifespan" to
    /// keyword search, embeddings, a chat's quote or Listen — so every path
    /// that derives a source's text drops it, after decoding character
    /// references. Dropping it changes nothing a reader sees. Words are never
    /// joined: a hyphen and any space the layout put after a soft hyphen stay
    /// as they are.
    func removingSoftHyphens() -> String {
        guard unicodeScalars.contains("\u{00AD}") else { return self }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(unicodeScalars.count)
        for scalar in unicodeScalars where scalar != "\u{00AD}" {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func decodedHTMLCharacterReference(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }
        guard body.hasPrefix("#") else {
            return htmlNamedCharacterReferences[String(body)]
        }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(Character(scalar))
    }
}
