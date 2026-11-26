import Foundation
import PDFKit
import CryptoKit
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "SourceService")

/// Fetches and caches source content for source context.
/// Supports web URLs and local file paths (macOS only for local files).
actor SourceService {
    
    static let shared = SourceService()

    /// Archived pages are plain reader documents, so their colors belong to the
    /// app rather than the publisher. The descendant rule is intentionally
    /// `!important`: archived markup can retain inline text colors, and a black
    /// inline color otherwise becomes unreadable when WebKit supplies a dark
    /// canvas. Links keep their affordance and captions stay secondary.
    nonisolated static let archivedArticleColorCSS = """
    :root { color-scheme: light dark; }
    body {
      color: #1d1d1f;
      background-color: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      body {
        color: #f2f2f7 !important;
        background-color: #1c1c1e !important;
      }
      body :is(p, h1, h2, h3, h4, h5, h6, li, blockquote, figcaption,
               td, th, pre, code, em, strong, b, i, sub, sup) {
        color: inherit !important;
      }
      body blockquote,
      body figcaption {
        color: #b8b8bd !important;
      }
      body a {
        color: #6cb6ff !important;
      }
    }
    """
    
    private var cache: [String: String] = [:]
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        // A redirect to this Mac or its network is not followed (`OutboundAddressPolicy`).
        self.session = URLSession(configuration: config, delegate: OutboundAddressPolicy.redirectGuard, delegateQueue: nil)
    }
    
    // MARK: - Public API
    
    /// Fetch content from a URL string (web or local path).
    func fetchContent(from urlString: String) async throws -> String {
        // Check cache
        if let cached = cache[urlString] {
            return cached
        }
        
        let content: String
        
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            content = try await fetchWebContent(urlString)
        } else {
            content = try fetchLocalContent(urlString)
        }
        
        // Cache result
        cache[urlString] = content
        return content
    }
    
    // MARK: - Web Content
    
    private func fetchWebContent(_ urlString: String) async throws -> String {
        guard let givenURL = URL(string: urlString) else {
            throw SourceError.invalidURL
        }
        try await OutboundAddressPolicy.check(givenURL)
        let url = await SubstackAppLink.readingAddress(for: givenURL)

        if let resource = Self.googleDocsResource(from: url) {
            return try await fetchGoogleDocsText(resource: resource)
        }

        // X posts are published as JSON, not as a page — see the capture branch
        // in `fetchAndArchiveWebContent`.
        if XPostThreadService.postID(from: urlString) != nil {
            return try await XPostThreadService.shared.capture(postURL: urlString).plainText
        }

        var request = URLRequest(url: url)
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        forHTTPHeaderField: "Accept")
        
        // Try plain HTTP first (fast, works for most sites)
        var needsWebView = false
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SourceError.fetchFailed
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 403 {
                    needsWebView = true
                    throw SourceError.accessDenied
                }
                throw SourceError.httpError(httpResponse.statusCode)
            }
            
            guard let html = String(data: data, encoding: .utf8) else {
                throw SourceError.decodingFailed
            }
            
            let text = extractTextFromHTML(html)
            
            // If extracted text is very short, the page likely requires JS rendering
            let wordCount = text.split(separator: " ").count
            if wordCount >= Self.scriptRenderedPageWordThreshold {
                return text
            }
            needsWebView = true
        } catch {
            if !needsWebView {
                throw error
            }
        }
        
        // Fallback: use WKWebView to render JS-heavy / bot-protected pages (macOS only)
        #if os(macOS)
        let rendered = try await WebViewContentExtractor.shared.extractContent(from: url)
        if SubstackAppLink.isReaderShell(rendered) { throw SourceError.insufficientContent }
        return rendered
        #else
        throw SourceError.accessDenied
        #endif
    }

    /// A Google Docs-family file ForeverLM can pull plain text out of.
    struct GoogleDocsResource: Sendable, Equatable {
        enum Kind: String, Sendable, Equatable {
            case document, spreadsheet, presentation

            init?(pathSegment: String) {
                switch pathSegment {
                case "document": self = .document
                case "spreadsheets": self = .spreadsheet
                case "presentation": self = .presentation
                default: return nil
                }
            }

            var label: String {
                switch self {
                case .document: return "Google Doc"
                case .spreadsheet: return "Google Sheet"
                case .presentation: return "Google Slides deck"
                }
            }
        }

        let kind: Kind
        let id: String
        /// Spreadsheets only: the tab the link points at. Google's CSV export is
        /// one sheet at a time, so a link to a specific tab has to carry it.
        let gid: String?
    }

    nonisolated static func googleDocumentID(from url: URL) -> String? {
        guard let resource = googleDocsResource(from: url), resource.kind == .document else {
            return nil
        }
        return resource.id
    }

    nonisolated static func googleDocsResource(from url: URL) -> GoogleDocsResource? {
        guard url.host?.lowercased() == "docs.google.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3,
              let kind = components.first.flatMap(GoogleDocsResource.Kind.init(pathSegment:)),
              let markerIndex = components.firstIndex(of: "d"),
              components.indices.contains(markerIndex + 1) else { return nil }
        let id = components[markerIndex + 1]
        // `/d/e/<token>/pub` is a published snapshot, not an exportable file id.
        guard id != "e", !id.isEmpty else { return nil }
        return GoogleDocsResource(
            kind: kind,
            id: id,
            gid: kind == .spreadsheet ? googleSheetGID(from: url) : nil
        )
    }

    /// Sheets links carry the tab as `#gid=0`, and share links occasionally as a
    /// `?gid=` query item.
    nonisolated private static func googleSheetGID(from url: URL) -> String? {
        let fragmentGID = url.fragment?
            .split(separator: "&")
            .compactMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0] == "gid" else { return nil }
                return String(parts[1])
            }
            .first
        let queryGID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "gid" }?
            .value
        let gid = fragmentGID ?? queryGID
        guard let gid, !gid.isEmpty, gid.allSatisfy(\.isNumber) else { return nil }
        return gid
    }

    nonisolated static func isGoogleDocsInterfaceContent(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let javascriptPlaceholder = normalized.contains("javascript isn't enabled in your browser")
            || normalized.contains("javascript is not enabled in your browser")
        let editorName = ["google docs", "google sheets", "google slides"].contains { normalized.contains($0) }
        let docsChrome = editorName
            && (normalized.contains("enable and reload") || normalized.contains("browser version is no longer supported"))
        return javascriptPlaceholder || docsChrome
    }

    /// Google's own export endpoints for a Docs-family file. Docs and Slides
    /// hand back plain text; Sheets only exports CSV, one tab per request.
    nonisolated static func googleDocsExportURL(for resource: GoogleDocsResource) -> URL {
        switch resource.kind {
        case .document:
            var components = URLComponents(string: "https://docs.google.com/document/d/\(resource.id)/export")!
            components.queryItems = [URLQueryItem(name: "format", value: "txt")]
            return components.url!
        case .spreadsheet:
            var components = URLComponents(string: "https://docs.google.com/spreadsheets/d/\(resource.id)/export")!
            components.queryItems = [URLQueryItem(name: "format", value: "csv")]
                + (resource.gid.map { [URLQueryItem(name: "gid", value: $0)] } ?? [])
            return components.url!
        case .presentation:
            return URL(string: "https://docs.google.com/presentation/d/\(resource.id)/export/txt")!
        }
    }

    private func fetchGoogleDocsText(resource: GoogleDocsResource) async throws -> String {
        var request = URLRequest(url: Self.googleDocsExportURL(for: resource))
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/plain,text/csv,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            return try await fetchGoogleDocsText(using: request, kind: resource.kind)
        } catch {
            logger.info("The public Google Docs export did not answer: \(error.localizedDescription, privacy: .public)")
        }

        // Link-accessible files export as text above; private ones cannot be
        // fetched — ForeverLM holds no Google Drive credentials.
        throw SourceError.googleDocsUnavailable(resource.kind)
    }

    /// The plain-text export of one Google Doc, for a doc linked into the Docs
    /// pane. The same endpoint and the same validation the source importer
    /// uses, so a linked doc and an imported one read identically.
    ///
    /// `cookies` are the browser session's Google cookies, when the caller has
    /// them: a doc shared only with the signed-in account exports with them and
    /// answers a sign-in page without. The export session is cookie-less on its
    /// own, so the header is attached to this one request and nothing else.
    func googleDocumentPlainText(
        documentID: String,
        cookies: [HTTPCookie] = []
    ) async throws -> String {
        let resource = GoogleDocsResource(kind: .document, id: documentID, gid: nil)
        var request = URLRequest(url: Self.googleDocsExportURL(for: resource))
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            // A cookie the export session stored on an earlier request would
            // shadow the browser's; the browser's is the one that is signed in.
            request.httpShouldHandleCookies = false
        }
        return try await fetchGoogleDocsText(using: request, kind: .document)
    }

    private func fetchGoogleDocsText(
        using request: URLRequest,
        kind: GoogleDocsResource.Kind
    ) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !(http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html"),
              let text = String(data: data, encoding: .utf8) else {
            throw SourceError.googleDocsUnavailable(kind)
        }
        let readable = kind == .spreadsheet ? Self.readableTextFromCSV(text) : text
        return try validatedGoogleDocumentText(readable, kind: kind)
    }

    /// Turns a CSV export into rows a reader (and the model) can follow, keeping
    /// the column structure without the quoting noise. Trailing empty columns are
    /// dropped so a sheet padded out to column Z doesn't read as a wall of pipes.
    nonisolated static func readableTextFromCSV(_ csv: String) -> String {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = csv.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field.trimmingCharacters(in: .whitespaces))
            field = ""
        }

        func endRow() {
            endField()
            while let last = row.last, last.isEmpty { row.removeLast() }
            if !row.isEmpty { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else if character.isNewline {
                    // A wrapped cell is still one cell; keep one row per line.
                    field.append(" ")
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"": inQuotes = true
            case ",": endField()
            // Swift reads CRLF as one Character, so match the whole class
            // rather than the individual line-break scalars.
            case let character where character.isNewline: endRow()
            default: field.append(character)
            }
        }
        endRow()

        return rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
    }

    private func validatedGoogleDocumentText(
        _ text: String,
        kind: GoogleDocsResource.Kind
    ) throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = cleaned.lowercased()
        guard !cleaned.isEmpty,
              !normalized.hasPrefix("<!doctype html"),
              !normalized.hasPrefix("<html"),
              !Self.isGoogleDocsInterfaceContent(cleaned) else {
            throw SourceError.googleDocsUnavailable(kind)
        }
        return cleaned
    }
    
    // MARK: - Archive.ph Fetch

    /// Fetch article content from archive.ph, bypassing paywalls.
    /// Tries `archive.ph/newest/{url}` which redirects to the most recent snapshot.
    func fetchArchiveContent(for urlString: String) async throws -> String {
        let archiveURL = "https://archive.ph/newest/\(urlString)"
        guard let url = URL(string: archiveURL) else {
            throw SourceError.fetchFailed
        }

        var request = URLRequest(url: url)
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SourceError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SourceError.decodingFailed
        }

        let text = extractTextFromHTML(html)
        let wordCount = text.split(separator: " ").count
        guard wordCount >= 200 else {
            throw SourceError.noArchiveSnapshot
        }

        cache[urlString] = text
        return text
    }

    // MARK: - Local Content
    
    /// Resolve a local file URL for a path that may include iCloud or macOS absolute paths.
    /// Where this stored path's file actually lives, as a URL.
    ///
    /// Delegates to `StorageService.locateSourceFile`, the app's single list of
    /// relocation rules, so this and `StudioArticle.resolvedLocalPath` can never
    /// again disagree about whether a source's file exists.
    static func resolveLocalFileURL(_ path: String) -> URL? {
        StorageService.locateSourceFile(path).map { URL(fileURLWithPath: $0) }
    }

    private func fetchLocalContent(_ path: String) throws -> String {
        guard let resolvedURL = Self.resolveLocalFileURL(path) else {
            throw SourceError.fileNotFound
        }
        let expandedPath = resolvedURL.path

        // A file on disk, or a chapter of an EPUB book kept as one file.
        guard EPUBBookFiles.exists(atPath: expandedPath) else {
            throw SourceError.fileNotFound
        }

        // Handle PDF files
        if expandedPath.lowercased().hasSuffix(".pdf") {
            return try extractTextFromPDF(at: expandedPath)
        }

        // Handle TTML transcript files (Apple Podcasts)
        if expandedPath.lowercased().hasSuffix(".ttml") {
            return try extractTextFromTTML(at: expandedPath)
        }

        // Handle text/markdown files
        guard let text = EPUBBookFiles.text(atPath: expandedPath) else { throw SourceError.fileNotFound }
        return text.removingSoftHyphens()
    }
    /// Extract clean transcript text from an Apple Podcasts TTML file.
    /// TTML files contain XML with speaker segments and word-level spans.
    private func extractTextFromTTML(at path: String) throws -> String {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return try Self.extractTextFromTTMLContent(content)
    }

    /// Extract clean transcript text from raw TTML XML content.
    static func extractTextFromTTMLContent(_ content: String) throws -> String {
        // Extract speaker paragraphs: <p ... ttm:agent="SPEAKER_N"> ... </p>
        // Apple has emitted small TTML variations over time, so parse attributes
        // separately instead of depending on one exact attribute order/quote style.
        let paragraphPattern = #"<p\b([^>]*)>(.*?)</p>"#
        let wordPattern = #"<span[^>]*podcasts:unit=(["'])word\1[^>]*>(.*?)</span>"#
        
        guard let paraRegex = try? NSRegularExpression(pattern: paragraphPattern, options: .dotMatchesLineSeparators),
              let wordRegex = try? NSRegularExpression(pattern: wordPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            throw SourceError.decodingFailed
        }
        
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let paragraphs = paraRegex.matches(in: content, range: fullRange)
        
        var transcriptParts: [String] = []
        var currentSpeaker: String?
        
        for paraMatch in paragraphs {
            guard let attrsRange = Range(paraMatch.range(at: 1), in: content),
                  let bodyRange = Range(paraMatch.range(at: 2), in: content) else { continue }
            
            let attrs = String(content[attrsRange])
            let speaker = ttmlAttribute("ttm:agent", in: attrs)
                ?? ttmlAttribute("agent", in: attrs)
                ?? "SPEAKER"
            let body = String(content[bodyRange])
            
            // Extract all words from this paragraph
            let bodyNS = body as NSString
            let bodyRange2 = NSRange(location: 0, length: bodyNS.length)
            let wordMatches = wordRegex.matches(in: body, range: bodyRange2)
            
            // A word's soft hyphen goes before the spacing is cleaned up below,
            // so a word that was nothing else leaves no double space.
            let words = wordMatches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 2), in: body) else { return nil }
                return String(body[range]).decodingHTMLCharacterReferences().removingSoftHyphens()
            }

            var text = words.isEmpty
                ? body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    .decodingHTMLCharacterReferences()
                    .removingSoftHyphens()
                : words.joined(separator: " ")
            // Clean up spacing around punctuation
            text = text.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            
            if speaker != currentSpeaker {
                transcriptParts.append("\n\n[\(speaker)]\n\(text)")
                currentSpeaker = speaker
            } else {
                transcriptParts.append(" \(text)")
            }
        }
        
        // A speaker's name is read from an attribute; it keeps no soft hyphen either.
        let transcript = transcriptParts.joined().removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty {
            throw SourceError.decodingFailed
        }
        
        return transcript
    }

    private static func ttmlAttribute(_ name: String, in attrs: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:^|\s)"# + escapedName + #"=(["'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let valueRange = Range(match.range(at: 2), in: attrs) else { return nil }
        return String(attrs[valueRange]).decodingHTMLCharacterReferences()
    }
    
    nonisolated func extractTextFromPDF(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let pdfDocument = PDFDocument(url: url) else {
            throw SourceError.pdfReadFailed
        }
        
        let fullText = PDFTextExtractor.textWithFigureReferences(
            from: pdfDocument,
            pages: 0..<pdfDocument.pageCount
        )
        
        if fullText.isEmpty {
            throw SourceError.pdfReadFailed
        }
        
        return fullText
    }

    // MARK: - PDF Download

    /// Download a PDF from a remote URL and save it to a local file path.
    /// Validates the response is actually a PDF before writing.
    func downloadPDF(from urlString: String, to destinationPath: String) async throws {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidURL
        }
        if !ManagedAI.isForeverLMGatewayURL(url) {
            try await OutboundAddressPolicy.check(url)
        }

        // A publisher that hands the PDF only to a subscriber is answered with
        // the reader's own session, so a sign-in done there counts here.
        var request = ManagedAI.isForeverLMGatewayURL(url)
            ? Self.browserRequest(for: url, timeout: 180)
            : await Self.authenticatedBrowserRequest(for: url, timeout: 180)
        // A Slack file's download_url is served by ForeverLM's own gateway as
        // the learner; it needs the managed session, not a browser disguise.
        guard ManagedAI.authorizeIfForeverLMGateway(&request) else {
            throw SourceError.paperIngestionFailed(
                "Sign in with Apple in ForeverLM to fetch a file posted in Slack. ForeverLM fetches it as you, so a signed-out Mac has nothing to fetch with."
            )
        }
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.fetchFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // ForeverLM's own gateway says why in the body — a Slack connection
            // that predates files:read, a channel the learner has not enabled —
            // and that sentence is what the chat should relay, not a status code
            // it would otherwise read as a paywall.
            if ManagedAI.isForeverLMGatewayURL(url),
               let description = Self.gatewayErrorDescription(from: data) {
                throw SourceError.paperIngestionFailed(description)
            }
            // The host's own words go into the error: PMC answers an embargoed
            // manuscript with 403 "Supplemental document is embargoed", and a
            // bare "Access denied" hid that behind a paywall guess.
            throw PDFFetchRefusal.httpStatus(
                httpResponse.statusCode,
                host: Self.refusingHost(httpResponse, requested: url),
                body: data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
            )
        }

        // Check if we got a PDF
        if Self.isPDF(data: data, response: httpResponse) {
            try data.write(to: URL(fileURLWithPath: destinationPath))
            return
        }

        let host = Self.refusingHost(httpResponse, requested: url)

        // PMC's "Preparing to download ..." page: answer its proof of work and
        // ask again. The answer goes into the cookie jar the session reads, the
        // way the page's own script stores it — not as a hand-set `Cookie`
        // header, which cookie handling (on for every download since the reader's
        // cookies were lent through the jar) is free to replace, and which also
        // dropped the reader's own cookies for the host. It stays there for its
        // lifetime, so the next PMC file in a batch needs no second answer.
        if let html = String(data: data, encoding: .utf8),
           let challenge = Self.pmcProofOfWorkChallenge(in: html) {
            guard let nonce = await Self.solvePMCProofOfWork(challenge),
                  let cookie = Self.pmcProofOfWorkCookie(
                      for: challenge,
                      nonce: nonce,
                      host: (httpResponse.url ?? url).host ?? host,
                      now: Date()
                  ) else {
                throw PDFFetchRefusal.unansweredProofOfWork(host: host, afterAnswer: false)
            }
            (session.configuration.httpCookieStorage ?? HTTPCookieStorage.shared).setCookie(cookie)
            logger.info("PMC PoW: solved, retrying download with cookie")
            var retryRequest = request
            retryRequest.httpShouldHandleCookies = true

            let (retryData, retryResponse) = try await session.data(for: retryRequest)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw SourceError.fetchFailed
            }
            guard (200...299).contains(retryHTTP.statusCode) else {
                throw PDFFetchRefusal.httpStatus(
                    retryHTTP.statusCode,
                    host: host,
                    body: retryData,
                    contentType: retryHTTP.value(forHTTPHeaderField: "Content-Type"),
                    retryAfter: retryHTTP.value(forHTTPHeaderField: "Retry-After")
                )
            }
            guard Self.isPDF(data: retryData, response: retryHTTP) else {
                if let retryHTML = String(data: retryData, encoding: .utf8),
                   Self.pmcProofOfWorkChallenge(in: retryHTML) != nil {
                    throw PDFFetchRefusal.unansweredProofOfWork(host: host, afterAnswer: true)
                }
                throw PDFFetchRefusal.page(
                    host: host,
                    body: retryData,
                    contentType: retryHTTP.value(forHTTPHeaderField: "Content-Type")
                )
            }
            try retryData.write(to: URL(fileURLWithPath: destinationPath))
            return
        }

        throw PDFFetchRefusal.page(
            host: host,
            body: data,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    /// The host that answered, after redirects; the one asked when unknown.
    private static func refusingHost(_ response: HTTPURLResponse, requested url: URL) -> String {
        response.url?.host ?? url.host ?? url.absoluteString
    }

    /// The `error_description` of a gateway JSON error body, or nil when the
    /// body is not one. The gateway writes these for the learner to read.
    static func gatewayErrorDescription(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = object["error_description"] as? String else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - PMC Proof-of-Work Solver

    /// PMC's proof-of-work check, as its "Preparing to download ..." page
    /// states it: find a nonce whose SHA-256 of `challenge + nonce` starts with
    /// `difficulty` zero hex digits, and store `challenge,nonce` in the named
    /// cookie (its script then reloads the page and gets the file).
    struct PMCProofOfWorkChallenge: Equatable, Sendable {
        let challenge: String
        let difficulty: Int
        let cookieName: String
        let cookiePath: String?
        /// Days, as the page's script passes them to its cookie library.
        let cookieExpirationDays: Double?
    }

    /// Maximum PoW difficulty (leading zero hex nibbles) we will attempt. The
    /// value on the challenge page is remote-controlled, so we clamp it to keep
    /// the worst-case search bounded (16^6 ≈ 2^24 expected hashes).
    private static let maxPoWDifficulty = 6
    /// Hard cap on hashing iterations so a hostile challenge can never spin forever.
    private static let maxPoWIterations = 1 << 25

    /// The check a PMC interstitial states, or nil when `html` is not one.
    nonisolated static func pmcProofOfWorkChallenge(in html: String) -> PMCProofOfWorkChallenge? {
        guard let challenge = extractJSConstant(named: "POW_CHALLENGE", from: html),
              let cookieName = extractJSConstant(named: "POW_COOKIE_NAME", from: html) else {
            return nil
        }
        // The page's script reads an unparseable difficulty as 4
        // (`parseInt(n, 10) || 4`); answering it the same way is answering
        // the page, not guessing.
        let requestedDifficulty = Int(extractJSConstant(named: "POW_DIFFICULTY", from: html) ?? "") ?? 4
        return PMCProofOfWorkChallenge(
            challenge: challenge,
            difficulty: max(0, min(requestedDifficulty, maxPoWDifficulty)),
            cookieName: cookieName,
            cookiePath: extractJSConstant(named: "POW_COOKIE_PATH", from: html),
            cookieExpirationDays: extractJSConstant(named: "POW_COOKIE_EXPIRATION", from: html).flatMap(Double.init)
        )
    }

    /// The cookie the page's script would set for a solved check. It lives as
    /// long as the page says; with no lifetime stated it is a session cookie.
    nonisolated static func pmcProofOfWorkCookie(
        for challenge: PMCProofOfWorkChallenge,
        nonce: Int,
        host: String,
        now: Date
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: challenge.cookieName,
            .value: "\(challenge.challenge),\(nonce)",
            .domain: host,
            .path: challenge.cookiePath.flatMap { $0.isEmpty ? nil : $0 } ?? "/",
            .secure: "TRUE",
        ]
        if let days = challenge.cookieExpirationDays, days > 0 {
            properties[.expires] = now.addingTimeInterval(days * MemoryTutorScheduler.secondsPerDay)
        }
        return HTTPCookie(properties: properties)
    }

    /// Solve a PMC proof-of-work check. The (CPU-bound) hashing loop runs off
    /// the actor and is cancellable so it can never block the actor or spin
    /// unbounded on an attacker-controlled difficulty.
    private static func solvePMCProofOfWork(_ challenge: PMCProofOfWorkChallenge) async -> Int? {
        let nonce: Int?
        do {
            nonce = try await Task.detached(priority: .userInitiated) {
                try findPMCPoWNonce(challenge: challenge.challenge, difficulty: challenge.difficulty)
            }.value
        } catch {
            logger.warning("PMC PoW: hashing cancelled or failed: \(error.localizedDescription)")
            return nil
        }

        guard let solved = nonce else {
            logger.warning("PMC PoW: failed to solve within limit")
            return nil
        }
        logger.info("PMC PoW: solved (difficulty=\(challenge.difficulty), nonce=\(solved))")
        return solved
    }

    /// Search for a PoW nonce where SHA256(challenge + nonce) has `difficulty`
    /// leading zero hex nibbles. Runs off the actor (detached) and checks for
    /// cancellation periodically so it can be torn down promptly.
    nonisolated private static func findPMCPoWNonce(challenge: String, difficulty: Int) throws -> Int? {
        let fullPairs = difficulty / 2
        let halfNibble = difficulty % 2 == 1
        var nonce = 0
        while nonce < maxPoWIterations {
            if nonce & 0xFFF == 0 {
                try Task.checkCancellation()
            }
            let input = Data((challenge + String(nonce)).utf8)
            let hash = SHA256.hash(data: input)
            // Check leading hex characters without allocating a full hex string
            let bytes = Array(hash)
            var match = true
            for i in 0..<fullPairs {
                if bytes[i] != 0 { match = false; break }
            }
            if match && halfNibble && (bytes[fullPairs] >> 4) != 0 {
                match = false
            }
            if match {
                return nonce
            }
            nonce += 1
        }
        return nil
    }

    /// Extract a JavaScript constant value like `const NAME = "value"` from HTML.
    nonisolated private static func extractJSConstant(named name: String, from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: name + #"\s*=\s*"([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    // MARK: - Request Helpers

    /// Build a URLRequest with browser-like headers to avoid bot detection.
    /// A browser-shaped request that also carries the cookies the app's own
    /// web views hold, so a publisher subscription the learner signed into in
    /// the reader is used by ForeverLM's own fetches and downloads.
    static func authenticatedBrowserRequest(for url: URL, timeout: TimeInterval) async -> URLRequest {
        var request = browserRequest(for: url, timeout: timeout)
        InAppWebSession.apply(await InAppWebSession.cookies(for: url), to: &request)
        return request
    }

    /// The user agent is the installed Safari's, not a pinned Chrome string: a
    /// pinned version ages into a bot signal. Chrome 131 is what nick-lane.net's
    /// firewall answered with a 403 in 2026-09 while serving the same open PDF
    /// to Safari, so the reader called the file paywalled. A Safari agent also
    /// matches the TLS handshake Apple's networking stack actually makes.
    nonisolated static func browserRequest(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        if let host = url.host {
            request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        return request
    }

    /// Check whether data contains a PDF header near the start of the payload.
    ///
    /// Rejects HTML up front. Paywall/landing pages, PMC "Lock" pages, and the NCBI
    /// "Preparing to download…" proof-of-work interstitial all begin — after an
    /// optional BOM and whitespace — with `<`, which a real PDF never does. Without
    /// this guard an HTML page that merely mentions "%PDF-" somewhere in its first
    /// kilobyte (a viewer script, an error message) would be misread as a PDF and
    /// saved as the final paper, which is exactly how those interstitials leaked in.
    nonisolated static func looksLikePDFData(_ data: Data) -> Bool {
        let signature = Data([0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
        let head = Data(data.prefix(1024))
        guard head.count >= signature.count else { return false }

        // Find the first meaningful byte, skipping a UTF-8 BOM and leading
        // whitespace (space, tab, CR, LF, FF, NUL) the way lenient readers do.
        let bytes = [UInt8](head)
        var i = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x00]
        while i < bytes.count, whitespace.contains(bytes[i]) { i += 1 }

        // A document that starts with '<' is HTML/XML, not a PDF.
        if i < bytes.count, bytes[i] == 0x3C /* '<' */ { return false }

        return head.range(of: signature) != nil
    }

    /// Check whether a local PDF file is both PDF-like and readable by PDFKit.
    nonisolated static func canOpenPDF(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              looksLikePDFData(data),
              let document = PDFDocument(url: url) else { return false }
        return document.pageCount > 0
    }

    /// Check whether data + response represent a valid PDF.
    private static func isPDF(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let hasPDFContentType = contentType.contains("application/pdf")
        let hasPDFMagicBytes = looksLikePDFData(data)
        if hasPDFContentType && !hasPDFMagicBytes {
            logger.warning("Rejected PDF response without PDF magic bytes")
        }
        return hasPDFMagicBytes
    }

    // Paper-specific functionality (PDF URL resolution, metadata lookup, DOI extraction,
    // domain classification, PMC/Unpaywall/Crossref/arXiv/OpenAlex APIs) has been moved
    // to PaperService.swift.

    // MARK: - HTML Text Extraction
    
    private func extractTextFromHTML(_ html: String) -> String {
        Self.readableTextFromHTML(html)
    }

    /// The same semantic article slice feeds stored source text and the archived
    /// reader document. Keeping one boundary prevents the Mac reader from looking
    /// clean while iOS receives the surrounding site's recommendation cards.
    nonisolated static func readableTextFromHTML(_ html: String) -> String {
        var text = readerHTML(from: html)

        // Preserve the structure that still matters after HTML becomes synced
        // plain text. The iOS reader understands these small Markdown markers;
        // search and AI context also retain useful section boundaries.
        for level in 1...6 {
            text = text.replacingOccurrences(
                of: #"<h\#(level)\b[^>]*>"#,
                with: "\n\n\(String(repeating: "#", count: level)) ",
                options: [.regularExpression, .caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: #"</h\#(level)>"#,
                with: "\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: #"<li\b[^>]*>"#, with: "\n- ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<blockquote\b[^>]*>"#, with: "\n\n> ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</blockquote>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<sup\b[^>]*>"#, with: "^(", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</sup>"#, with: ")", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: #"</?(?:p|div|br|tr|figure|figcaption|pre|ul|ol|table|thead|tbody|section|article)\b[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // A soft hyphen, written raw or as `&shy;`, is where the page may break
        // a word, not a character of it.
        text = text.decodingHTMLCharacterReferences().removingSoftHyphens()

        let lines = text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var normalized: [String] = []
        for line in lines {
            if line.isEmpty, normalized.last?.isEmpty == true { continue }
            normalized.append(line)
        }
        text = normalized.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    // MARK: - Article Archival (HTML + Images)

    /// Result of archiving a web article locally.
    struct ArchivedArticle: Sendable {
        /// Plain text for LLM / search (same as fetchContent would return).
        let plainText: String
        /// Absolute path to the saved HTML file on disk (nil if archival failed but text succeeded).
        let localHTMLPath: String?
        /// Title from og:title / <title> when available.
        let pageTitle: String?
        /// Author from HTML meta tags when available.
        let pageAuthor: String?
        /// Every title the page offered for itself, for the article-metadata
        /// model to read; see `PaperService.WebArticleTitleEvidence`.
        var titleEvidence: PaperService.WebArticleTitleEvidence? = nil
    }

    /// A refresh capture lives outside the canonical article directory until
    /// its extracted text has passed Source Content Cleanup. This keeps a
    /// logged-out page, timeout, or failed model call from damaging the saved
    /// article the learner can already read.
    struct StagedArticleRefresh: Sendable {
        let article: ArchivedArticle
        fileprivate let sourceURL: String
        fileprivate let stagingSourceID: String
        fileprivate let previousCachedText: String?

        /// A staging folder of its own under `Articles/`, never a source's.
        fileprivate static func newStagingID(for sourceID: String) -> String {
            ".article-refresh-\(sourceID)-\(UUID().uuidString)"
        }
    }

    /// Filesystem half of an installed refresh. The previous archive remains
    /// beside it until SQLite accepts the new canonical text, allowing the
    /// caller to roll the archive back if the transactional source save fails.
    struct InstalledArticleRefreshArchive: Sendable {
        let finalHTMLPath: String
        fileprivate let finalDirectoryPath: String
        fileprivate let backupDirectoryPath: String?
    }

    /// Stable Figshare record identity derived only from URL structure. Figshare's
    /// ordinary collection pages sit behind a browser challenge, while its public
    /// JSON API exposes the same title, authors, and description without one.
    struct FigshareResource: Sendable, Equatable {
        enum Kind: String, Sendable {
            case articles
            case collections
        }

        let kind: Kind
        let id: String

        var apiURL: URL? {
            URL(string: "https://api.figshare.com/v2/\(kind.rawValue)/\(id)")
        }
    }

    struct FigshareMetadata: Sendable, Equatable {
        let title: String
        let author: String?
        let descriptionHTML: String?
    }

    private struct FigshareAPIAuthor: Decodable {
        let fullName: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }

    private struct FigshareAPIPayload: Decodable {
        let title: String
        let description: String?
        let authors: [FigshareAPIAuthor]?
    }

    nonisolated static func figshareResource(from url: URL) -> FigshareResource? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "doi.org" || host == "dx.doi.org" {
            // A Figshare DOI reads "<prefix>/<registrant>.figshare[.plus][.c].<id>.v<n>",
            // and the prefix is separated by a slash rather than a dot — so split on
            // both, or "10.25452/figshare" hides the marker the suffix hangs off.
            let components = url.path
                .lowercased()
                .split(whereSeparator: { $0 == "/" || $0 == "." })
            guard let markerIndex = components.firstIndex(of: "figshare") else { return nil }
            // Only the components after the marker describe the record: the ID comes
            // before the ".v<n>" version, and "c" there is what marks a collection.
            let suffix = components[components.index(after: markerIndex)...]
            guard let id = suffix.first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }
            let kind: FigshareResource.Kind = suffix.contains("c") ? .collections : .articles
            return FigshareResource(kind: kind, id: String(id))
        }

        guard host == "figshare.com" || host.hasSuffix(".figshare.com") else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        for (marker, kind) in [
            ("collections", FigshareResource.Kind.collections),
            ("articles", FigshareResource.Kind.articles),
        ] {
            guard let markerIndex = pathComponents.firstIndex(where: {
                $0.caseInsensitiveCompare(marker) == .orderedSame
            }) else { continue }
            if let id = pathComponents[pathComponents.index(after: markerIndex)...]
                .first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return FigshareResource(kind: kind, id: id)
            }
        }
        return nil
    }

    nonisolated static func decodeFigshareMetadata(from data: Data) -> FigshareMetadata? {
        guard let payload = try? JSONDecoder().decode(FigshareAPIPayload.self, from: data) else {
            return nil
        }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let authorNames = (payload.authors ?? [])
            .map { $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let author: String?
        switch authorNames.count {
        case 0: author = nil
        case 1: author = authorNames[0]
        case 2: author = "\(authorNames[0]) & \(authorNames[1])"
        default: author = "\(authorNames[0]) et al."
        }
        let description = payload.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FigshareMetadata(
            title: title,
            author: author,
            descriptionHTML: description?.isEmpty == false ? description : nil
        )
    }

    private func fetchFigshareMetadata(for url: URL) async -> FigshareMetadata? {
        guard let apiURL = Self.figshareResource(from: url)?.apiURL else { return nil }
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return Self.decodeFigshareMetadata(from: data)
        } catch {
            logger.warning("Figshare metadata lookup failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fetch a web article and archive it locally with images for offline reading.
    /// Saves cleaned HTML + downloaded images to `Articles/<sourceId>/` under the ForeverLM root.
    /// Always returns plain text; the HTML archive is best-effort.
    func fetchAndArchiveWebContent(
        url urlString: String,
        sourceId: String,
        existingText: String? = nil,
        preferAuthenticatedBrowser: Bool = false,
        attributionSourceId: String? = nil
    ) async throws -> ArchivedArticle {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidURL
        }
        try await OutboundAddressPolicy.check(url)

        if let resource = Self.googleDocsResource(from: url) {
            let text = try await fetchGoogleDocsText(resource: resource)
            cache[urlString] = text
            return ArchivedArticle(plainText: text, localHTMLPath: nil, pageTitle: nil, pageAuthor: nil)
        }

        // An X post is not a web page an ordinary fetch can read: x.com answers
        // HTTP clients with a JavaScript shell, shows logged-out visitors a
        // login wall, and is the first thing to vanish when the Mac is offline
        // or Screen Time restricts the domain. X publishes the post itself as
        // JSON through its embed endpoint, so capture the post and the thread
        // it replies to and archive *that* as the source's document. Everything
        // downstream — the reader's offline fallback, search, the assistant,
        // the phone — then reads a copy that does not depend on reaching x.com.
        if XPostThreadService.postID(from: urlString) != nil {
            let thread = try await XPostThreadService.shared.capture(
                postURL: urlString,
                existingText: existingText
            )
            let plainText = thread.plainText
            guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceError.insufficientContent
            }
            let localPath = await archiveHTMLToDisk(
                rawHTML: thread.archiveHTML,
                sourceId: sourceId,
                baseURL: url
            )
            cache[urlString] = plainText
            return ArchivedArticle(
                plainText: plainText,
                localHTMLPath: localPath,
                pageTitle: thread.sourceTitle,
                pageAuthor: thread.subject?.authorName
            )
        }

        // Figshare collection pages currently answer ordinary HTTP clients with
        // `202` and an empty AWS WAF challenge body. Use Figshare's authoritative
        // public record API so title extraction and ingestion do not depend on a
        // hidden browser winning that challenge. Any supplied description remains
        // publisher content and is archived through the normal reader path; a
        // metadata-only record still gets its canonical title persisted.
        if let metadata = await fetchFigshareMetadata(for: url) {
            let escapedTitle = metadata.title.htmlEscaped
            let escapedAuthor = metadata.author.map(\.htmlEscaped)
            let byline = escapedAuthor.map { "<p>\($0)</p>" } ?? ""
            let descriptionHTML = metadata.descriptionHTML ?? ""
            let document = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>\(escapedTitle)</title></head>
            <body><article><h1>\(escapedTitle)</h1>\(byline)\(descriptionHTML)</article></body></html>
            """
            let plainText = extractTextFromHTML(document)
            if !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let localPath = await archiveHTMLToDisk(rawHTML: document, sourceId: sourceId, baseURL: url)
                cache[urlString] = plainText
                return ArchivedArticle(
                    plainText: plainText,
                    localHTMLPath: localPath,
                    pageTitle: metadata.title,
                    pageAuthor: metadata.author
                )
            }
        }

        // A Substack app link is read at the post's own address: signed in,
        // the app link is the reader, not the post (`SubstackAppLink`).
        let pageURL = await SubstackAppLink.readingAddress(for: url)
        guard let rawHTML = try await fetchPageHTML(
            url: pageURL,
            preferAuthenticatedBrowser: preferAuthenticatedBrowser
        ) else {
            throw SourceError.fetchFailed
        }
        return try await archiveWebPageHTML(
            rawHTML,
            url: pageURL,
            cacheKey: urlString,
            sourceId: sourceId,
            attributionSourceId: attributionSourceId
        )
    }

    /// Archive a page the reader has already rendered, as the source's document.
    ///
    /// The same pipeline as a fetched page from the HTML onward: the hidden fetch
    /// and the visible reader see the same site, so what differs is only who won
    /// the publisher's bot check. The reader's copy is the document after
    /// scripts ran, which is what the hidden fetch reads too.
    func archiveRenderedWebContent(
        html: String,
        url urlString: String,
        sourceId: String,
        archiveToDisk: Bool = true
    ) async throws -> ArchivedArticle {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidURL
        }
        return try await archiveWebPageHTML(
            html,
            url: url,
            cacheKey: urlString,
            sourceId: sourceId,
            attributionSourceId: nil,
            writeArchive: archiveToDisk
        )
    }

    /// Turn a page's HTML into stored text plus the archived reader document.
    /// `cacheKey` is the source's URL as stored, which is what `fetchContent`
    /// looks the text up by.
    /// `writeArchive` is false for a paper read from a publisher page: the
    /// text is wanted, but a paper's local file is its PDF, so no reader
    /// document is written for it.
    private func archiveWebPageHTML(
        _ rawHTML: String,
        url: URL,
        cacheKey: String,
        sourceId: String,
        attributionSourceId: String?,
        writeArchive: Bool = true
    ) async throws -> ArchivedArticle {
        let decodedHTML = rawHTML.repairingUTF8Mojibake()
        let pageMetadata = PaperService.extractWebArticleMetadata(from: decodedHTML)

        // Decide once, here, which parts of the page are the article. Both the
        // stored text and the archived reader document descend from this
        // string, so a menu removed now is a menu absent from the Mac reader,
        // the phone, search, and AI context alike.
        let readableHTML = await ArticleChromeFilter.filteringSiteChrome(
            in: decodedHTML,
            source: AIUsageSource(
                id: attributionSourceId ?? sourceId,
                sourceType: .article,
                title: pageMetadata?.title ?? ""
            ),
            pageURL: url,
            articleTitle: pageMetadata?.title
        )

        let plainText = extractTextFromHTML(readableHTML)
        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !SubstackAppLink.isReaderShell(plainText) else {
            throw SourceError.insufficientContent
        }

        // Best-effort archival: clean HTML, download images, save to disk
        let localPath = writeArchive
            ? await archiveHTMLToDisk(rawHTML: readableHTML, sourceId: sourceId, baseURL: url)
            : nil

        cache[cacheKey] = plainText
        return ArchivedArticle(
            plainText: plainText,
            localHTMLPath: localPath,
            pageTitle: pageMetadata?.title,
            pageAuthor: pageMetadata?.author,
            titleEvidence: pageMetadata?.titleEvidence
        )
    }

    /// Capture the current page through ForeverLM's persistent WebKit profile.
    /// The explicit browser-first route is the important difference from normal
    /// ingestion: an ordinary 200 response may contain only a public paywall
    /// preview, while the browser profile holds the subscription cookies the
    /// learner established in the live Reader.
    func stageArticleRefresh(url urlString: String, sourceId: String) async throws -> StagedArticleRefresh {
        let stagingSourceID = StagedArticleRefresh.newStagingID(for: sourceId)
        let previousCachedText = cache[urlString]
        do {
            let article = try await fetchAndArchiveWebContent(
                url: urlString,
                sourceId: stagingSourceID,
                existingText: nil,
                preferAuthenticatedBrowser: true,
                attributionSourceId: sourceId
            )
            return StagedArticleRefresh(
                article: article,
                sourceURL: urlString,
                stagingSourceID: stagingSourceID,
                previousCachedText: previousCachedText
            )
        } catch {
            removeArticleArchiveDirectory(sourceID: stagingSourceID)
            restoreCache(url: urlString, text: previousCachedText)
            throw error
        }
    }

    /// Move a successfully prepared staged archive into place while retaining
    /// the old directory for rollback until the caller commits SQLite.
    func installStagedArticleRefreshArchive(
        _ staged: StagedArticleRefresh,
        sourceId: String
    ) throws -> InstalledArticleRefreshArchive? {
        guard staged.article.localHTMLPath != nil else { return nil }

        let articlesRoot = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles")
        let stagingDirectory = (articlesRoot as NSString)
            .appendingPathComponent(staged.stagingSourceID)
        let finalDirectory = (articlesRoot as NSString).appendingPathComponent(sourceId)
        let finalHTMLPath = (finalDirectory as NSString).appendingPathComponent("article.html")
        let backupDirectory = (articlesRoot as NSString)
            .appendingPathComponent(".article-refresh-backup-\(sourceId)-\(UUID().uuidString)")
        let fm = FileManager.default

        guard fm.fileExists(atPath: stagingDirectory) else {
            throw SourceError.fetchFailed
        }
        try fm.createDirectory(atPath: articlesRoot, withIntermediateDirectories: true)

        var installedBackup: String?
        do {
            if fm.fileExists(atPath: finalDirectory) {
                try fm.moveItem(atPath: finalDirectory, toPath: backupDirectory)
                installedBackup = backupDirectory
            }
            try fm.moveItem(atPath: stagingDirectory, toPath: finalDirectory)
            return InstalledArticleRefreshArchive(
                finalHTMLPath: finalHTMLPath,
                finalDirectoryPath: finalDirectory,
                backupDirectoryPath: installedBackup
            )
        } catch {
            if fm.fileExists(atPath: finalDirectory) {
                try? fm.removeItem(atPath: finalDirectory)
            }
            if let installedBackup, fm.fileExists(atPath: installedBackup) {
                try? fm.moveItem(atPath: installedBackup, toPath: finalDirectory)
            }
            throw error
        }
    }

    /// Finalize the archive after the source/content transaction has committed.
    func commitInstalledArticleRefreshArchive(
        _ installed: InstalledArticleRefreshArchive,
        sourceId: String
    ) async {
        if let backup = installed.backupDirectoryPath {
            try? FileManager.default.removeItem(atPath: backup)
        }
        #if os(macOS)
        do {
            _ = try await ArticleArchiveCache.shared.prepare(
                canonicalHTMLPath: installed.finalHTMLPath,
                sourceID: sourceId,
                refresh: true
            )
        } catch {
            logger.warning("Could not refresh local article cache for \(sourceId): \(error.localizedDescription)")
        }
        #endif
    }

    /// Restore the former archive after a failed SQLite save and return the
    /// SourceService cache to the text visible before the refresh began.
    func rollbackInstalledArticleRefreshArchive(
        _ installed: InstalledArticleRefreshArchive,
        staged: StagedArticleRefresh
    ) {
        let fm = FileManager.default
        if fm.fileExists(atPath: installed.finalDirectoryPath) {
            try? fm.removeItem(atPath: installed.finalDirectoryPath)
        }
        if let backup = installed.backupDirectoryPath,
           fm.fileExists(atPath: backup) {
            try? fm.moveItem(atPath: backup, toPath: installed.finalDirectoryPath)
        }
        restoreCache(url: staged.sourceURL, text: staged.previousCachedText)
    }

    /// Discard a capture that was unchanged, shorter than the saved copy, or
    /// failed cleanup before it reached storage.
    func discardStagedArticleRefresh(_ staged: StagedArticleRefresh) {
        removeArticleArchiveDirectory(sourceID: staged.stagingSourceID)
        restoreCache(url: staged.sourceURL, text: staged.previousCachedText)
    }

    /// Complete a text-only refresh (for example, a Google export with no HTML
    /// archive) while retaining the newly fetched value in the service cache.
    func commitStagedArticleRefresh(_ staged: StagedArticleRefresh) {
        removeArticleArchiveDirectory(sourceID: staged.stagingSourceID)
    }

    /// Remove the reader document archived for a source, because it is not
    /// the document: the fetch archives a page before its text is judged, so
    /// a source parked behind a publisher bot check has the check's own page
    /// on disk.
    func discardArticleArchive(sourceID: String) {
        removeArticleArchiveDirectory(sourceID: sourceID)
    }

    private func removeArticleArchiveDirectory(sourceID: String) {
        let directory = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles/\(sourceID)")
        if FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private func restoreCache(url: String, text: String?) {
        if let text {
            cache[url] = text
        } else {
            cache.removeValue(forKey: url)
        }
    }

    /// Rewrite one already-archived article's reader document from the live page,
    /// leaving its canonical text alone.
    ///
    /// The backfill for archives written before `ArticleChromeFilter` existed
    /// deliberately does not re-derive text: `source_content` was cleaned by
    /// Source Content Cleanup when the article was ingested and is already free
    /// of site furniture. Re-running that pass would be the expensive half of a
    /// refetch and could only turn a good `ready` source into an error. Nor does
    /// it check that the text is whole: one cut short is
    /// completed from this archive by the canonical cleanup
    /// (`CanonicalContentCleanupService.withCompleteArticleExtraction`).
    ///
    /// Returns the archived path, or nil when the page could not be archived.
    func refreshArchivedArticleHTML(url urlString: String, sourceId: String) async throws -> String? {
        guard let url = URL(string: urlString) else { throw SourceError.invalidURL }
        guard let rawHTML = try await fetchPageHTML(url: url) else { throw SourceError.fetchFailed }

        let decodedHTML = rawHTML.repairingUTF8Mojibake()
        let pageMetadata = PaperService.extractWebArticleMetadata(from: decodedHTML)
        let readableHTML = await ArticleChromeFilter.filteringSiteChrome(
            in: decodedHTML,
            source: AIUsageSource(id: sourceId, sourceType: .article, title: pageMetadata?.title ?? ""),
            pageURL: url,
            articleTitle: pageMetadata?.title
        )
        // A page that now answers with a consent wall or an error shell would
        // otherwise replace a good archive with nothing.
        guard !extractTextFromHTML(readableHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.insufficientContent
        }
        return await archiveHTMLToDisk(rawHTML: readableHTML, sourceId: sourceId, baseURL: url)
    }

    /// Fetch a page as HTML, falling back to a real browser for JS-heavy or
    /// bot-protected sites. Shared by first ingestion and the archive refresh so
    /// both see the same page a person would.
    ///
    /// Throws `linkIsPDF` when the address serves a PDF file, and
    /// `accessDenied` when the site refused the request (401/403) and the
    /// browser could not read the page either. Without those, both arrive
    /// downstream as a page with no text in it, which says nothing about why.
    private func fetchPageHTML(
        url: URL,
        preferAuthenticatedBrowser: Bool = false
    ) async throws -> String? {
        #if os(macOS)
        if preferAuthenticatedBrowser {
            do {
                let authenticatedHTML = try await WebViewContentExtractor.shared.extractHTML(from: url)
                if !authenticatedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return authenticatedHTML
                }
            } catch {
                logger.error("Reading the page in the signed-in browser failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        var request = URLRequest(url: url)
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                        forHTTPHeaderField: "Accept")

        var fetchedHTML: String?
        var refused = false
        // A failed request falls through to the browser below.
        let plainFetch = try? await session.data(for: request)
        if let data = plainFetch?.0, let httpResponse = plainFetch?.1 as? HTTPURLResponse {
            // A `/download` address, or a landing page that redirects to the
            // file, answers with a PDF. In a browser that is a PDF viewer with
            // no text in its markup, so reading it as a page finds nothing.
            if (200...299).contains(httpResponse.statusCode), Self.looksLikePDFData(data) {
                throw SourceError.linkIsPDF
            }
            refused = [401, 403].contains(httpResponse.statusCode)
            if httpResponse.statusCode == 200,
               !data.isEmpty,
               let candidate = String(data: data, encoding: .utf8),
               !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fetchedHTML = candidate
            }
        }

        #if os(macOS)
        // A page whose article its scripts write answers plain HTTP with the
        // empty frame they write into, and a 200 with that frame must not be
        // taken as the article. Substack's app link, fetched with the Substack
        // sign-in this session's cookie store holds, is 29 words of navigation
        // and "This site requires JavaScript", the post only in script data:
        // such posts would be saved as their navigation bar.
        // `fetchWebContent` reads so thin a page again in a browser; this path,
        // the one ingestion uses, does too.
        if let fetchedHTML,
           Self.readableWordCount(ofHTML: fetchedHTML) >= Self.scriptRenderedPageWordThreshold {
            return fetchedHTML
        }
        let renderedHTML: String?
        do {
            renderedHTML = try await WebViewContentExtractor.shared.extractHTML(from: url)
        } catch {
            logger.error("Reading the page in a browser failed: \(error.localizedDescription, privacy: .public)")
            renderedHTML = nil
        }
        let page = Self.fullerPageHTML(fetched: fetchedHTML, rendered: renderedHTML)
        #else
        let page = fetchedHTML
        #endif
        // A bot wall the browser shows as text is judged downstream
        // (`SourceDiscovery.isSecurityVerificationContent`); one that leaves
        // nothing readable is the site's refusal, and is reported as that.
        if refused, page.map({ Self.readableWordCount(ofHTML: $0) == 0 }) ?? true {
            throw SourceError.accessDenied
        }
        return page
    }

    /// Below this many readable words, a page fetched over plain HTTP is
    /// taken to be a frame its scripts fill in, and is read again in a browser.
    nonisolated static let scriptRenderedPageWordThreshold = 200

    /// Words of article text `readableTextFromHTML` finds in a page.
    nonisolated static func readableWordCount(ofHTML html: String) -> Int {
        readableTextFromHTML(html).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The copy of a thin page that becomes the article: the browser's when it
    /// reads longer than the plain fetch, which a short page that needs no
    /// script keeps, and whichever exists when the other could not be had.
    nonisolated static func fullerPageHTML(fetched: String?, rendered: String?) -> String? {
        let rendered = rendered.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        guard let fetched else { return rendered }
        guard let rendered else { return fetched }
        return readableWordCount(ofHTML: rendered) > readableWordCount(ofHTML: fetched)
            ? rendered
            : fetched
    }

    /// Clean raw HTML into a reader-friendly document and save it with downloaded images.
    /// Returns the absolute path to the saved HTML file, or nil on failure.
    private func archiveHTMLToDisk(rawHTML: String, sourceId: String, baseURL: URL) async -> String? {
        let fm = FileManager.default
        let root = StorageService.libraryRootPath
        let articleDir = (root as NSString).appendingPathComponent("Articles/\(sourceId)")
        let imagesDir = (articleDir as NSString).appendingPathComponent("images")
        let htmlPath = (articleDir as NSString).appendingPathComponent("article.html")

        do {
            try fm.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // Clean the HTML
        var cleaned = Self.readerHTML(from: rawHTML)

        // Point relative links back at the site — they resolve against the
        // archive folder once the document lives on disk.
        cleaned = Self.absolutizingLinks(
            in: cleaned,
            baseURL: Self.linkResolutionBase(forRawHTML: rawHTML, pageURL: baseURL)
        )

        // Download images and rewrite src attributes
        cleaned = await downloadAndRewriteImages(in: cleaned, baseURL: baseURL, imagesDir: imagesDir)

        // Wrap in a standalone HTML document with basic styling
        let document = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            max-width: 720px;
            margin: 2em auto;
            padding: 0 1em;
            line-height: 1.6;
            font-size: 17px;
          }
          img { max-width: 100%; height: auto; border-radius: 4px; }
          pre, code { font-size: 0.9em; }
          pre { overflow-x: auto; padding: 1em; border-radius: 6px; }
          blockquote {
            border-left: 3px solid #888;
            margin-left: 0;
            padding-left: 1em;
            color: #666;
          }
          \(Self.archivedArticleColorCSS)
        </style>
        </head>
        <body>
        \(cleaned)
        </body>
        </html>
        """

        do {
            try document.write(toFile: htmlPath, atomically: true, encoding: .utf8)
            #if os(macOS)
            do {
                _ = try await ArticleArchiveCache.shared.prepare(
                    canonicalHTMLPath: htmlPath,
                    sourceID: sourceId,
                    refresh: true
                )
            } catch {
                logger.warning("Could not create local article cache for \(sourceId): \(error.localizedDescription)")
            }
            #endif
            return htmlPath
        } catch {
            return nil
        }
    }

    /// Sanitize page HTML without deciding which visible text is meaningful.
    nonisolated static func readerHTML(from html: String) -> String {
        let inertPatterns = [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<noscript[^>]*>[\s\S]*?</noscript>"#,
            #"<iframe[^>]*>[\s\S]*?</iframe>"#,
        ]
        var candidateHTML = html.repairingUTF8Mojibake()
        for pattern in inertPatterns {
            candidateHTML = candidateHTML.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        var text: String

        // Substack has a stable, explicit post container. Select it before tag
        // stripping so publication chrome, avatars, and engagement controls do
        // not collapse into the article as loose text. Other sites continue to
        // use the complete visible body; their semantic cleanup remains owned by
        // the configured article-cleanup model.
        if let postSlice = substackPostHTML(from: candidateHTML) {
            text = postSlice
        } else if let bodyMatch = candidateHTML.range(of: #"<body[^>]*>([\s\S]*)</body>"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(candidateHTML[bodyMatch])
        } else {
            text = candidateHTML
        }

        // Remove script and style blocks
        let removePatterns = [
            inertPatterns[0],
            inertPatterns[1],
            inertPatterns[2],
            inertPatterns[3],
        ]
        for pattern in removePatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        text = numberingInlineFootnotes(in: text)
        // A disclosure's label is a line of its own. Stripped as an unknown
        // tag, it ran into the first sentence of what it discloses.
        text = text.replacingOccurrences(of: #"<summary\b[^>]*>"#, with: "<p>", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</summary\s*>"#, with: "</p>", options: [.regularExpression, .caseInsensitive])

        // Strip all tags except the ones we want to keep
        // First, protect the tags we want
        let allowedTags = "p|h[1-6]|img|figure|figcaption|blockquote|ul|ol|li|a|em|strong|b|i|code|pre|br|hr|sub|sup|table|thead|tbody|tr|th|td"
        // Anchor targets usually sit on a wrapper the allow list drops, so
        // convert them before stripping or in-page links land nowhere.
        text = preservingAnchorTargets(in: text, allowedTags: allowedTags)
        // Remove tags that aren't in our allow list
        let tagPattern = #"<(/?)(?!(?:\#(allowedTags))\b)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>"#
        text = text.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)

        // Clean up excessive whitespace between tags
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    /// Footnotes a page writes inside the sentence they annotate, numbered in
    /// place and gathered under Footnotes at the end of the article.
    ///
    /// Distill — distill.pub's article template, which al-folio and many
    /// research blogs use — writes each footnote as a `<d-footnote>` element
    /// in the middle of its sentence and leaves the number, the hover box and
    /// the list in the appendix to its script. ForeverLM runs no page script
    /// and `readerHTML` keeps an allow list of tags, so the element went and
    /// its words ran straight into the sentence: "accurately predicting an
    /// atom’s distances to nearby atomsSpecifically, for an atom-pair l,m, we
    /// ignore the loss…", 27 times over in The Illustrated AlphaFold
    /// in the reader, in the stored text and in Listen alike.
    /// The element is the template's own markup for a footnote, not a guess
    /// from a class name, so it is drawn the way the template draws it: a
    /// numbered reference where it stood, and the note, whole, in a numbered
    /// list after the article.
    nonisolated static func numberingInlineFootnotes(in html: String) -> String {
        // The name must end at `footnote`: Distill's appendix holds an empty
        // `<d-footnote-list>` its script fills, which is no note.
        guard html.range(of: "<d-footnote", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"<d-footnote(?=[\s/>])[^>]*>([\s\S]*?)</d-footnote\s*>"#,
                options: [.caseInsensitive]
              ) else { return html }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var notes: [String] = []
        var cursor = 0
        for match in matches {
            let number = notes.count + 1
            result += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "<sup><a href=\"#flm-footnote-\(number)\" id=\"flm-footnote-ref-\(number)\">\(number)</a></sup>"
            // A note is one paragraph of the list, so its own paragraph tags
            // would split the number from its words.
            let note = nsHTML.substring(with: match.range(at: 1))
                .replacingOccurrences(of: #"</?p\b[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            notes.append(note)
            cursor = match.range.location + match.range.length
        }
        result += nsHTML.substring(from: cursor)

        let list = notes.enumerated().map { index, note in
            "<p id=\"flm-footnote-\(index + 1)\"><sup>\(index + 1)</sup> \(note)</p>"
        }
        return result + "\n<h2>Footnotes</h2>\n" + list.joined(separator: "\n")
    }

    // MARK: - Link Preservation

    /// Keep the targets of in-page links alive across tag stripping.
    ///
    /// A table of contents links to `#priority-1`, but the matching id almost
    /// always sits on a wrapper — `<div class="anchor" id="priority-1">` — and
    /// wrappers aren't in the allow list. Stripping them would leave every in-page
    /// link pointing at an id that does not exist, so clicking would do nothing.
    /// Replace those opening tags with an empty `<a id="…">`, which survives.
    /// Ids on allowed tags already survive and are left alone, and only linked
    /// ids are kept — pages carry hundreds of unreferenced block ids.
    nonisolated static func preservingAnchorTargets(in html: String, allowedTags: String) -> String {
        let fragments = referencedFragments(in: html)
        guard !fragments.isEmpty else { return html }

        let pattern = #"<(?!(?:\#(allowedTags))\b)[a-zA-Z][a-zA-Z0-9]*\b[^>]*?\bid\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let nsHTML = html as NSString
        var result = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        // Splice from the end so earlier match ranges stay valid.
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard fragments.contains(id) else { continue }
            result = result.replacingCharacters(in: match.range, with: "<a id=\"\(id)\"></a>") as NSString
        }
        return result as String
    }

    /// Fragment identifiers the document links to, without the leading `#`.
    private nonisolated static func referencedFragments(in html: String) -> Set<String> {
        let pattern = #"href\s*=\s*["']#([^"'\s>]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsHTML = html as NSString
        var fragments = Set<String>()
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let fragment = nsHTML.substring(with: match.range(at: 1))
            fragments.insert(fragment)
            if let decoded = fragment.removingPercentEncoding { fragments.insert(decoded) }
        }
        return fragments
    }

    /// Rewrite link targets so the archive resolves them the way the live page
    /// did. Saved HTML loads from a `file://` URL, so a site-relative
    /// `href="/team"` would resolve against the archive folder and dead-end.
    /// Fragments and links that already carry a scheme are left untouched.
    nonisolated static func absolutizingLinks(in html: String, baseURL: URL) -> String {
        // Both quote styles appear in the wild, and a missed one is a dead link.
        [#"""#, "'"].reduce(html) { absolutizingLinks(in: $0, baseURL: baseURL, quote: $1) }
    }

    private nonisolated static func absolutizingLinks(in html: String, baseURL: URL, quote: String) -> String {
        let pattern = #"(<a\b[^>]*\bhref\s*=\s*\#(quote))([^\#(quote)]*)(\#(quote))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let nsHTML = html as NSString
        var result = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        for match in matches.reversed() where match.numberOfRanges >= 4 {
            let hrefRange = match.range(at: 2)
            let href = nsHTML.substring(with: hrefRange)
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard URL(string: trimmed)?.scheme == nil else { continue }
            guard let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else { continue }
            result = result.replacingCharacters(in: hrefRange, with: absolute.absoluteString) as NSString
        }
        return result as String
    }

    /// Base URL relative links resolve against: the page's own `<base href>`
    /// when it declares one, otherwise the URL the page was fetched from.
    nonisolated static func linkResolutionBase(forRawHTML html: String, pageURL: URL) -> URL {
        guard let declared = firstCapture(#"<base\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#, in: html),
              let resolved = URL(string: declared.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: pageURL)?.absoluteURL,
              resolved.scheme != nil else {
            return pageURL
        }
        return resolved
    }

    // MARK: - Substack Post Extraction

    /// Extract the clean post slice from Substack-style pages: the post title,
    /// subtitle, and the `available-content` body container, skipping the byline
    /// chrome (avatar, author link, date, like count, share/restack toolbar).
    /// Returns nil when the page doesn't use that structure.
    nonisolated static func substackPostHTML(from html: String) -> String? {
        guard let availableContent = innerHTMLOfDiv(withClassContaining: "available-content", in: html) else {
            return nil
        }

        // Current Substack pages put the actual authored post in `body markup`.
        // Prefer that narrower structural boundary so subscription/paywall UI
        // added beside it inside `available-content` is not archived as prose.
        let body = innerHTMLOfDiv(withClassContaining: "body markup", in: availableContent)
            ?? availableContent

        var header = ""
        if let title = firstCapture(
            #"<h1\b[^>]*class=[\"'][^\"']*\bpost-title\b[^\"']*[\"'][^>]*>([\s\S]*?)</h1>"#,
            in: html
        ) {
            header += "<h1>\(title)</h1>\n"
        }
        if let subtitle = firstCapture(
            #"<h3\b[^>]*class=[\"'][^\"']*\bsubtitle\b[^\"']*[\"'][^>]*>([\s\S]*?)</h3>"#,
            in: html
        ) {
            header += "<h3>\(subtitle)</h3>\n"
        }
        return header + body
    }

    /// First capture group of `pattern` in `html`, case-insensitive.
    private nonisolated static func firstCapture(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return nsHTML.substring(with: match.range(at: 1))
    }

    /// Inner HTML of the first `<div>` whose class attribute contains `marker`.
    /// Divs nest, so the closing tag is found by depth counting rather than a
    /// non-greedy regex (which would stop at the first inner `</div>`).
    private nonisolated static func innerHTMLOfDiv(withClassContaining marker: String, in html: String) -> String? {
        innerHTMLOfElement(
            named: "div",
            openPattern: #"<div\b[^>]*class=[\"'][^\"']*\#(marker)[^\"']*[\"'][^>]*>"#,
            in: html
        )
    }

    private nonisolated static func innerHTMLOfElement(
        named element: String,
        openPattern: String,
        in html: String
    ) -> String? {
        guard let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
              let tokenRegex = try? NSRegularExpression(
                pattern: #"<\#(element)\b|</\#(element)>"#,
                options: [.caseInsensitive]
              ) else { return nil }
        let nsHTML = html as NSString
        guard let open = openRegex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else {
            return nil
        }
        let contentStart = open.range.location + open.range.length
        var depth = 1
        var innerHTML: String?
        let searchRange = NSRange(location: contentStart, length: nsHTML.length - contentStart)
        tokenRegex.enumerateMatches(in: html, range: searchRange) { match, _, stop in
            guard let match else { return }
            if nsHTML.substring(with: match.range).hasPrefix("</") {
                depth -= 1
                if depth == 0 {
                    innerHTML = nsHTML.substring(
                        with: NSRange(location: contentStart, length: match.range.location - contentStart)
                    )
                    stop.pointee = true
                }
            } else {
                depth += 1
            }
        }
        return innerHTML
    }

    /// Find all <img> tags in HTML, download images to disk, rewrite src to local relative paths.
    private func downloadAndRewriteImages(in html: String, baseURL: URL, imagesDir: String) async -> String {
        var result = html

        // Match img tags and capture src attribute
        let imgPattern = #"<img\b[^>]*\bsrc\s*=\s*"([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) else {
            return html
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        // Collect unique image URLs
        var imageURLs: [(original: String, resolved: URL)] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let srcRange = match.range(at: 1)
            let src = nsHTML.substring(with: srcRange)
            guard !seen.contains(src) else { continue }
            seen.insert(src)

            // Skip data URIs
            if src.hasPrefix("data:") { continue }

            // Resolve relative URLs against the page base URL
            if let resolved = URL(string: src, relativeTo: baseURL)?.absoluteURL {
                imageURLs.append((original: src, resolved: resolved))
            }
        }

        // Download every image with bounded concurrency. Limiting active requests
        // protects the network without dropping images from long articles.
        let downloadImage: @Sendable (Int, String, URL) async -> (String, String?) = { [session] idx, original, resolved in
            do {
                var req = URLRequest(url: resolved)
                req.timeoutInterval = 10
                let (data, response) = try await session.data(for: req)

                guard let httpResp = response as? HTTPURLResponse,
                      (200...299).contains(httpResp.statusCode),
                      data.count > 100 else {
                    return (original, nil)
                }

                let ext = Self.imageExtension(
                    contentType: httpResp.value(forHTTPHeaderField: "Content-Type"),
                    url: resolved
                )
                let filename = "img\(idx).\(ext)"
                let destPath = (imagesDir as NSString).appendingPathComponent(filename)
                try data.write(to: URL(fileURLWithPath: destPath))
                return (original, "images/\(filename)")
            } catch {
                return (original, nil)
            }
        }

        await withTaskGroup(of: (String, String?).self) { group in
            let concurrencyLimit = 10

            let initialCount = min(concurrencyLimit, imageURLs.count)
            for idx in 0..<initialCount {
                let entry = imageURLs[idx]
                group.addTask {
                    await downloadImage(idx, entry.original, entry.resolved)
                }
            }

            var nextIndex = initialCount
            while let (originalSrc, localPath) = await group.next() {
                if let localPath {
                    result = result.replacingOccurrences(of: originalSrc, with: localPath)
                }
                if nextIndex < imageURLs.count {
                    let idx = nextIndex
                    let entry = imageURLs[idx]
                    group.addTask {
                        await downloadImage(idx, entry.original, entry.resolved)
                    }
                    nextIndex += 1
                }
            }
        }

        return result
    }

    /// Determine appropriate file extension for a downloaded image.
    private static func imageExtension(contentType: String?, url: URL) -> String {
        if let ct = contentType?.lowercased() {
            if ct.contains("png") { return "png" }
            if ct.contains("gif") { return "gif" }
            if ct.contains("webp") { return "webp" }
            if ct.contains("svg") { return "svg" }
            if ct.contains("avif") { return "avif" }
            if ct.contains("jpeg") || ct.contains("jpg") { return "jpg" }
        }
        let pathExt = url.pathExtension.lowercased()
        if ["png", "gif", "webp", "svg", "avif", "jpg", "jpeg"].contains(pathExt) {
            return pathExt == "jpeg" ? "jpg" : pathExt
        }
        return "jpg" // default
    }
}

extension SourceService.StagedArticleRefresh {
    /// A capture that brought text and no page to archive, as a Google export
    /// does, staged under a folder of its own. Tests stand in for the browser
    /// with it; discarding or committing it touches no source's archive.
    init(textOnly article: SourceService.ArchivedArticle, url: String, sourceID: String) {
        self.init(
            article: SourceService.ArchivedArticle(
                plainText: article.plainText,
                localHTMLPath: nil,
                pageTitle: article.pageTitle,
                pageAuthor: article.pageAuthor,
                titleEvidence: article.titleEvidence
            ),
            sourceURL: url,
            stagingSourceID: Self.newStagingID(for: sourceID),
            previousCachedText: nil
        )
    }
}
