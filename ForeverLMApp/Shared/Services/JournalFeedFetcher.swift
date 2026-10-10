import Foundation

/// Fetches a journal feed, and turns what a learner pasted into a feed URL.
///
/// Requests look like a browser's (`SourceService.browserRequest`) because
/// publishers tell one from a script — nature.com in particular answers a
/// bare client with a challenge page. Conditional headers make the twice-daily
/// check free when nothing was published: the publisher answers 304 and no
/// body travels.
enum JournalFeedFetcher {
    enum FetchError: LocalizedError, Equatable {
        case invalidURL
        case badStatus(Int)
        case tooLarge
        case noFeedFound
        case notAFeed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "That is not a web address."
            case .badStatus(let code): return "The publisher answered HTTP \(code)."
            case .tooLarge: return "The feed is larger than ForeverLM reads."
            case .noFeedFound: return "No feed was found at that address. Paste the site's RSS link instead."
            case .notAFeed: return "The address does not serve an RSS or Atom feed."
            }
        }
    }

    enum FetchResult: Equatable, Sendable {
        /// The publisher's validators matched; nothing changed since last time.
        case notModified
        case feed(ParsedJournalFeed, etag: String?, lastModified: String?)
    }

    struct Resolved: Equatable, Sendable {
        let feedURL: URL
        let feed: ParsedJournalFeed
        let etag: String?
        let lastModified: String?
    }

    static let maximumBytes = 10_000_000
    static let requestTimeout: TimeInterval = 30

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 90
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Checking a followed feed

    static func fetch(feedURL: String, etag: String?, lastModified: String?) async throws -> FetchResult {
        guard let url = URL(string: feedURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw FetchError.invalidURL
        }
        var request = feedRequest(for: url)
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified, !lastModified.isEmpty { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notAFeed }
        if http.statusCode == 304 { return .notModified }
        guard (200...299).contains(http.statusCode) else { throw FetchError.badStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw FetchError.tooLarge }
        let feed: ParsedJournalFeed
        do {
            feed = try JournalFeedParser.parse(data)
        } catch JournalFeedParser.ParseError.notAFeed {
            throw FetchError.notAFeed
        }
        return .feed(
            feed,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    // MARK: - Adding a feed

    /// A pasted address is either the feed itself, a page that advertises one,
    /// or a page whose platform keeps the feed at a conventional path. The page
    /// route is what makes "paste the home page" work: nature.com/nrm links its
    /// `nrm.rss` in the head, a Substack links `/feed`, as most sites do; the
    /// conventional-path route covers the blogs that do not.
    static func resolve(userInput: String) async throws -> Resolved {
        var trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        guard let url = URL(string: trimmed), url.host != nil else { throw FetchError.invalidURL }

        let (data, response) = try await session.data(for: feedRequest(for: url))
        guard let http = response as? HTTPURLResponse else { throw FetchError.notAFeed }
        guard (200...299).contains(http.statusCode) else { throw FetchError.badStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw FetchError.tooLarge }
        let finalURL = http.url ?? url

        if let feed = try? JournalFeedParser.parse(data) {
            return Resolved(
                feedURL: finalURL,
                feed: feed,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
        }

        let html = String(decoding: data, as: UTF8.self)
        let advertised = JournalFeedParser.discoverFeedURLs(inHTML: html, relativeTo: finalURL)
        var lastError: Error = FetchError.noFeedFound
        for candidate in advertised.prefix(3) {
            do {
                if let resolved = try await resolveCandidate(candidate) { return resolved }
            } catch {
                lastError = error
            }
        }

        // No advertised feed, or none that parsed: a blog that forgot the
        // <link> still keeps its feed where its platform puts it. A miss is a
        // quick 404, so the probes are cheap; a slow host is bounded by the
        // per-request timeout times the handful tried.
        let wellKnown = JournalFeedParser.wellKnownFeedURLs(for: finalURL)
            .filter { probe in !advertised.contains(probe) }
        for candidate in wellKnown.prefix(maximumWellKnownProbes) {
            if let resolved = try? await resolveCandidate(candidate) { return resolved }
        }
        throw advertised.isEmpty ? FetchError.noFeedFound : lastError
    }

    /// How many conventional feed paths are tried for a page that advertises
    /// none, before giving up on the address.
    static let maximumWellKnownProbes = 12

    private static func resolveCandidate(_ candidate: URL) async throws -> Resolved? {
        let result = try await fetch(feedURL: candidate.absoluteString, etag: nil, lastModified: nil)
        guard case .feed(let feed, let etag, let lastModified) = result else { return nil }
        // A probe that answers with an empty, titleless document is a soft
        // 404 dressed as XML, not the site's feed.
        guard !feed.items.isEmpty || !feed.title.isEmpty else { return nil }
        return Resolved(feedURL: candidate, feed: feed, etag: etag, lastModified: lastModified)
    }

    private static func feedRequest(for url: URL) -> URLRequest {
        var request = SourceService.browserRequest(for: url, timeout: requestTimeout)
        request.setValue(
            "application/rss+xml, application/atom+xml, application/rdf+xml, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        return request
    }
}
