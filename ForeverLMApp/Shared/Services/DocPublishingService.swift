import Foundation
import OSLog

/// A Doc's page on foreverlm.com, as the publishing service reports it.
struct PublishedDocStatus: Equatable, Sendable {
    let docID: String
    let url: URL
    let slug: String
    let title: String
    let publishedAt: Date
    let updatedAt: Date
    /// The page is not open to anyone with the link: it is shared with specific
    /// readers, or guarded by a password set before reader lists existed.
    let isProtected: Bool
    /// The email addresses the page is shared with, normalised as the site
    /// stores them. Empty for an open page and for a password page.
    var readers: [String] = []
    /// The share password of a page protected before reader lists existed,
    /// returned only to the authenticated owner. Nil otherwise.
    let password: String?
    /// The address was chosen by the writer rather than drawn at random.
    var isCustomSlug: Bool = false
}

/// What a publish does to who can read the page. `keep` leaves whatever the
/// page has (open, for a first publish; a password stays a password);
/// `open` lets anyone with the link read it; `readers` shares it with exactly
/// those addresses, replacing a password.
enum DocPageAccess: Equatable, Sendable {
    case keep
    case open
    case readers([String])
}

enum DocPublishingError: LocalizedError, Equatable {
    /// No managed session on this Mac: publishing is an account feature, and
    /// the account is the Sign in with Apple in Settings › API Keys.
    case signedOut
    /// The service refused or failed; `message` is its own wording.
    case server(status: Int, code: String, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .signedOut:
            return "Sign in with Apple in Settings › API Keys to publish a page. Publishing is tied to your ForeverLM account so only you can update or take down the page."
        case .server(_, _, let message):
            return message
        case .malformedResponse:
            return "foreverlm.com answered in a way ForeverLM did not understand. Try again in a moment."
        }
    }
}

/// Publishes a Doc as a public page on foreverlm.com, or takes it down.
///
/// The client sends only the title and the canonical Markdown; the site renders
/// the page itself, so what a reader sees never depends on which client
/// published and no client-supplied HTML is ever served. The account behind the
/// managed AI session owns the page: republishing keeps the address, and only
/// that account can update or unpublish it. Spec: docs/docs-design.md → Publishing.
enum DocPublishing {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let baseURL = URL(string: "https://foreverlm.com")!

    static let minSlugCharacters = 3
    static let maxSlugCharacters = 64
    /// A custom address as the site accepts it: lowercase letters, digits and
    /// single hyphens, starting and ending with a letter or digit. The site
    /// applies the same rule; this one lets a sheet refuse before sending.
    private static let slugPattern = try! NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){2,63}$")

    /// The custom address a writer typed, as the site would store it, or nil
    /// when it cannot be one. Case and surrounding space are forgiven, and a
    /// pasted full address is reduced to its last segment.
    static func normalizeCustomSlug(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: #"^(?:https?://)?(?:www\.)?foreverlm\.com/(?:d|share)/"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
            if text.hasSuffix(".md") { text.removeLast(3) }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (minSlugCharacters...maxSlugCharacters).contains(text.count),
              slugPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              !["preview", "new", "api", "admin", "foreverlm", "index", "d"].contains(text) else { return nil }
        return text
    }

    /// A reader list is for a report shared with a few people, not a mailing list.
    static let maxReaders = 200
    /// One address as the site stores it — trimmed, lower-cased, one `@`,
    /// something either side, a dot in the domain — or nil when the text is
    /// not an address. The site applies the same rule.
    static func normalizeReader(_ input: String) -> String? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, address.count <= 254,
              address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              address.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return address
    }

    /// The addresses in text a writer typed or pasted — separated by commas,
    /// semicolons, spaces or line breaks, in any case, repeated or not — as the
    /// site stores them, or nil when one of them is not an address. Empty text
    /// is an empty list.
    static func normalizeReaders(_ text: String) -> [String]? {
        // A pasted "Name <address>" keeps the address and drops the name.
        let unnamed = text.replacingOccurrences(of: #"[^<>,;\n]*<([^<>\s]+)>"#, with: "$1", options: .regularExpression)
        var readers: [String] = []
        for piece in unnamed.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace || $0.isNewline }) {
            guard let address = normalizeReader(String(piece)) else { return nil }
            if !readers.contains(address) { readers.append(address) }
        }
        return readers
    }

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DocPublishingError.malformedResponse }
        return (data, http)
    }

    private static let pageLogger = Logger(subsystem: "com.foreverlm", category: "DocPage")

    /// The address a preview stands at when the doc has no page of its own.
    static let previewCanonicalURL = "https://foreverlm.com/share/preview"

    /// What the renderer is given, whichever renderer draws — the bundled one
    /// on this Mac or the site's preview route — with the rules the route
    /// applies (`handlePreview` in `publishing/service.ts`) applied here once,
    /// so both draw the same page from the same doc.
    struct PreviewInput: Equatable, Sendable {
        /// Trimmed, inner runs of whitespace collapsed, "Untitled" when empty.
        var title: String
        var markdown: String
        /// The doc's own address when it is published at one the site would
        /// serve, else the preview address, so the page's links say where it
        /// lives.
        var canonicalURL: String
        /// ISO-8601 instants: when the page was published (now, for a draft)
        /// and when this drawing was made.
        var publishedAt: String
        var updatedAt: String
        /// A preview marks every block with its Markdown lines for the host's
        /// Edit mode; a public page carries no marks.
        var sourceMarks = true
        /// The pages other docs have, by doc id: a `foreverlm://doc/<id>`
        /// link whose doc is here is drawn as a link to that page; one whose
        /// doc is not stays prose, as every other private address does. The
        /// site resolves these itself from the owner's pointers when it draws
        /// a page; the bundled renderer is told, from the statuses this Mac
        /// already holds.
        var docLinks: [String: String] = [:]
    }

    static func previewInput(
        title: String,
        markdown: String,
        pageURL: URL?,
        publishedAt: Date?,
        now: Date = Date(),
        docLinks: [String: String] = [:]
    ) -> PreviewInput {
        let collapsedTitle = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let formatter = KnowledgeStore.iso8601Formatter
        return PreviewInput(
            title: collapsedTitle.isEmpty ? "Untitled" : collapsedTitle,
            markdown: markdown,
            canonicalURL: previewCanonicalURL(for: pageURL),
            publishedAt: formatter.string(from: publishedAt ?? now),
            updatedAt: formatter.string(from: now),
            docLinks: docLinks
        )
    }

    /// The page's own address when it is one the site serves —
    /// `https://foreverlm.com/share/<slug>` with a slug the site accepts —
    /// else the preview address.
    static func previewCanonicalURL(for pageURL: URL?) -> String {
        guard let pageURL,
              let match = pageURL.absoluteString.wholeMatch(of: /^https:\/\/foreverlm\.com\/share\/([a-z0-9-]+)$/) else {
            return previewCanonicalURL
        }
        let slug = String(match.1)
        let range = NSRange(slug.startIndex..., in: slug)
        guard slugPattern.firstMatch(in: slug, range: range) != nil else { return previewCanonicalURL }
        return pageURL.absoluteString
    }

    /// The doc drawn as its page, for the Page view: on this Mac, by the
    /// site's renderer bundled into the app (`PublishedPageRenderer`), in a
    /// few milliseconds and without a sign-in; and when that bundle cannot
    /// run, by the site itself over the preview route, as before. The two
    /// draw the same page from the same input.
    static func page(
        title: String,
        markdown: String,
        pageURL: URL? = nil,
        publishedAt: Date? = nil,
        docLinks: [String: String] = [:],
        renderer: PublishedPageRenderer = .shared,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws -> String {
        let input = previewInput(title: title, markdown: markdown, pageURL: pageURL, publishedAt: publishedAt, docLinks: docLinks)
        let started = ContinuousClock.now
        do {
            let html = try await renderer.render(input)
            let elapsed = ContinuousClock.now - started
            pageLogger.info("Page drawn on this Mac in \(elapsed.formatted(.units(allowed: [.milliseconds]))) (\(html.utf8.count) bytes from \(markdown.utf8.count) bytes of Markdown)")
            return html
        } catch {
            pageLogger.error("The bundled page renderer failed (\(error.localizedDescription)); asking foreverlm.com to draw the page")
            return try await preview(
                title: title,
                markdown: markdown,
                pageURL: pageURL,
                publishedAt: publishedAt,
                sessionToken: sessionToken,
                transport: transport
            )
        }
    }

    /// The page for this doc, or nil when it is not published.
    static func status(
        docID: String,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws -> PublishedDocStatus? {
        let (data, response) = try await send(method: "GET", docID: docID, body: nil, sessionToken: sessionToken, transport: transport)
        let payload = try decodeObject(data, response: response)
        guard payload["published"] as? Bool == true else { return nil }
        return try parseStatus(payload, fallbackDocID: docID)
    }

    /// Every page this account owns, keyed by Doc id. The Docs list uses this
    /// one bounded projection instead of issuing a request for every row.
    static func statuses(
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws -> [String: PublishedDocStatus] {
        guard let sessionToken, !sessionToken.isEmpty else { throw DocPublishingError.signedOut }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/publish/docs"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        let payload = try decodeObject(data, response: response)
        guard let rows = payload["published_docs"] as? [[String: Any]] else {
            throw DocPublishingError.malformedResponse
        }
        let statuses = try rows.map { try parseStatus($0) }
        return Dictionary(statuses.map { ($0.docID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Publish the doc, or update its page if it already has one. Returns the
    /// page, whose address is stable across updates unless `slug` asks for a
    /// new one: then the page moves there and its old address forwards.
    static func publish(
        docID: String,
        title: String,
        markdown: String,
        access: DocPageAccess = .keep,
        slug: String? = nil,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws -> PublishedDocStatus {
        var payload: [String: Any] = ["title": title, "markdown": markdown]
        switch access {
        case .keep: break
        case .open: payload["readers"] = [String]()
        case .readers(let readers): payload["readers"] = readers
        }
        if let slug, !slug.isEmpty { payload["slug"] = slug }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await send(method: "PUT", docID: docID, body: body, sessionToken: sessionToken, transport: transport)
        return try parseStatus(try decodeObject(data, response: response), fallbackDocID: docID)
    }

    /// The doc drawn as foreverlm.com would draw it, from the text given, without
    /// publishing anything: the site renders and returns the HTML. The Page view
    /// in the Docs pane shows this, so a doc can be read the way a reader would
    /// see it before it is published, and a published one with its unsaved
    /// edits. `pageURL` is the doc's public address when it has one, so the
    /// page's own links say where it lives.
    static func preview(
        title: String,
        markdown: String,
        pageURL: URL? = nil,
        publishedAt: Date? = nil,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws -> String {
        var payload: [String: Any] = ["title": title, "markdown": markdown]
        if let pageURL { payload["url"] = pageURL.absoluteString }
        if let publishedAt { payload["published_at"] = KnowledgeStore.iso8601Formatter.string(from: publishedAt) }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let sessionToken, !sessionToken.isEmpty else { throw DocPublishingError.signedOut }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/publish/preview"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            _ = try decodeObject(data, response: response)
            throw DocPublishingError.malformedResponse
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { throw DocPublishingError.malformedResponse }
        return html
    }

    /// Take the page down. A doc that was not published is not an error.
    static func unpublish(
        docID: String,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = urlSessionTransport
    ) async throws {
        let (data, response) = try await send(method: "DELETE", docID: docID, body: nil, sessionToken: sessionToken, transport: transport)
        _ = try decodeObject(data, response: response)
    }

    // MARK: - Wire

    static func endpoint(docID: String) -> URL {
        baseURL.appendingPathComponent("api/publish/docs/\(docID)")
    }

    private static func send(
        method: String,
        docID: String,
        body: Data?,
        sessionToken: String?,
        transport: Transport
    ) async throws -> (Data, HTTPURLResponse) {
        guard let sessionToken, !sessionToken.isEmpty else { throw DocPublishingError.signedOut }
        var request = URLRequest(url: endpoint(docID: docID))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await transport(request)
    }

    private static func decodeObject(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            let code = object?["error"] as? String ?? "http_\(response.statusCode)"
            if response.statusCode == 401 { throw DocPublishingError.signedOut }
            let message = object?["error_description"] as? String
                ?? "foreverlm.com answered \(response.statusCode) while publishing."
            throw DocPublishingError.server(status: response.statusCode, code: code, message: message)
        }
        guard let object else { throw DocPublishingError.malformedResponse }
        return object
    }

    private static func parseStatus(_ payload: [String: Any], fallbackDocID: String? = nil) throws -> PublishedDocStatus {
        guard let urlString = payload["url"] as? String, let url = URL(string: urlString),
              let slug = payload["slug"] as? String,
              let publishedAt = date(payload["published_at"]),
              let updatedAt = date(payload["updated_at"]),
              let docID = (payload["doc_id"] as? String) ?? fallbackDocID,
              !docID.isEmpty else {
            throw DocPublishingError.malformedResponse
        }
        return PublishedDocStatus(
            docID: docID,
            url: url,
            slug: slug,
            title: payload["title"] as? String ?? "",
            publishedAt: publishedAt,
            updatedAt: updatedAt,
            isProtected: payload["protected"] as? Bool ?? false,
            readers: payload["readers"] as? [String] ?? [],
            password: payload["password"] as? String,
            isCustomSlug: payload["custom_slug"] as? Bool ?? false
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return KnowledgeStore.iso8601Formatter.date(from: string)
    }
}
