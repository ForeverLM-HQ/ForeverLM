import Foundation

/// A feed as parsed, before anything is stored.
struct ParsedJournalFeed: Equatable, Sendable {
    var title: String
    var siteURL: String?
    var items: [ParsedJournalItem]
}

struct ParsedJournalItem: Equatable, Sendable {
    var url: String
    var title: String
    var summary: String?
    var authors: [String]
    var doi: String?
    var journal: String?
    var publishedAt: Date?
}

/// Reads the three feed dialects sites actually serve — RSS 2.0 (Substack,
/// WordPress, Ghost, Medium, arXiv), RSS 1.0 (RDF, which every Nature
/// Portfolio journal uses) and Atom (Blogger, Reddit, many static blogs) —
/// into one shape, and finds a page's feed: the one it advertises, or the one
/// at a conventional path when it advertises none.
///
/// Everything here is structure: element names, attributes, dates, DOIs.
/// Nothing reads the article text for meaning; that is the matching call's
/// job (`AIService.matchJournalArticles`).
enum JournalFeedParser {
    enum ParseError: LocalizedError, Equatable {
        case notAFeed
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notAFeed: return "The response is not an RSS or Atom feed."
            case .malformed(let detail): return "The feed could not be read: \(detail)"
            }
        }
    }

    static func parse(_ data: Data) throws -> ParsedJournalFeed {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            if !delegate.sawFeedRoot { throw ParseError.notAFeed }
            let detail = parser.parserError?.localizedDescription ?? "unknown XML error"
            // A trailing error after items were read is a truncated download,
            // not a wrong content type; keep what parsed.
            guard !delegate.items.isEmpty else { throw ParseError.malformed(detail) }
            return delegate.result()
        }
        guard delegate.sawFeedRoot else { throw ParseError.notAFeed }
        return delegate.result()
    }

    // MARK: - Feed discovery

    /// The feeds an HTML page advertises through `<link rel="alternate">`,
    /// resolved against the page URL, in document order.
    static func discoverFeedURLs(inHTML html: String, relativeTo pageURL: URL) -> [URL] {
        let head = String(html.prefix(200_000))
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        var found: [URL] = []
        var seen = Set<String>()
        let range = NSRange(head.startIndex..., in: head)
        for match in tagPattern.matches(in: head, options: [], range: range) {
            guard let tagRange = Range(match.range, in: head) else { continue }
            let tag = String(head[tagRange])
            guard let type = attribute("type", in: tag)?.lowercased(),
                  feedContentTypes.contains(where: { type.hasPrefix($0) }),
                  let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains("alternate"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: decodeEntities(href), relativeTo: pageURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                continue
            }
            if seen.insert(url.absoluteString).inserted { found.append(url) }
        }
        return found
    }

    static let feedContentTypes = ["application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/xml", "text/xml"]

    /// Where a site keeps its feed when its pages do not say. The paths
    /// WordPress (`/feed/`), Ghost (`/rss/`), Hugo and Jekyll (`/index.xml`,
    /// `/feed.xml`, `/atom.xml`), Substack (`/feed`) and Reddit (`.rss` after
    /// the path) use — tried relative to the pasted page first, so a section
    /// like `blog.example.com/ai/` finds its own feed before the site's, then
    /// at the site root. The order is the order they are fetched in, so the
    /// common ones come first.
    static func wellKnownFeedURLs(for pageURL: URL) -> [URL] {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true) else { return [] }
        components.query = nil
        components.fragment = nil
        let path = components.path
        let directory = path.hasSuffix("/") ? path : path + "/"
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path

        var bases = [directory]
        if directory != "/" { bases.append("/") }
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ candidatePath: String) {
            components.path = candidatePath
            guard let url = components.url, seen.insert(url.absoluteString).inserted else { return }
            found.append(url)
        }
        for base in bases {
            for suffix in ["feed", "feed/", "rss", "rss/", "feed.xml", "rss.xml", "atom.xml", "index.xml"] {
                add(base + suffix)
            }
            if base == directory, !trimmed.isEmpty, trimmed != "/" {
                add(trimmed + ".rss")
            }
        }
        return found
    }

    // MARK: - Article URLs

    /// Query parameters that name the reader's route to a post rather than the
    /// post — Medium appends `source=rss-…` to every feed link, Substack and
    /// newsletters add `utm_*`. They are dropped so the stored identity is the
    /// address the learner would paste by hand, and the same post in two feeds
    /// is one row. Mirrors `URLNormalizer.trackingParams`, which the library's
    /// own duplicate check applies to the result again.
    static func cleanArticleURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("?"), var components = URLComponents(string: trimmed),
              let items = components.queryItems, !items.isEmpty else { return trimmed }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") { return false }
            return !trackingQueryParameters.contains(name)
        }
        guard kept.count != items.count else { return trimmed }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? trimmed
    }

    private static let trackingQueryParameters: Set<String> = [
        "source", "ref", "fbclid", "gclid", "mc_cid", "mc_eid", "mkt_tok", "igshid",
    ]

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range) else { return nil }
        for group in 1...3 {
            let groupRange = match.range(at: group)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: tag) {
                return String(tag[swiftRange])
            }
        }
        return nil
    }

    // MARK: - Text

    /// Tags dropped, entities decoded, whitespace collapsed. Feed summaries are
    /// HTML fragments; the matching model reads the words.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        if let tags = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = tags.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        text = decodeEntities(text)
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"),
            ("&mdash;", "—"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&rdquo;", "”"), ("&ldquo;", "“"),
        ]
        for (entity, replacement) in named where result.contains(entity) {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let numeric = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);", options: []) {
            let matches = numeric.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let codeRange = Range(match.range(at: 1), in: result) else { continue }
                var code = String(result[codeRange])
                let isHex = code.hasPrefix("x") || code.hasPrefix("X")
                if isHex { code.removeFirst() }
                guard let value = UInt32(code, radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(value) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }

    // MARK: - Dates

    /// Feed dates arrive as RFC 822 (`pubDate`), ISO 8601 with or without a
    /// time (`dc:date`, Atom `published`), or a bare `YYYY-MM-DD`.
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = iso8601WithFractions.date(from: text) ?? iso8601.date(from: text) {
            return date
        }
        for formatter in [rfc822, rfc822NoSeconds, dateOnly] {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static let rfc822 = posixFormatter("EEE, dd MMM yyyy HH:mm:ss Z")
    private static let rfc822NoSeconds = posixFormatter("EEE, dd MMM yyyy HH:mm Z")
    private static let dateOnly = posixFormatter("yyyy-MM-dd")

    // MARK: - DOI

    /// `prism:doi` carries a bare DOI; `dc:identifier` a `doi:` URI; either
    /// may be missing, in which case the article URL itself often names it.
    static func normalizedDOI(_ raw: String?) -> String? {
        guard var doi = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty else { return nil }
        let lowered = doi.lowercased()
        for prefix in ["doi:", "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/"] where lowered.hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
            break
        }
        doi = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard doi.hasPrefix("10."), doi.contains("/") else { return nil }
        return doi
    }
}

// MARK: - XML delegate

private final class FeedDelegate: NSObject, XMLParserDelegate {
    private(set) var sawFeedRoot = false
    private var feedTitle = ""
    private var feedSiteURL: String?
    private(set) var items: [ParsedJournalItem] = []

    private var path: [String] = []
    private var text = ""
    private var insideItem = false
    private var insideAuthor = false

    private var itemURL = ""
    private var itemAbout: String?
    private var itemAtomLink: String?
    private var itemTitle = ""
    private var itemDCTitle = ""
    private var itemDescription = ""
    private var itemEncoded = ""
    private var itemSummary = ""
    private var itemContent = ""
    private var itemAuthors: [String] = []
    private var itemDOI: String?
    private var itemIdentifier: String?
    private var itemJournal: String?
    private var itemDateCandidates: [String] = []

    func result() -> ParsedJournalFeed {
        ParsedJournalFeed(
            title: JournalFeedParser.plainText(fromHTML: feedTitle),
            siteURL: feedSiteURL.map(JournalFeedParser.cleanArticleURL),
            items: items
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if path.isEmpty {
            sawFeedRoot = ["rss", "rdf:rdf", "feed"].contains(name)
        }
        path.append(name)
        text = ""

        if name == "item" || name == "entry" {
            insideItem = true
            resetItem()
            itemAbout = attributeDict["rdf:about"]
            return
        }
        guard insideItem else {
            if name == "link", path.count >= 2, path[path.count - 2] == "feed",
               let href = attributeDict["href"], !href.isEmpty {
                let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
                if rel == "alternate", feedSiteURL == nil { feedSiteURL = href }
            }
            return
        }
        switch name {
        case "link":
            if let href = attributeDict["href"], !href.isEmpty {
                let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
                if rel == "alternate" || itemAtomLink == nil { itemAtomLink = href }
            }
        case "author":
            insideAuthor = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }

        if name == "item" || name == "entry" {
            finishItem()
            insideItem = false
            return
        }

        guard insideItem else {
            // Channel-level fields. `title` and `link` under rss/channel,
            // rdf:RDF/channel, or feed. An RDF channel's <link> is the feed
            // itself; the site is only known when RSS 2.0 names it.
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            if name == "title", parent == "channel" || parent == "feed", feedTitle.isEmpty {
                feedTitle = value
            } else if name == "link", parent == "channel", feedSiteURL == nil, !value.isEmpty {
                feedSiteURL = value
            }
            return
        }

        switch name {
        case "title":
            if insideAuthor { break }
            itemTitle = value
        case "dc:title":
            itemDCTitle = value
        case "link":
            if !value.isEmpty { itemURL = value }
        case "guid":
            // A permalink guid stands in when there is no <link>.
            if itemURL.isEmpty, value.hasPrefix("http") { itemURL = value }
        case "description":
            itemDescription = value
        case "content:encoded":
            itemEncoded = value
        case "summary":
            itemSummary = value
        case "content":
            itemContent = value
        case "dc:creator":
            if !value.isEmpty { itemAuthors.append(value) }
        case "name":
            if insideAuthor, !value.isEmpty { itemAuthors.append(value) }
        case "author":
            insideAuthor = false
            // RSS 2.0's <author> is an email with a name in parentheses; only
            // take it when nothing better was given.
            if !value.isEmpty, itemAuthors.isEmpty, !value.contains("@") { itemAuthors.append(value) }
        case "prism:doi":
            itemDOI = value
        case "dc:identifier":
            itemIdentifier = value
        case "prism:publicationname":
            itemJournal = value
        case "dc:date", "pubdate", "published", "updated", "prism:publicationdate", "dc:date.issued":
            if !value.isEmpty { itemDateCandidates.append(value) }
        default:
            break
        }
    }

    private func resetItem() {
        itemURL = ""
        itemAbout = nil
        itemAtomLink = nil
        itemTitle = ""
        itemDCTitle = ""
        itemDescription = ""
        itemEncoded = ""
        itemSummary = ""
        itemContent = ""
        itemAuthors = []
        itemDOI = nil
        itemIdentifier = nil
        itemJournal = nil
        itemDateCandidates = []
        insideAuthor = false
    }

    private func finishItem() {
        let url = [itemURL, itemAtomLink ?? "", itemAbout ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("http") }
            .map(JournalFeedParser.cleanArticleURL) ?? ""
        guard !url.isEmpty else { return }
        let rawTitle = itemTitle.isEmpty ? itemDCTitle : itemTitle
        // A journal's item title carries the paper's own markup; folded first, its
        // `H<sub>2</sub>O<sub>2</sub>` reads "H₂O₂" rather than the "H 2 O 2" that
        // dropping every tag leaves.
        let title = JournalFeedParser.plainText(fromHTML: rawTitle.foldingInlineMarkup())
        guard !title.isEmpty else { return }

        let summarySource = [itemDescription, itemEncoded, itemSummary, itemContent].first { !$0.isEmpty }
        let summary = summarySource.map(JournalFeedParser.plainText(fromHTML:)).flatMap { $0.isEmpty ? nil : $0 }
        let doi = JournalFeedParser.normalizedDOI(itemDOI)
            ?? JournalFeedParser.normalizedDOI(itemIdentifier)
            ?? PaperService.extractDOI(from: url).flatMap(JournalFeedParser.normalizedDOI)
        // Prefer the publication date; `updated` is the last alternative.
        let published = itemDateCandidates.compactMap(JournalFeedParser.parseDate).first

        items.append(ParsedJournalItem(
            url: url,
            title: title,
            summary: summary.map { String($0.prefix(2_000)) },
            authors: itemAuthors.map { JournalFeedParser.plainText(fromHTML: $0) }.filter { !$0.isEmpty },
            doi: doi,
            journal: itemJournal.map(JournalFeedParser.plainText(fromHTML:)).flatMap { $0.isEmpty ? nil : $0 },
            publishedAt: published
        ))
    }
}
