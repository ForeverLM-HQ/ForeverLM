import Foundation

/// The sources an article links to, read for "Find Linked Sources".
///
/// Two steps, with a hard line between them. Finding the links is deterministic: every
/// `<a href>` in the article's archived reader document is read, resolved to an absolute
/// web address, deduplicated on its normalized form, and numbered into the article's text
/// as a marker (`[L3]`). Judging them is the model's: it reads the prose around each marker
/// and says which links the article uses as sources and what it says about each. A pick
/// names a marker; code maps the marker back to the URL. The model never sees, chooses or
/// rewrites an address, so a slow, failed or differently-worded call can only change which
/// links are offered and how they are described, never what a candidate row points at.
///
/// The kind of source a link is — paper, article, video, podcast, post — is read off the
/// URL by `StudioViewModel.detectSourceType`, the same rule the composer applies when a
/// link is pasted, so a candidate imports through the pipeline its URL would have taken
/// anyway.
enum ArticleLinkDiscoveryService {

    /// One hyperlink found in the article.
    struct Link: Equatable, Sendable {
        /// The marker number written into the text, starting at 1.
        let index: Int
        /// The absolute address, exactly as the page carried it (tracking parameters and
        /// all), so the import dedups it the way a pasted link would be.
        let url: String
        /// The words that carried the link, tags stripped; empty for an anchor around an
        /// image or an icon.
        let text: String
    }

    /// The article prepared for the model: its text with markers, and the links by number.
    struct Reading: Equatable, Sendable {
        let markedText: String
        let links: [Link]

        /// The `LINKS:` block the model reads after the text.
        var linkIndex: String {
            links.map { link in
                let words = link.text.isEmpty ? "(no link text)" : "\"\(link.text)\""
                return "[L\(link.index)] \(link.url) — \(words)"
            }.joined(separator: "\n")
        }
    }

    /// One link the model judged to be a source.
    struct Pick: Decodable, Equatable, Sendable {
        let link: Int
        let title: String?
        let why: String?
    }

    enum DiscoveryError: LocalizedError {
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .malformedResponse:
                return "The model's reply was not the expected list of links."
            }
        }
    }

    // MARK: - Finding the links

    /// Reads the article's links and numbers them into its text.
    ///
    /// `html` is the archived reader document (or the fetched page's readable slice); its
    /// links were absolutized at archive time, and any relative one left is resolved against
    /// `pageURL`. Dropped before the model sees them: fragments within the page, `mailto:`
    /// and `javascript:` pseudo-links, links to the article's own address, and links to
    /// image files (an anchor around a figure points at the figure). The same address linked
    /// twice — a name in the opening and again in the close — is one link with one marker,
    /// so the model cannot pick it twice and a rescan cannot add a second row for it.
    nonisolated static func read(html: String, pageURL: URL?) -> Reading {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return Reading(markedText: SourceService.readableTextFromHTML(html), links: [])
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        let selfKey = pageURL.map { URLNormalizer.normalize($0.absoluteString) }

        // Each kept anchor, in document order, with the normalized address it points at.
        // Placeholders carry the anchor's ordinal (never the address) through the tag
        // stripping, since an address can hold characters the text pass would rewrite.
        var kept: [(ordinal: Int, key: String, link: Link)] = []
        var rewritten = html as NSString

        // Walk backwards so earlier ranges stay valid as later anchors are rewritten.
        for (position, match) in matches.enumerated().reversed() where match.numberOfRanges >= 4 {
            let hrefRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let innerRange = match.range(at: 3)
            guard hrefRange.location != NSNotFound, innerRange.location != NSNotFound else { continue }
            let inner = nsHTML.substring(with: innerRange)

            guard let absolute = absoluteWebAddress(nsHTML.substring(with: hrefRange), relativeTo: pageURL) else {
                rewritten = rewritten.replacingCharacters(in: match.range, with: inner) as NSString
                continue
            }
            let key = URLNormalizer.normalize(absolute)
            if key == selfKey || isImageAddress(absolute) {
                rewritten = rewritten.replacingCharacters(in: match.range, with: inner) as NSString
                continue
            }

            let text = SourceService.readableTextFromHTML(inner)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            kept.append((position, key, Link(index: 0, url: absolute, text: text)))
            rewritten = rewritten.replacingCharacters(
                in: match.range,
                with: "\(inner) \u{E000}\(position)\u{E001}"
            ) as NSString
        }

        // Document order: the walk above was reversed. The first appearance of an address
        // owns the marker; later appearances of the same address reuse it.
        var numbered: [Link] = []
        var indexByKey: [String: Int] = [:]
        var indexByOrdinal: [Int: Int] = [:]
        for entry in kept.reversed() {
            if let index = indexByKey[entry.key] {
                indexByOrdinal[entry.ordinal] = index
            } else {
                let index = numbered.count + 1
                indexByKey[entry.key] = index
                indexByOrdinal[entry.ordinal] = index
                numbered.append(Link(index: index, url: entry.link.url, text: entry.link.text))
            }
        }

        var text = SourceService.readableTextFromHTML(rewritten as String)
        // The private-use placeholders survive tag stripping; swap each for its marker.
        for (ordinal, index) in indexByOrdinal {
            text = text.replacingOccurrences(of: "\u{E000}\(ordinal)\u{E001}", with: "[L\(index)]")
        }
        return Reading(markedText: text, links: numbered)
    }

    /// The absolute `http(s)` address a link points at, or nil for anything that is not a
    /// web page: fragments, `mailto:`, `javascript:`, `tel:`, data URIs, empty hrefs.
    nonisolated static func absoluteWebAddress(_ rawHref: String, relativeTo pageURL: URL?) -> String? {
        let href = rawHref
            .decodingHTMLCharacterReferences()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("#") else { return nil }
        let resolved: URL?
        if let direct = URL(string: href), direct.scheme != nil {
            resolved = direct
        } else if let pageURL {
            resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL
        } else {
            resolved = nil
        }
        guard let url = resolved,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        // A fragment names a place on a page, not a page; drop it so two links into one
        // page are one link.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    /// Whether an address is an image file rather than a page. Decided from the path's
    /// extension and the image CDNs newsletter platforms wrap their figures in.
    nonisolated static func isImageAddress(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tiff"].contains(ext) {
            return true
        }
        let host = url.host?.lowercased() ?? ""
        return host == "substackcdn.com" && url.path.hasPrefix("/image/")
    }

    // MARK: - Reading the model's answer

    /// Parses the model's picks. An empty list is a real answer — the article uses none of
    /// its links as a source. A reply that is not the object at all is a failure and says
    /// so, rather than being quietly read as "none".
    nonisolated static func decodeReply(_ reply: String) throws -> [Pick] {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReplyPayload.self, from: data) else {
            throw DiscoveryError.malformedResponse
        }
        return payload.sources ?? []
    }

    private struct ReplyPayload: Decodable {
        let sources: [Pick]?
    }

    // MARK: - Candidates

    /// The candidate rows the picks stand for, one per distinct marker, in the order the
    /// links appear in the article. A pick naming a marker the reading does not have is
    /// dropped: there is no address for it, and inventing one is exactly what this layer
    /// exists to prevent.
    nonisolated static func candidates(
        from picks: [Pick],
        reading: Reading,
        sourceID: String,
        now: Date = Date()
    ) -> [VideoCitedPaper] {
        let linksByIndex = Dictionary(reading.links.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        var candidates: [VideoCitedPaper] = []
        for pick in picks.sorted(by: { $0.link < $1.link }) {
            guard !seen.contains(pick.link), let link = linksByIndex[pick.link] else { continue }
            seen.insert(pick.link)
            candidates.append(candidate(for: link, pick: pick, sourceID: sourceID, now: now))
        }
        return candidates
    }

    /// One candidate for one link. The title is the model's when it gave one, else the
    /// link's own words, else the site — never the bare address. A paper's DOI is read off
    /// the address deterministically, so the import dedups it against a paper saved under
    /// another address of the same DOI.
    nonisolated static func candidate(for link: Link, pick: Pick?, sourceID: String, now: Date) -> VideoCitedPaper {
        let kind = VideoCitedPaper.Kind(sourceType: StudioViewModel.detectSourceType(url: link.url))
        let modelTitle = pick?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: String
        if !modelTitle.isEmpty, !looksLikeAddress(modelTitle) {
            title = modelTitle
        } else if !link.text.isEmpty, !looksLikeAddress(link.text) {
            title = link.text
        } else {
            title = URLComponents(string: link.url)?.host.map { host in
                host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            } ?? link.url
        }
        let why = pick?.why?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoCitedPaper(
            sourceID: sourceID,
            title: title,
            doi: kind == .paper ? PaperService.extractDOI(from: link.url) : nil,
            url: link.url,
            status: .pending,
            kind: kind,
            context: (why?.isEmpty == false) ? why : nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private nonisolated static func looksLikeAddress(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
    }

    // MARK: - Chunking

    /// The marked text in pieces the model can read, each with the whole link index. The
    /// index is repeated because a marker in the second chunk needs its address to be
    /// judged. Overlap keeps a sentence that straddles the cut readable in one of the two.
    nonisolated static func chunks(of reading: Reading, maxCharacters: Int = 48_000) -> [String] {
        SlideCitationService.materialChunks(reading.markedText, maxCharacters: maxCharacters, overlapCharacters: 1_500)
    }
}
