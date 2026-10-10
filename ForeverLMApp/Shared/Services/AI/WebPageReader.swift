import Foundation
import PDFKit

/// Reads one web page or online PDF into plain text for the chat's
/// `fetch_web_page` tool.
///
/// A provider's web search returns snippets; research needs the page. This is
/// the route-independent way to read one: it runs in the app, so it works the
/// same whether the model is reached directly, through OpenRouter, or through
/// the managed proxy, and nothing is billed but the tokens the text costs.
/// Extraction is deliberately simple — boilerplate regions dropped, the
/// article or main region preferred, tags stripped — because the reader is a
/// language model that copes with rough text far better than with no text.
enum WebPageReader {
    struct Page: Equatable, Sendable {
        /// The URL the content actually came from, after redirects.
        let url: String
        let title: String
        let text: String
        /// `html`, `pdf`, or `text`, for the result header.
        let kind: String
    }

    enum ReadError: LocalizedError, Equatable {
        case invalidURL
        case unsupportedScheme
        case badStatus(Int)
        case unsupportedContent(String)
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "The URL could not be parsed."
            case .unsupportedScheme: return "Only http and https pages can be read."
            case .badStatus(let code): return "The server answered HTTP \(code)."
            case .unsupportedContent(let type): return "The response is \(type), which cannot be read as text."
            case .tooLarge: return "The response is larger than the reader accepts."
            case .unreadable: return "No readable text was found on the page. It may be rendered by scripts or behind a sign-in or bot check."
            }
        }
    }

    /// Characters of page text one tool call returns. Twelve thousand is
    /// roughly three thousand tokens: enough for an article or a paper's
    /// introduction in one read, small enough that a model reading twenty
    /// pages in a turn does not spend its window on the first three.
    static let windowCharacters = 12_000
    /// Largest response body the reader downloads. Papers run to a few
    /// megabytes; anything past this is a dataset, not a page.
    static let maximumBytes = 25_000_000
    static let requestTimeout: TimeInterval = 25

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()

    // MARK: - Fetching

    static func read(_ rawURL: String) async throws -> Page {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else { throw ReadError.invalidURL }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ReadError.unsupportedScheme
        }
        let request = SourceService.browserRequest(for: url, timeout: requestTimeout)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReadError.unreadable }
        guard (200...299).contains(http.statusCode) else { throw ReadError.badStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        let finalURL = (http.url ?? url).absoluteString
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return try page(from: data, contentType: contentType, url: finalURL)
    }

    // MARK: - Checking that an address opens

    /// What a bounded check of an address found.
    struct Opening: Equatable, Sendable {
        /// The address that answered, after redirects.
        let finalURL: String
        /// The page's own title from its head; nil for a PDF or a head with none.
        let title: String?
    }

    /// Bytes `opens` reads: enough for a page's head, never the page.
    static let openCheckByteLimit = 65_536
    static let openCheckTimeout: TimeInterval = 12

    /// Whether an address opens: a GET that answers 2xx, read for at most
    /// 64 KB and then dropped, so an address a model listed is checked without
    /// downloading what it points at. Nil when it does not answer, answers an
    /// error status, is not an http(s) address, or is a soft 404: a page
    /// that redirects to its site's front page answers 200 for a page that is
    /// not there. A publisher's bot check that answers 403 reads as not
    /// opening; Discover then keeps the page only when the search engine
    /// cited it or Crossref knows its DOI.
    static func opens(_ rawURL: String) async -> Opening? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let request = SourceService.browserRequest(for: url, timeout: openCheckTimeout)
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        let answered = http.url ?? url
        guard !redirectedToFrontPage(requested: url, answered: answered) else { return nil }
        let finalURL = answered.absoluteString
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.isEmpty || contentType.contains("html") else {
            return Opening(finalURL: finalURL, title: nil)
        }
        var data = Data()
        data.reserveCapacity(openCheckByteLimit)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= openCheckByteLimit { break }
            }
        } catch {
            // The status already answered; a head cut short still names the page.
        }
        let title = pageTitle(fromHTML: String(decoding: data, as: UTF8.self))
        return Opening(finalURL: finalURL, title: title.isEmpty ? nil : title)
    }

    /// Whether a request for a page of its own answered from the site's front
    /// page: what a site that has no such page does instead of a 404.
    static func redirectedToFrontPage(requested: URL, answered: URL) -> Bool {
        let isFront: (String) -> Bool = { $0.isEmpty || $0 == "/" }
        return !isFront(requested.path) && isFront(answered.path)
    }

    /// Pure decode step, separated so tests can feed bytes without a server.
    static func page(from data: Data, contentType: String, url: String) throws -> Page {
        if contentType.contains("application/pdf") || data.starts(with: Array("%PDF".utf8)) {
            return try pdfPage(from: data, url: url)
        }
        let isText = contentType.isEmpty
            || contentType.contains("text/")
            || contentType.contains("xml")
            || contentType.contains("json")
            || contentType.contains("javascript")
        guard isText else {
            throw ReadError.unsupportedContent(contentType.split(separator: ";").first.map(String.init) ?? contentType)
        }
        guard let body = decodeText(data, contentType: contentType) else { throw ReadError.unreadable }
        if contentType.contains("text/html") || contentType.contains("xhtml") || looksLikeHTML(body) {
            let extracted = readableText(fromHTML: body)
            guard !extracted.text.isEmpty else { throw ReadError.unreadable }
            return Page(url: url, title: extracted.title, text: extracted.text, kind: "html")
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReadError.unreadable }
        return Page(url: url, title: URL(string: url)?.lastPathComponent ?? url, text: text, kind: "text")
    }

    private static func pdfPage(from data: Data, url: String) throws -> Page {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ReadError.unreadable }
        let text = PDFTextExtractor.textWithFigureReferences(from: document, pages: 0..<document.pageCount)
        guard !text.isEmpty else { throw ReadError.unreadable }
        let attributedTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (attributedTitle?.isEmpty == false ? attributedTitle : nil)
            ?? URL(string: url)?.lastPathComponent
            ?? url
        return Page(url: url, title: title, text: text, kind: "pdf")
    }

    private static func decodeText(_ data: Data, contentType: String) -> String? {
        if let charsetRange = contentType.range(of: "charset=") {
            let charset = contentType[charsetRange.upperBound...]
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'"))) } ?? ""
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(encoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) { return text }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func looksLikeHTML(_ body: String) -> Bool {
        let head = body.prefix(2_000).lowercased()
        return head.contains("<html") || head.contains("<!doctype html") || head.contains("<body")
    }

    // MARK: - HTML → text

    /// The page's title and its readable text. Script, style, navigation,
    /// header, footer, aside and form regions are dropped; when the page marks
    /// an `<article>` or `<main>` region that carries most of the text, only
    /// that region is kept, so a news page reads as its story rather than its
    /// menus and related-links rails.
    static func readableText(fromHTML html: String) -> (title: String, text: String) {
        let title = pageTitle(fromHTML: html)
        var working = removingRegions(
            ["script", "style", "noscript", "svg", "template", "iframe", "nav", "header", "footer", "aside", "form"],
            from: html
        )
        // Headings keep a marker so the structure survives into plain text.
        if let regex = try? NSRegularExpression(pattern: #"<h([1-6])[^>]*>"#, options: .caseInsensitive) {
            working = regex.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..<working.endIndex, in: working),
                withTemplate: "\n\n## "
            )
        }
        let whole = EPUBParser.stripHTML(working)
        for region in ["article", "main"] {
            if let inner = largestRegion(region, in: working) {
                let regionText = EPUBParser.stripHTML(inner)
                // Keep the region only when it is the page: a 300-character
                // <main> wrapping a sign-in form is not the story.
                if regionText.count >= 600, regionText.count * 3 >= whole.count {
                    return (title, collapseBlankLines(regionText))
                }
            }
        }
        return (title, collapseBlankLines(whole))
    }

    static func pageTitle(fromHTML html: String) -> String {
        // og:title, each tag read on its own in either attribute order
        // (`HTMLTagAttributes`) — an apostrophe in "Parkinson's" is part of the
        // value — and then the document's <title>.
        let socialTitles = HTMLTagAttributes.tags(named: "meta", in: html)
            .filter { $0["property"]?.lowercased() == "og:title" }
            .compactMap { $0["content"] }
        var candidates = socialTitles
        if let regex = try? NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
           let range = Range(match.range(at: 1), in: html) {
            candidates.append(String(html[range]))
        }
        for candidate in candidates {
            let title = EPUBParser.stripHTML(candidate)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return ""
    }

    private static func removingRegions(_ tags: [String], from html: String) -> String {
        var text = html
        for tag in tags {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                options: .caseInsensitive
            ) else { continue }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        return text
    }

    private static func largestRegion(_ tag: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)\\s*>",
            options: .caseInsensitive
        ) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        var best: String?
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let inner = String(html[range])
            if inner.count > (best?.count ?? 0) { best = inner }
        }
        return best
    }

    private static func collapseBlankLines(_ text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool result

    /// One window of a page as the tool returns it: a header the model can
    /// cite from, the text from `offset`, and — when more remains — the offset
    /// to pass for the next window. Offsets are character counts into the
    /// extracted text, so a second call continues exactly where the first
    /// stopped.
    static func toolResult(for page: Page, offset requestedOffset: Int) -> String {
        let total = page.text.count
        let offset = max(0, min(requestedOffset, total))
        let start = page.text.index(page.text.startIndex, offsetBy: offset)
        let endOffset = min(total, offset + windowCharacters)
        let end = page.text.index(page.text.startIndex, offsetBy: endOffset)
        var header = "Title: \(page.title.isEmpty ? "(untitled)" : page.title)\nURL: \(page.url)\nContent: \(page.kind), \(total) characters"
        if total > windowCharacters {
            header += ", showing \(offset + 1)–\(endOffset)"
        }
        var body = String(page.text[start..<end])
        if endOffset < total {
            body += "\n\n[Continues. Call fetch_web_page again with the same url and offset \(endOffset) for the next part.]"
        }
        return header + "\n\n" + body
    }
}
