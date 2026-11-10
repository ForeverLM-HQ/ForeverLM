import Foundation
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "PaperService")

/// Paper-specific services: PDF URL resolution, metadata lookup, DOI extraction,
/// and open-access discovery for academic papers and preprints.
enum PaperService {

    /// Transport/decode failure distinct from a genuine empty result, so callers can
    /// tell "offline / HTTP error / rate-limited" apart from "no matching paper".
    private enum FetchError: Error {
        case badStatus(Int)
        case decodeFailed
        /// The address answered with a PDF, not a page to read.
        case servedPDF
    }

    struct PaperPageMetadata {
        let title: String?
        let authorsDisplay: String?
        let journal: String?
        let year: String?
        let doi: String?
        let pdfURL: String?
    }

    private static let browserLikeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    private struct WebPageFetchResult {
        let html: String
        let finalURL: URL
    }

    // MARK: - PDF URL Resolution

    /// Convert a paper's abstract/landing page URL to its direct PDF download URL.
    /// Only handles cases where a simple URL transformation is reliable — for everything
    /// else, the caller falls back to `extractPDFURLFromWebPage()`.
    static func paperPDFURL(from urlString: String) -> String? {
        let lower = urlString.lowercased()

        // Already a direct PDF link
        if isDirectPDFURL(urlString) { return urlString }

        // arXiv: use export.arxiv.org for programmatic PDF downloads (faster, no throttle)
        // arxiv.org/abs/XXXX → export.arxiv.org/pdf/XXXX.pdf
        if lower.contains("arxiv.org/abs/") {
            var pdfURL = urlString.replacingOccurrences(of: "/abs/", with: "/pdf/")
            pdfURL = pdfURL.replacingOccurrences(of: "://arxiv.org", with: "://export.arxiv.org")
            if !pdfURL.hasSuffix(".pdf") { pdfURL += ".pdf" }
            return pdfURL
        }

        // arXiv: arxiv.org/pdf/XXXX (without .pdf extension) → export.arxiv.org/pdf/XXXX.pdf
        if lower.contains("arxiv.org/pdf/") {
            var base = urlString
            if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
            if let hashIdx = base.firstIndex(of: "#") { base = String(base[..<hashIdx]) }
            while base.hasSuffix("/") { base = String(base.dropLast()) }
            if !base.lowercased().hasSuffix(".pdf") { base += ".pdf" }
            base = base.replacingOccurrences(of: "://arxiv.org", with: "://export.arxiv.org")
            return base
        }

        // arXiv: arxiv.org/html/XXXX → export.arxiv.org/pdf/XXXX.pdf
        if lower.contains("arxiv.org/html/") {
            var pdfURL = urlString.replacingOccurrences(of: "/html/", with: "/pdf/")
            if let qIdx = pdfURL.firstIndex(of: "?") { pdfURL = String(pdfURL[..<qIdx]) }
            if let hashIdx = pdfURL.firstIndex(of: "#") { pdfURL = String(pdfURL[..<hashIdx]) }
            while pdfURL.hasSuffix("/") { pdfURL = String(pdfURL.dropLast()) }
            if !pdfURL.lowercased().hasSuffix(".pdf") { pdfURL += ".pdf" }
            pdfURL = pdfURL.replacingOccurrences(of: "://arxiv.org", with: "://export.arxiv.org")
            return pdfURL
        }

        // OpenReview: openreview.net/forum?id=X → openreview.net/pdf?id=X
        if lower.contains("openreview.net/forum") {
            return urlString.replacingOccurrences(of: "/forum?", with: "/pdf?")
        }
        // OpenReview: already a PDF URL
        if lower.contains("openreview.net/pdf") {
            return urlString
        }

        // DOI links for bioRxiv/medRxiv: doi.org/10.1101/... or
        // doi.org/10.64898/... → bioRxiv PDF URL.
        if lower.contains("doi.org/10.1101/") || lower.contains("doi.org/10.64898/") {
            let prefix = lower.contains("doi.org/10.64898/") ? "10.64898/" : "10.1101/"
            if let range = urlString.range(of: prefix) {
                var doi = String(urlString[range.lowerBound...])
                // Strip query params and fragments
                if let qIdx = doi.firstIndex(of: "?") { doi = String(doi[..<qIdx]) }
                if let hashIdx = doi.firstIndex(of: "#") { doi = String(doi[..<hashIdx]) }
                while doi.hasSuffix("/") { doi = String(doi.dropLast()) }
                return "https://www.biorxiv.org/content/\(doi).full.pdf"
            }
        }

        // DOI links for arXiv: doi.org/10.48550/arXiv.XXXX → arxiv PDF URL
        if lower.contains("doi.org/10.48550/arxiv.") {
            if let range = lower.range(of: "arxiv.") {
                var id = String(urlString[range.upperBound...])
                if let qIdx = id.firstIndex(of: "?") { id = String(id[..<qIdx]) }
                if let hashIdx = id.firstIndex(of: "#") { id = String(id[..<hashIdx]) }
                return "https://export.arxiv.org/pdf/\(id).pdf"
            }
        }

        // bioRxiv / medRxiv: normalize URL then append .full.pdf
        if lower.contains("biorxiv.org/content/") || lower.contains("medrxiv.org/content/") {
            var base = urlString
            // Strip query params and fragments
            if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
            if let hashIdx = base.firstIndex(of: "#") { base = String(base[..<hashIdx]) }
            // Strip trailing slashes
            while base.hasSuffix("/") { base = String(base.dropLast()) }
            // Strip known suffixes (.full.pdf already handled above, .full, .abstract)
            for suffix in [".full", ".abstract"] {
                if base.lowercased().hasSuffix(suffix) {
                    base = String(base.dropLast(suffix.count))
                    break
                }
            }
            return base + ".full.pdf"
        }

        // Nature's news, editorials, and comment pieces share the journal's
        // URL shape but have no PDF to resolve; they are articles, not papers.
        if isNatureNewsURL(urlString) { return nil }

        // Nature: nature.com/articles/X → nature.com/articles/X.pdf
        if lower.contains("nature.com/articles/") {
            var base = urlString
            if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
            if let hashIdx = base.firstIndex(of: "#") { base = String(base[..<hashIdx]) }
            while base.hasSuffix("/") { base = String(base.dropLast()) }
            if !base.lowercased().hasSuffix(".pdf") {
                return base + ".pdf"
            }
            return base
        }

        // DOI links for Nature: doi.org/10.1038/... → nature.com/articles/X.pdf
        if lower.contains("doi.org/10.1038/") {
            if let range = urlString.range(of: "10.1038/") {
                var articleId = String(urlString[range.upperBound...])
                if let qIdx = articleId.firstIndex(of: "?") { articleId = String(articleId[..<qIdx]) }
                if let hashIdx = articleId.firstIndex(of: "#") { articleId = String(articleId[..<hashIdx]) }
                return "https://www.nature.com/articles/\(articleId).pdf"
            }
        }

        // Europe PMC's rendered PDF (`europepmc.org/articles/PMC…?pdf=render`,
        // `ptpmcrender.fcgi?accid=PMC…`) is a PDF address without a `.pdf`.
        if isEuropePMCRenderedPDFURL(urlString) { return urlString }

        // PMC: the short `…/articles/PMCXXXX/pdf/` link is NCBI's PDF route, a
        // 301 to the file (see `ncbiPMCPDFURL(pmcid:)`). The article page itself
        // stays nil here: the reader shows a PMC paper's page, and the PDF
        // resolvers turn the page into the route with `ncbiPMCPDFURL(forArticleURL:)`.
        if lower.contains("ncbi.nlm.nih.gov/pmc/articles/") || lower.contains("pmc.ncbi.nlm.nih.gov/articles/") {
            if isNCBIPMCShortPDFRoute(urlString), let pmcid = extractPMCID(from: urlString) {
                return ncbiPMCPDFURL(pmcid: pmcid)
            }
            return nil
        }

        // ScienceDirect: article landing pages use a PII identifier. The PDF
        // endpoint may require an authenticated ScienceDirect/WebKit session,
        // but the URL itself is deterministic from the PII.
        if let scienceDirectPDF = ScienceDirectService.pdfURL(from: urlString) {
            return scienceDirectPDF
        }

        // Cell Press (cell.com): use /action/showPdf?pii=XXX for direct PDF bytes.
        // The /pdf/ endpoint serves an ePDF HTML viewer, not raw PDF.
        // The citation_pdf_url meta tag also points to the HTML viewer, so this must stay hardcoded.
        if lower.contains("cell.com/") && (lower.contains("/fulltext/") || lower.contains("/abstract/") || lower.contains("/pdf/")) {
            var base = urlString
            if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
            if let hashIdx = base.firstIndex(of: "#") { base = String(base[..<hashIdx]) }
            let pii = (base as NSString).lastPathComponent
                .replacingOccurrences(of: ".pdf", with: "")
            if let components = URLComponents(string: base),
               let scheme = components.scheme, let host = components.host {
                return "\(scheme)://\(host)/action/showPdf?pii=\(pii)"
            }
        }

        // Generic Atypon/Literatum: /doi/full/10.XXXX and /doi/abs/10.XXXX
        // landing pages map to /doi/pdf/10.XXXX. Covers many publishers
        // (NEJM, Wiley, Taylor & Francis, SAGE, PNAS, Science, ACS, etc.).
        // /doi/reader/ and /doi/epdf/ are the publisher's PDF viewer pages
        // around the same file: Science's PDF button is /doi/reader/<doi>,
        // which lands on /doi/epdf/<doi>.
        let doiPattern = #"/doi/(?:full/|abs/|pdf/|epdf/|reader/)?(10\.\d{4,}/[^\s?#]+)"#
        if let regex = try? NSRegularExpression(pattern: doiPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
           let matchedRange = Range(match.range(at: 0), in: urlString),
           let doiRange = Range(match.range(at: 1), in: urlString) {
            let prefix = String(urlString[..<matchedRange.lowerBound])
            var doi = String(urlString[doiRange])
            while doi.hasSuffix("/") { doi = String(doi.dropLast()) }
            return "\(prefix)/doi/pdf/\(doi)"
        }

        // For everything else, return nil — the caller will fall back to
        // extractPDFURLFromWebPage() which fetches the page and reads the
        // citation_pdf_url meta tag (standard across academic publishers).
        return nil
    }

    /// True when the URL path points at a PDF, even if the download URL carries
    /// query parameters or a fragment that are required by the server.
    static func isDirectPDFURL(_ urlString: String) -> Bool {
        if let components = URLComponents(string: urlString) {
            return components.percentEncodedPath.lowercased().hasSuffix(".pdf")
                || components.path.lowercased().hasSuffix(".pdf")
        }
        let stripped = urlString
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return stripped.lowercased().hasSuffix(".pdf")
    }

    /// Markers of a PDF that belongs to a paper without being the paper:
    /// supplementary information, source data, a reporting summary. Nature
    /// files these under `/articles/<id>/MediaObjects/…_MOESM1_ESM.pdf`; other
    /// publishers under `/suppl/`, `supplementary`, `supplement`. Lowercased
    /// path and query are searched, so the marker can sit in either.
    static let supplementaryPDFURLMarkers = [
        "/mediaobjects/", "moesm", "_esm.", "_esm_", "/suppl/", "/suppl_", "supplement",
        "supplementary", "reporting-summary", "reporting_summary", "reportingsummary",
        "source-data", "source_data", "sourcedata", "/sd", "peer-review", "peer_review",
    ]

    /// True when `urlString` points at a paper's supplementary file rather
    /// than the paper. On 2026-09-06 the reader's Download PDF, offered the
    /// Nature page of a paper the learner had no access to, clicked the first
    /// `.pdf` link on it — the four-page Reporting Summary — and that file was
    /// saved as the paper's PDF, with metadata extracted from it. A file like
    /// this is never the paper, whatever the page offers.
    static func isSupplementaryPDFURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        let pathAndQuery: String
        if let components = URLComponents(string: urlString) {
            pathAndQuery = (components.path + "?" + (components.query ?? "")).lowercased()
        } else {
            pathAndQuery = lower
        }
        return supplementaryPDFURLMarkers.contains { marker in
            if marker == "/sd" {
                // Springer's `/sd/…` supplementary path segment, not a word that
                // merely starts with those letters.
                return pathAndQuery.contains("/sd/")
            }
            return pathAndQuery.contains(marker)
        }
    }

    /// The same markers for a page script, as one JavaScript regular
    /// expression source. The reader's link pickers run in the page and must
    /// skip the same files this predicate refuses afterwards.
    static let supplementaryPDFURLJavaScriptPattern =
        "\\/mediaobjects\\/|moesm|_esm[._]|\\/suppl[\\/_]|supplement|reporting[-_]?summary|source[-_]?data|\\/sd\\/|peer[-_]review"

    /// Convert a paper PDF URL back to its abstract/landing page URL for title extraction.
    /// Returns nil if not a recognized pattern — caller should use the original URL.
    static func paperAbstractURL(from urlString: String) -> String? {
        let lower = urlString.lowercased()

        // arXiv: arxiv.org/pdf/XXXX.pdf → arxiv.org/abs/XXXX
        if lower.contains("arxiv.org/pdf/") {
            var abs = urlString.replacingOccurrences(of: "/pdf/", with: "/abs/")
            // Strip .pdf extension
            if abs.lowercased().hasSuffix(".pdf") { abs = String(abs.dropLast(4)) }
            return abs
        }

        // bioRxiv / medRxiv: convert to canonical abstract page URL
        if lower.contains("biorxiv.org") || lower.contains("medrxiv.org") {
            let host = lower.contains("medrxiv.org") ? "www.medrxiv.org" : "www.biorxiv.org"

            // Extract the DOI-like ID (e.g., "2022.03.16.484643") from various URL patterns:
            // - /content/10.1101/2022.03.16.484643v1.full.pdf
            // - /content/biorxiv/early/2025/02/15/2022.03.16.484643.full.pdf
            // The DOI portion matches: YYYY.MM.DD.NNNNNN (optionally with vN suffix)
            let doiPattern = #"(\d{4}\.\d{2}\.\d{2}\.\d+)(v\d+)?"#
            if let regex = try? NSRegularExpression(pattern: doiPattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                let doiSuffix = String(urlString[range])
                var version = ""
                if let vRange = Range(match.range(at: 2), in: urlString) {
                    version = String(urlString[vRange])
                }
                return "https://\(host)/content/10.1101/\(doiSuffix)\(version)"
            }

            // Fallback: strip PDF suffixes from URL
            var base = urlString
            if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
            if base.lowercased().hasSuffix(".full.pdf") {
                base = String(base.dropLast(9))
            } else if base.lowercased().hasSuffix(".pdf") {
                base = String(base.dropLast(4))
            }
            if base.lowercased().hasSuffix(".full") {
                base = String(base.dropLast(5))
            }
            return base
        }

        if let scienceDirectAbstract = ScienceDirectService.abstractURL(from: urlString) {
            return scienceDirectAbstract
        }

        return nil
    }

    /// Fetch the paper landing page and extract scholarly metadata from its HTML head.
    static func fetchPaperPageMetadata(at urlString: String) async -> PaperPageMetadata? {
        let fetchURL = paperAbstractURL(from: urlString) ?? urlString
        guard let url = URL(string: fetchURL) else { return nil }

        let page: WebPageFetchResult
        do {
            page = try await fetchWebPage(at: url, allowedStatusCodes: 200...399)
        } catch {
            logger.error("fetchPaperPageMetadata: transport/HTTP failure for \(fetchURL, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        // The page that answered, not the one asked for: a DOI resolves through
        // redirects to the publisher's host, and it is that host's name a
        // holding page may wear as its title.
        return extractPaperPageMetadata(from: page.html, url: page.finalURL.absoluteString)
    }

    // MARK: - Web Page PDF Extraction

    /// Fetch a web page and extract an explicitly advertised PDF URL:
    /// 1. `citation_pdf_url` meta tag (Google Scholar standard, covers most academic publishers)
    /// 2. `<link rel="alternate" type="application/pdf">` in <head>
    /// Ambiguous page-link choice is handled by the AI browser agent, not local keyword scoring.
    static func extractPDFURLFromWebPage(at urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        let page: WebPageFetchResult
        do {
            page = try await fetchWebPage(at: url, allowedStatusCodes: 200...299)
        } catch FetchError.servedPDF {
            // The address is the file itself: a repository's `…/document`
            // (HAL), a download endpoint without `.pdf` in its path. Open-access
            // indexes list such addresses as a location's PDF, and scanning
            // them for a link found nothing, so the candidate was dropped.
            return urlString
        } catch {
            logger.error("extractPDFURLFromWebPage: transport/HTTP failure for \(urlString, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        return extractPDFURL(fromHTML: page.html, relativeTo: page.finalURL)
    }

    /// Fetch a web page, propagating transport errors (offline, timeout, TLS) and
    /// surfacing HTTP/decode failures via `FetchError` so callers can distinguish a
    /// network failure from a page that genuinely advertises no result.
    private static func fetchWebPage(at url: URL, allowedStatusCodes: ClosedRange<Int>) async throws -> WebPageFetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            SharedWebKit.desktopSafariUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await browserLikeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.decodeFailed }
        guard allowedStatusCodes.contains(http.statusCode) else { throw FetchError.badStatus(http.statusCode) }
        if SourceService.looksLikePDFData(data) { throw FetchError.servedPDF }
        guard let html = String(data: data, encoding: .utf8) else { throw FetchError.decodeFailed }

        return WebPageFetchResult(html: html, finalURL: response.url ?? url)
    }

    /// Perform a JSON GET request, propagating transport errors (offline, timeout,
    /// TLS) so a network failure is distinguishable from a genuine "no result".
    /// Returns nil for a non-200 response or a body that is not a JSON object.
    private static func fetchJSONObject(from url: URL, userAgent: String? = nil, timeout: TimeInterval = 15) async throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Build a URL from a base and query items, letting URLComponents percent-encode
    /// the values. `.urlQueryAllowed` does NOT escape `&`, `+`, or `=`, so building
    /// query strings by hand corrupts any title/author/DOI containing them; here we
    /// additionally escape those characters so the query cannot be split or mangled.
    private static func makeQueryURL(_ base: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        components.percentEncodedQueryItems = queryItems.map { item in
            URLQueryItem(
                name: item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name,
                value: item.value?.addingPercentEncoding(withAllowedCharacters: allowed)
            )
        }
        return components.url
    }

    static func extractPDFURL(fromHTML html: String, relativeTo url: URL) -> String? {
        // Only scan the <head> section for meta/link tags
        let head: String
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            head = String(html[html.startIndex..<headEnd.upperBound])
        } else {
            head = html
        }

        // A supplementary file advertised where the paper's PDF would be is
        // not the paper; better no link than that one.
        func unlessSupplementary(_ candidate: String?) -> String? {
            guard let candidate, !isSupplementaryPDFURL(candidate) else { return nil }
            return candidate
        }

        // 1) Publisher article-download buttons. Nature can advertise a stale
        // citation_pdf_url while the real in-press PDF uses *_reference.pdf.
        if let pdfURL = unlessSupplementary(extractArticlePDFLink(fromHTML: html, relativeTo: url)) {
            return pdfURL
        }

        // 2) citation_pdf_url — the de facto standard for scholarly pages
        if let pdfURL = extractPaperPageMetadata(from: head)?.pdfURL,
           let resolved = unlessSupplementary(resolveURL(pdfURL, relativeTo: url)) {
            return resolved
        }

        // 2b) A publisher's own PDF viewer page. JCI Insight answers
        // `/articles/view/<id>/pdf` with HTML: a Download PDF form whose
        // action is `…/pdf/render.pdf`, and an iframe a script points at the
        // same file (the page itself carries no citation_pdf_url). The file
        // behind that address is the paper; the page around it is not.
        if let pdfURL = unlessSupplementary(extractEmbeddedViewerPDFLink(fromHTML: html, relativeTo: url)) {
            return pdfURL
        }

        // 2c) Atypon's cloud reader. Science's PDF button is `/doi/reader/<doi>`,
        // which lands on `/doi/epdf/<doi>`: an HTML page around a PDF renderer,
        // with no citation_pdf_url, no frame and no form — the file arrives by
        // script from a signed, short-lived `/doi/pdfdirect/` address. The
        // page's own Download control is `<a href="/doi/pdf/<doi>?download=true">`,
        // and a viewer page that lacks even that still says which paper it
        // shows in its address (2026-09-21, "That link opened a page, not a PDF").
        if let pdfURL = unlessSupplementary(extractAtyponReaderPDFLink(fromHTML: html, relativeTo: url)) {
            return pdfURL
        }

        // 3) <link rel="alternate" type="application/pdf">
        for link in HTMLTagAttributes.tags(named: "link", in: head) {
            guard link["type"].map(decodeHTML)?.caseInsensitiveCompare("application/pdf") == .orderedSame,
                  let href = link["href"].map(decodeHTML), !href.isEmpty,
                  let resolved = unlessSupplementary(resolveURL(href, relativeTo: url)) else { continue }
            return resolved
        }

        return nil
    }

    /// The PDF behind an Atypon (Literatum) viewer page: the page's own
    /// `/doi/pdf/<doi>` Download control on the same host, or, when the page
    /// carries none, the `/doi/pdf/` address derived from the viewer's own
    /// `/doi/epdf/` or `/doi/reader/` address. Any other page yields nothing.
    private static func extractAtyponReaderPDFLink(fromHTML html: String, relativeTo url: URL) -> String? {
        for anchor in HTMLTagAttributes.tags(named: "a", in: html) {
            guard let href = anchor["href"].map(decodeHTML) else { continue }
            let resolved = resolveURL(href, relativeTo: url)
            guard let candidate = URL(string: resolved),
                  candidate.host?.lowercased() == url.host?.lowercased(),
                  candidate.path.lowercased().contains("/doi/pdf/") else { continue }
            return resolved
        }
        let path = url.path.lowercased()
        guard path.contains("/doi/epdf/") || path.contains("/doi/reader/") else { return nil }
        return paperPDFURL(from: url.absoluteString)
    }

    private static func extractArticlePDFLink(fromHTML html: String, relativeTo url: URL) -> String? {
        for anchor in HTMLTagAttributes.tags(named: "a", in: html) {
            func says(_ attribute: String, _ value: String) -> Bool {
                anchor[attribute].map(decodeHTML)?.caseInsensitiveCompare(value) == .orderedSame
            }
            let isArticleDownload = says("data-article-pdf", "true")
                || says("data-test", "download-pdf")
                || says("data-readcube-pdf-url", "true")
            guard isArticleDownload,
                  let href = anchor["href"].map(decodeHTML),
                  href.lowercased().contains(".pdf") else { continue }
            return resolveURL(href, relativeTo: url)
        }
        return nil
    }

    /// The PDF a publisher's viewer page embeds: the `action` of a form whose
    /// submit downloads it, the `src` of an `<iframe>`, `<embed>` or
    /// `<object>` that displays it, or the address a page script assigns to
    /// such a frame (`document.getElementById('asset_source').src = "…pdf"`).
    /// Only an address whose path ends in `.pdf` counts; a page can embed
    /// many frames and none of the others is the paper.
    static func extractEmbeddedViewerPDFLink(fromHTML html: String, relativeTo url: URL) -> String? {
        let patterns = [
            #"<form\b[^>]*\baction\s*=\s*["']([^"']+)["']"#,
            #"<(?:iframe|embed|object)\b[^>]*\b(?:src|data)\s*=\s*["']([^"']+)["']"#,
            #"\.src\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let candidate = decodeHTML(String(html[range]))
                guard isDirectPDFURL(candidate), !isSupplementaryPDFURL(candidate) else { continue }
                return resolveURL(candidate, relativeTo: url)
            }
        }
        return nil
    }

    /// True when a downloaded file is a web page rather than a document: a
    /// doctype or an `<html` tag within its first two kilobytes. What tells a
    /// publisher's viewer page, saved by a download that expected the PDF,
    /// from the PDF.
    static func looksLikeHTMLDocument(_ text: String) -> Bool {
        let head = text.prefix(2048).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    private static func pageAdvertisesOpenAccessPDF(at urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let page: WebPageFetchResult
        do {
            page = try await fetchWebPage(at: url, allowedStatusCodes: 200...399)
        } catch {
            logger.error("pageAdvertisesOpenAccessPDF: transport/HTTP failure for \(urlString, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        guard extractPDFURL(fromHTML: page.html, relativeTo: page.finalURL) != nil else { return false }

        let lower = page.html.lowercased()
        return lower.contains(#""isaccessibleforfree":true"#)
            || lower.contains(#""copyright":{"open":true"#)
            || lower.contains("data-test=\"open-access\"")
            || lower.contains("creative commons")
    }

    /// Metadata belongs in the document head. Restrict every metadata lookup to
    /// that bounded region before reading it: modern Next.js pages can append
    /// megabytes of serialized application state to the body, and an absent
    /// meta field otherwise made each lookup scan that entire payload. The
    /// Contrary anti-aging report exposed this as a background core spinning
    /// for minutes while its source row remained in Fetching.
    private static func metadataScanRegion(from html: String) -> String {
        let maximumCharacters = 256 * 1_024
        let limit = html.index(
            html.startIndex,
            offsetBy: maximumCharacters,
            limitedBy: html.endIndex
        ) ?? html.endIndex
        let prefix = html[..<limit]
        if let headEnd = prefix.range(of: "</head>", options: .caseInsensitive)?.upperBound {
            return String(prefix[..<headEnd])
        }
        // Fragment fixtures and malformed pages may omit <head>. They still get
        // the same hard bound, so metadata extraction has predictable cost.
        return String(prefix)
    }

    /// The `<meta>` tags of a page's head, read once per page by the tag
    /// reader every head reader shares (`HTMLTagAttributes`): a value is read
    /// inside its own tag, in either attribute order. A lookup that spanned
    /// tags is how two articles stored a kilobyte of head as their author.
    private struct HeadMetaTags {
        let tags: [HTMLTagAttributes.Tag]

        /// `html` is bounded to the head first (`metadataScanRegion`).
        init(html: String) {
            tags = HTMLTagAttributes.tags(named: "meta", in: PaperService.metadataScanRegion(from: html))
        }

        /// The decoded `content` of every `<meta>` whose `attribute` is
        /// `value`, matched case-insensitively, in document order.
        func contents(attribute: String, value: String) -> [String] {
            tags.compactMap { tag in
                guard let key = tag[attribute],
                      PaperService.decodeHTML(key).caseInsensitiveCompare(value) == .orderedSame,
                      let raw = tag["content"] else { return nil }
                let content = PaperService.decodeHTML(raw)
                return content.isEmpty ? nil : content
            }
        }

        func content(name: String) -> String? {
            contents(attribute: "name", value: name).first
        }

        func content(property: String) -> String? {
            contents(attribute: "property", value: property).first
        }

        /// The page announces it is on its way elsewhere
        /// (`<meta http-equiv="refresh">`).
        var announcesRefresh: Bool {
            tags.contains { tag in
                tag["http-equiv"].map(PaperService.decodeHTML)?
                    .caseInsensitiveCompare("refresh") == .orderedSame
            }
        }
    }

    private static func decodeHTML(_ text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&ndash;", with: "\u{2013}")
            .replacingOccurrences(of: "&mdash;", with: "\u{2014}")
            .replacingOccurrences(of: "&lsquo;", with: "\u{2018}")
            .replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
            .replacingOccurrences(of: "&hellip;", with: "\u{2026}")
        // Numeric references (`&#x27;`, `&#8217;`) are how frameworks escape
        // punctuation in attributes; a title read through them must not keep
        // the code.
        if decoded.contains("&#"),
           let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: decoded),
                      let inner = Range(match.range(at: 1), in: decoded) else { continue }
                let code = decoded[inner]
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(code.dropFirst(), radix: 16)
                    : UInt32(code)
                guard let value, let scalar = Unicode.Scalar(value) else { continue }
                decoded.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return decoded
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorsDisplay(from rawAuthors: [String]) -> String? {
        let authors = rawAuthors.compactMap(Self.normalizedAuthorDisplayName)
        guard !authors.isEmpty else { return nil }
        return StudioArticle.canonicalPaperAuthor(authors.joined(separator: "; "))
    }

    private static func normalizedAuthorDisplayName(_ raw: String) -> String? {
        let trimmed = decodeHTML(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func crossrefAuthorName(from author: [String: Any]) -> String? {
        if let name = author["name"] as? String {
            return Self.normalizedAuthorDisplayName(name)
        }
        let given = (author["given"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let family = (author["family"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = [given, family]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
        return Self.normalizedAuthorDisplayName(joined)
    }

    private static func crossrefAuthorsDisplay(from rawAuthors: [[String: Any]]) -> String? {
        Self.authorsDisplay(from: rawAuthors.compactMap(Self.crossrefAuthorName))
    }

    private static func commaSeparatedFamilyAuthorDisplay(from raw: String) -> String? {
        let authors = raw.components(separatedBy: ";").compactMap(Self.normalizedAuthorDisplayName)
        return Self.authorsDisplay(from: authors)
    }

    private static func extractYear(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func normalizeExtractedDOI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let doi = extractDOI(from: trimmed) {
            return doi
        }
        return firstPrintedDOI(in: trimmed)
    }

    /// Resolve a possibly-relative URL against a base URL.
    private static func resolveURL(_ urlString: String, relativeTo base: URL) -> String {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return urlString
        }
        return URL(string: urlString, relativeTo: base)?.absoluteString ?? urlString
    }

    // MARK: - DOI Extraction

    /// Every DOI printed in `text`, in the order printed, each as printed.
    ///
    /// A DOI's suffix may hold parentheses: The Lancet's DOIs from before 2005
    /// read `10.1016/S0140-6736(04)16983-3`. The parsers here used to stop at
    /// the `(`, which leaves `10.1016/S0140-6736` — itself a DOI to OpenAlex,
    /// of a junk work whose open-access copy is an unrelated Lancet paper — so
    /// importing Luoma et al. (2004) on 2026-09-28 saved Ginsburg et al. (2017)
    /// in its place. A DOI runs to the next whitespace, quote or angle bracket;
    /// the sentence's closing punctuation comes off, and so does a `)` or `]`
    /// the DOI did not open, as `PDFReferenceEntries.doi(inReferenceEntry:)`
    /// reads a reference list.
    static func printedDOIs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"10\.\d{4,9}/[^\s"'<>]+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { trimmedPrintedDOI(String(text[$0])) }
        }
    }

    /// The first DOI printed in `text` (`printedDOIs(in:)`).
    static func firstPrintedDOI(in text: String) -> String? {
        printedDOIs(in: text).first
    }

    private static func trimmedPrintedDOI(_ run: String) -> String? {
        var doi = run
        func unopened(_ close: Character, _ open: Character) -> Bool {
            doi.filter { $0 == close }.count > doi.filter { $0 == open }.count
        }
        while let last = doi.last {
            if ".,;:".contains(last) {
                doi.removeLast()
            } else if last == ")", unopened(")", "(") {
                doi.removeLast()
            } else if last == "]", unopened("]", "[") {
                doi.removeLast()
            } else {
                break
            }
        }
        return doi.hasSuffix("/") ? nil : doi
    }

    /// Extract DOI from a paper URL (doi.org link, Nature, bioRxiv, etc.)
    static func extractDOI(from urlString: String) -> String? {
        let lower = urlString.lowercased()

        // Direct DOI link: https://doi.org/10.XXXX/...
        if lower.contains("doi.org/") {
            if let range = urlString.range(of: "doi.org/") {
                var doi = String(urlString[range.upperBound...])
                // Strip query/fragment
                if let q = doi.firstIndex(of: "?") { doi = String(doi[..<q]) }
                if let h = doi.firstIndex(of: "#") { doi = String(doi[..<h]) }
                return doi.isEmpty ? nil : doi
            }
        }

        // Nature: nature.com/articles/XXXXXX → DOI is 10.1038/XXXXXX
        if lower.contains("nature.com/articles/") {
            if let range = urlString.range(of: "nature.com/articles/") {
                var articleId = String(urlString[range.upperBound...])
                if let q = articleId.firstIndex(of: "?") { articleId = String(articleId[..<q]) }
                if articleId.hasSuffix(".pdf") { articleId = String(articleId.dropLast(4)) }
                return articleId.isEmpty ? nil : "10.1038/\(articleId)"
            }
        }

        // bioRxiv / medRxiv content pages → DOI is 10.1101/YYYY.MM.DD.NNNNNN or 10.64898/YYYY.MM.DD.NNNNNN
        if lower.contains("biorxiv.org") || lower.contains("medrxiv.org") {
            let doiPattern = #"10\.(?:1101|64898)/(\d{4}\.\d{2}\.\d{2}\.\d+(?:v\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: doiPattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range, in: urlString) {
                return String(urlString[range])
            }

            // Older bioRxiv/medRxiv PDF paths may omit the DOI prefix:
            // /content/biorxiv/early/2026/05/13/2026.05.11.724149.full.pdf
            let earlyPathPattern = #"(\d{4}\.\d{2}\.\d{2}\.\d+(?:v\d+)?)"#
            if let regex = try? NSRegularExpression(pattern: earlyPathPattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                let suffix = String(urlString[range])
                let prefix = lower.contains("biorxiv.org") && usesNewBiorxivDOIPrefix(suffix) ? "10.64898" : "10.1101"
                return "\(prefix)/\(suffix)"
            }
        }

        // arXiv: arxiv.org/abs/XXXX.YYYYY → DOI is 10.48550/arXiv.XXXX.YYYYY
        if lower.contains("arxiv.org") {
            let idPattern = #"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})"#
            if let regex = try? NSRegularExpression(pattern: idPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return "10.48550/arXiv.\(urlString[range])"
            }
        }

        // Springer: link.springer.com/article/10.XXXX/YYYY
        if lower.contains("link.springer.com/article/") {
            if let range = urlString.range(of: "link.springer.com/article/") {
                var doi = String(urlString[range.upperBound...])
                if let q = doi.firstIndex(of: "?") { doi = String(doi[..<q]) }
                if let h = doi.firstIndex(of: "#") { doi = String(doi[..<h]) }
                if doi.hasPrefix("10.") { return doi }
            }
        }

        // Generic /doi/ URLs (PNAS, Science, ACS, Wiley, Cell, etc.):
        // e.g. pnas.org/doi/10.1073/pnas.XXX, science.org/doi/10.1126/science.XXX
        let doiInPathPattern = #"/doi/(?:full/|abs/|pdf/|epdf/)?(?:10\.\d{4,}/[^\s?#]+)"#
        if let regex = try? NSRegularExpression(pattern: doiInPathPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range, in: urlString) {
            var doiPath = String(urlString[range])
            // Strip the /doi/ (and optional /full/, /abs/, /pdf/, /epdf/) prefix to get the DOI
            let prefixPattern = #"^/doi/(?:full/|abs/|pdf/|epdf/)?"#
            if let prefixRegex = try? NSRegularExpression(pattern: prefixPattern, options: .caseInsensitive) {
                doiPath = prefixRegex.stringByReplacingMatches(in: doiPath, range: NSRange(doiPath.startIndex..., in: doiPath), withTemplate: "")
            }
            if !doiPath.isEmpty { return doiPath }
        }

        return nil
    }

    private static func usesNewBiorxivDOIPrefix(_ suffix: String) -> Bool {
        let dateParts = suffix.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard dateParts.count == 3 else { return false }
        let year = dateParts[0]
        let month = dateParts[1]
        if year > 2025 { return true }
        if year == 2025, month >= 12 { return true }
        return false
    }

    /// A DOI lowercased and without a preprint's version, so every version of one preprint is one
    /// paper: a trailing `v<digits>` that follows a digit, `.` or `/` (bioRxiv and medRxiv
    /// `10.1101/2024.11.04.615786v3`, preprints.org `10.20944/preprints202301.0001.v1`, Research
    /// Square `10.21203/rs.3.rs-2581279/v1`), with the `.` or `/` it leaves behind. A `v` after a
    /// letter is part of the DOI: every 2015 Oxford DOI has one (`10.1093/nar/gkv1344` and
    /// `10.1093/nar/gkv1157` are two papers), and dropping it would make one paper of a journal's
    /// whole year. A version that would be the whole suffix is kept.
    static func unversionedDOI(_ doi: String) -> String {
        let value = doi.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let version = value.range(of: #"(?<=[0-9./])v[0-9]+$"#, options: .regularExpression) else { return value }
        var unversioned = String(value[..<version.lowerBound])
        while let last = unversioned.last, "./".contains(last) { unversioned.removeLast() }
        guard let slash = unversioned.firstIndex(of: "/"), unversioned.index(after: slash) < unversioned.endIndex else { return value }
        return unversioned
    }

    /// Extract arXiv ID from a URL (e.g. "2401.12345" from "https://arxiv.org/abs/2401.12345").
    static func extractArxivID(from urlString: String) -> String? {
        let pattern = #"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else { return nil }
        return String(urlString[range])
    }

    /// The Springer Nature article id a URL ends in — `s41467-025-66778-6`,
    /// with or without `.pdf` — wherever the file is hosted. Nature names a
    /// paper's PDF after its article id, and a company that mirrors its own
    /// paper keeps the name (`insitro.com/wp-content/uploads/…/s41467-025-66778-6.pdf`),
    /// so the id survives when the `nature.com` host does not. The id is the
    /// DOI's suffix but not the DOI: `10.1038` (Nature), `10.1007` (Springer)
    /// and `10.1186` (BMC) all issue ids of this shape under one journal-code
    /// space, so a caller matches a saved DOI on the suffix rather than guessing
    /// the prefix. Nature's journalism (`d41586-…`) is not an article id here.
    static func extractSpringerNatureArticleID(from urlString: String) -> String? {
        let pattern = #"/(s\d{5}-\d{3}-\d{5}-[a-z0-9])(?:\.pdf)?/?(?:[?#]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else { return nil }
        return String(urlString[range]).lowercased()
    }

    /// Extract OpenReview forum ID from a URL.
    static func extractOpenReviewID(from urlString: String) -> String? {
        // openreview.net/forum?id=XXXX or openreview.net/pdf?id=XXXX
        let pattern = #"openreview\.net/(?:forum|pdf)\?id=([^&\s#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else { return nil }
        return String(urlString[range])
    }

    // MARK: - PMC ID Extraction

    /// Whether a URL points at one of Nature's news, editorial, or comment
    /// pieces rather than a research paper. Nature gives its journalism the
    /// same `/articles/<id>` shape and a real DOI, but the article id starts
    /// with `d` (`d41586-026-02616-z`) where research papers start with `s`
    /// (`s41586-023-06600-9`). Deciding this from the URL keeps every library
    /// that imports the same link landing on the same type, instead of asking
    /// a model to guess whether a news story is a paper and then hunting for a
    /// PDF that does not exist.
    static func isNatureNewsURL(_ urlString: String) -> Bool {
        let pattern = #"(?:nature\.com/articles/|10\.1038/)(d\d{5}-\d{3}-\d{5}-[a-z0-9])(?:[^a-z0-9-]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) != nil
    }

    // MARK: - Publisher full text without a PDF

    /// Phrases a publisher's landing page shows a reader who may not read the
    /// paper. Any one of them can turn up in a paper that discusses publishing;
    /// a full-text page shows none, and a wall shows several, so two distinct
    /// phrases are required before a page is called a wall.
    static let publisherAccessWallPhrases: [String] = [
        "access options",
        "access this article",
        "access through your institution",
        "log in via an institution",
        "log in via your institution",
        "buy this article",
        "buy article",
        "purchase pdf",
        "purchase access",
        "purchase instant access",
        "view all available purchase options",
        "get full access to this article",
        "subscribe to this journal",
        "institutional subscriptions",
        "prices may be subject to local taxes",
        "price includes vat",
    ]

    /// Whether page text is the publisher's access wall — the abstract, the
    /// reference list and a purchase panel — rather than the paper itself.
    static func looksLikePublisherAccessWall(text: String) -> Bool {
        let lowered = text.lowercased()
        var hits = 0
        for phrase in publisherAccessWallPhrases where lowered.contains(phrase) {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }

    /// The fewest words of body text a publisher page must carry to be taken
    /// as a paper's full text. A landing page's abstract runs a few hundred
    /// words; the shortest research letters run well past this.
    static let minimumPaperFullTextWordCount = 600

    /// Headings of the sections publishers print around a paper rather than as
    /// part of it. Text under these is not evidence that the paper is present:
    /// Nature's preview of a paper a reader cannot access carries the abstract,
    /// one-line figure titles and the complete Extended Data legends, which run
    /// to thousands of words while Main, Results and Methods are absent.
    /// Headings are compared lowercased with trailing punctuation removed.
    static let paperNonBodyHeadings: Set<String> = [
        "extended data", "supplementary information", "supplementary material",
        "supplementary materials", "source data", "data availability",
        "code availability", "references", "references and notes",
        "acknowledgements", "acknowledgments", "author information",
        "authors and affiliations", "contributions", "author contributions",
        "corresponding author", "corresponding authors", "ethics declarations",
        "competing interests", "peer review", "peer review information",
        "additional information", "rights and permissions", "about this article",
        "cite this article", "funding", "change history", "publisher's note",
        "publisher\u{2019}s note", "access options", "additional access options",
        "similar content being viewed by others", "explore related subjects",
        "related articles", "recommended articles",
    ]

    /// Heading prefixes of figure and table legends, which are not body text.
    static let paperNonBodyHeadingPrefixes = [
        "extended data fig", "extended data table", "supplementary fig",
        "supplementary table", "fig.", "figure ", "table ",
    ]

    /// The fewest words a section must run to count as the paper's body. A
    /// paper's sections — the abstract, Introduction, Results, a headingless
    /// body — run to hundreds of words. A publisher's page around them is a
    /// scatter of small sections: citation counts, Share and Export panels,
    /// "How to cite", a footer, and the sign-in and password forms the site
    /// keeps hidden in the page. Aging Cell's Wiley landing page for a 2004
    /// paper was stored as that paper's text (2026-11-08): its abstract ran
    /// 224 words, and some twenty such sections, none over 75 words, carried
    /// it past `minimumPaperFullTextWordCount`.
    static let minimumPaperBodySectionWordCount = 150

    /// Words of the text that stand in the paper's body: in sections that run
    /// to `minimumPaperBodySectionWordCount` words and that `paperNonBodyHeadings`
    /// does not name. Text with no Markdown headings is one section and counts
    /// whole; the reader's text extraction marks a page's headings with `#`, so
    /// a publisher page's legends, reference list, back matter and interface
    /// are set aside by their headings, and the abstract and the body remain.
    static func paperBodyWordCount(_ text: String) -> Int {
        var count = 0
        var sectionCount = 0
        var insideNonBodySection = false
        func closeSection() {
            if sectionCount >= minimumPaperBodySectionWordCount { count += sectionCount }
            sectionCount = 0
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
                // A bare `###` carries no title and does not open a section.
                guard !heading.isEmpty else { continue }
                closeSection()
                insideNonBodySection = paperNonBodyHeadings.contains(heading)
                    || paperNonBodyHeadingPrefixes.contains(where: { heading.hasPrefix($0) })
                continue
            }
            guard !insideNonBodySection else { continue }
            sectionCount += trimmed.split(whereSeparator: { $0.isWhitespace }).count
        }
        closeSection()
        return count
    }

    /// Whether text read from a publisher page can stand in for a paper's PDF:
    /// enough body text to be the paper, and not the wall that fronts it. The
    /// length is judged on the body alone, because a preview's Extended Data
    /// legends and a reference list can outrun a whole research letter.
    static func looksLikePaperFullText(_ text: String) -> Bool {
        guard !looksLikePublisherAccessWall(text: text) else { return false }
        return paperBodyWordCount(text) >= minimumPaperFullTextWordCount
    }

    /// Extract a PMC ID (e.g. "PMC12007350") from a PMC article URL.
    /// Handles both old (ncbi.nlm.nih.gov/pmc/articles/) and new (pmc.ncbi.nlm.nih.gov/articles/) formats.
    static func extractPMCID(from urlString: String) -> String? {
        let pattern = #"ncbi\.nlm\.nih\.gov/(?:pmc/)?articles/(PMC\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else { return nil }
        return String(urlString[range])
    }

    /// NCBI's own PDF route for a PMC article: `…/articles/<PMCID>/pdf/`.
    ///
    /// Measured on 2026-09-23: the route answers with a 301 to the file
    /// (`…/pdf/nihms-1720171.pdf`), and the file with PMC's "Preparing to
    /// download ..." proof-of-work page until the request carries the answer's
    /// cookie, which `SourceService.downloadPDF` computes. It is the first PDF
    /// candidate for any PMC article: Europe PMC's rendered copy
    /// (`?pdf=render`), which the lookups used to hand out first, now answers
    /// non-browser clients with 403 or 500, and a recheck that reached it
    /// reported an open paper as having no PDF.
    static func ncbiPMCPDFURL(pmcid: String) -> String {
        let normalized = pmcid.uppercased().hasPrefix("PMC") ? "PMC" + pmcid.dropFirst(3) : "PMC\(pmcid)"
        return "https://pmc.ncbi.nlm.nih.gov/articles/\(normalized)/pdf/"
    }

    /// NCBI's PDF route for the PMC article `urlString` names — its page, in
    /// either PMC URL shape, or its short `/pdf/` link — or nil when it names
    /// none. A long-form file URL (`…/pdf/<name>.pdf`) is already the file and
    /// is returned by `paperPDFURL(from:)` unchanged.
    static func ncbiPMCPDFURL(forArticleURL urlString: String) -> String? {
        guard let pmcid = extractPMCID(from: urlString) else { return nil }
        return ncbiPMCPDFURL(pmcid: pmcid)
    }

    /// Whether `urlString` is on PubMed Central's own host: `pmc.ncbi.nlm.nih.gov`,
    /// or the older `www.ncbi.nlm.nih.gov/pmc/`.
    static func isNCBIPMCURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else { return false }
        if host == "pmc.ncbi.nlm.nih.gov" { return true }
        return (host == "www.ncbi.nlm.nih.gov" || host == "ncbi.nlm.nih.gov")
            && components.path.lowercased().hasPrefix("/pmc/")
    }

    /// The short `…/articles/PMCXXXX/pdf` or `…/pdf/` link, with no file name
    /// after it. `attach_pdf_to_paper` used to answer it with "No downloadable
    /// PDF URL found", because it is not a `.pdf` path and its page scan met
    /// the proof-of-work page, while the file it redirects to attached fine.
    static func isNCBIPMCShortPDFRoute(_ urlString: String) -> Bool {
        guard isNCBIPMCURL(urlString), let components = URLComponents(string: urlString) else { return false }
        let pattern = #"/articles/PMC\d+/pdf/?$"#
        return components.path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Europe PMC's rendered PDF of a PMC article: `europepmc.org/articles/PMC…?pdf=render`
    /// or the `ptpmcrender.fcgi?…&blobtype=pdf` backend. It is a PDF address
    /// even though its path does not say so.
    static func isEuropePMCRenderedPDFURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "europepmc.org" || host.hasSuffix(".europepmc.org") else { return false }
        let items = components.queryItems ?? []
        if components.path.lowercased().contains("ptpmcrender") {
            return items.contains { $0.name.lowercased() == "blobtype" && $0.value?.lowercased() == "pdf" }
        }
        return items.contains { $0.name.lowercased() == "pdf" && $0.value?.lowercased() == "render" }
    }

    /// Extract a PubMed ID (PMID) from a pubmed.ncbi.nlm.nih.gov URL.
    static func extractPMID(from urlString: String) -> String? {
        let lower = urlString.lowercased()
        guard lower.contains("pubmed.ncbi.nlm.nih.gov") else { return nil }
        // URL pattern: https://pubmed.ncbi.nlm.nih.gov/12345678/
        let pattern = #"pubmed\.ncbi\.nlm\.nih\.gov/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else { return nil }
        return String(urlString[range])
    }

    // MARK: - Paper Title Extraction

    /// Try to extract a paper title from the raw HTML of a journal landing page.
    static func extractPaperTitle(from html: String) -> String? {
        extractPaperPageMetadata(from: html)?.title
    }

    /// Whether a page title is the page's chrome rather than a document's name:
    /// what an interstitial calls itself while it sends the browser somewhere
    /// else. Elsevier's linkinghub answers every 10.1016 DOI with a page titled
    /// "Redirecting" that moves on by meta refresh and script; a bot check
    /// titles itself "Just a moment…"; some hosts title a holding page with
    /// their own name; some title it not at all. None of these is ever the
    /// paper's title, so a caller holding one must neither save it nor search
    /// the scholarly indexes by it — the DOI record's title is the paper's.
    ///
    /// Deliberately an exact vocabulary, not a prefix: "Redirecting T cells
    /// against cancer" is a paper.
    static func isInterstitialPageTitle(_ title: String, url: String? = nil) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let bare = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if bare == "redirecting" || bare == "redirect" { return true }
        if SourceDiscovery.isSecurityVerificationPage(title: trimmed, visibleText: "", url: url ?? "") {
            return true
        }
        if let host = url.flatMap(URL.init(string:))?.host?.lowercased() {
            let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let lower = trimmed.lowercased()
            if lower == host || lower == bareHost { return true }
        }
        return false
    }

    /// Title and byline metadata for blog posts and other non-scholarly web articles.
    struct WebArticleMetadata {
        /// The best title the page's structure alone can give. It is a
        /// placeholder until the article-metadata model has read
        /// `titleEvidence`; see `WebArticleTitleEvidence`.
        let title: String?
        let author: String?
        /// Every place the page names itself, for the model to weigh.
        let titleEvidence: WebArticleTitleEvidence

        init(title: String?, author: String?, titleEvidence: WebArticleTitleEvidence = WebArticleTitleEvidence()) {
            self.title = title
            self.author = author
            self.titleEvidence = titleEvidence
        }
    }

    /// What a web page says its own title is, from each place a page says it.
    ///
    /// A page's `<title>` is site chrome as often as it is the headline
    /// ("Waypoint Bio" on every post of that site; "Waypoint Bio: Immune
    /// Engineering — Amplify Partners"), an `og:title` carries the same
    /// publisher suffix, and an `<h1>` can carry the section it sits in
    /// ("Writings - The Missing Dimension in Pooled Screens"). Which of them
    /// is the headline the author gave is reading, not parsing, so the fields
    /// are kept apart here and handed together to the article-metadata model
    /// (`AIService.fixArticleTitle`). Nothing in this struct is cleaned up:
    /// the model sees the page as it was served.
    struct WebArticleTitleEvidence: Sendable, Equatable {
        /// The `<title>` element's text.
        var documentTitle: String?
        /// `og:title`, or `twitter:title` when the page has no Open Graph title.
        var socialTitle: String?
        /// `og:site_name` or `application-name`: the publisher's name for itself.
        var siteName: String?
        /// The first `<h1>` with visible text.
        var headline: String?
        /// `headline` from the page's JSON-LD Article record, the one field a
        /// publisher writes specifically to name the article.
        var structuredHeadline: String?
        /// The author the JSON-LD Article record names, when the page has no
        /// author `<meta>`.
        var structuredAuthor: String?

        var isEmpty: Bool {
            documentTitle == nil && socialTitle == nil && siteName == nil
                && headline == nil && structuredHeadline == nil
        }

        /// Every distinct title the page offered, most deliberate first.
        var titleCandidates: [String] {
            var seen = Set<String>()
            return [structuredHeadline, socialTitle, headline, documentTitle]
                .compactMap { $0 }
                .filter { seen.insert($0.lowercased()).inserted }
        }

        /// True when `title` is one the page itself supplied — the document
        /// title, a social title, the headline, the site's name or the page's
        /// host — rather than one a person typed. Used to decide whether the
        /// model's answer may replace what a source currently carries.
        func supplied(_ title: String, host: String?) -> Bool {
            let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return true }
            var supplied = titleCandidates.map { $0.lowercased() }
            if let siteName { supplied.append(siteName.lowercased()) }
            if let host = host?.lowercased() {
                supplied.append(host)
                if host.hasPrefix("www.") { supplied.append(String(host.dropFirst(4))) }
            }
            return supplied.contains(needle)
        }
    }

    /// Extract article title and author from a web page: the head's metadata,
    /// its JSON-LD Article record, and the first headline in the body.
    static func extractWebArticleMetadata(from html: String) -> WebArticleMetadata? {
        let metadataHTML = metadataScanRegion(from: html)
        let meta = HeadMetaTags(html: metadataHTML)
        let evidence = extractWebArticleTitleEvidence(from: html, metadataHTML: metadataHTML, meta: meta)

        // The structural placeholder. A JSON-LD headline is the one field
        // written to name the article, so it wins; otherwise the head's
        // metadata as before. A `<title>` that is just the site's own name
        // names the site, so the page's headline stands in for it. Everything
        // finer than this is the model's call.
        var title = evidence.structuredHeadline ?? extractPaperTitleCandidate(from: metadataHTML, meta: meta)
        if let candidate = title, let headline = evidence.headline,
           let siteName = evidence.siteName,
           candidate.caseInsensitiveCompare(siteName) == .orderedSame {
            title = headline
        }

        // The byline: the head's author tags, every one of them (quantum.country
        // names two), then Open Graph's, then the JSON-LD record's. Each must be
        // a name. Open Graph defines `article:author` as a profile link, and
        // eleven articles in the production library stored one as their
        // author, so a web address — or anything else that is not a name
        // (`SourceAuthor`) — gives way to the next place the page names one.
        let author = [
            byline(of: meta.contents(attribute: "name", value: "author")),
            byline(of: meta.contents(attribute: "property", value: "article:author")),
            evidence.structuredAuthor,
        ]
        .lazy
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        if title == nil, author == nil, evidence.isEmpty { return nil }
        return WebArticleMetadata(title: title, author: author, titleEvidence: evidence)
    }

    /// One byline from the names a page gives, in its order: the names that
    /// are names (`SourceAuthor`), each once, as the library shortens a list —
    /// "A", "A & B", "A et al.".
    private static func byline(of candidates: [String]) -> String? {
        var seen = Set<String>()
        let names = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && SourceAuthor.isPlausible($0) }
            .filter { seen.insert($0.lowercased()).inserted }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]) et al."
        }
    }

    /// The bounded slice of a page in which its headline and JSON-LD live:
    /// the head plus the opening of the body. The same reasoning as
    /// `metadataScanRegion` — a Next.js page can trail megabytes of serialized
    /// state, and a regular expression must never be asked to cross them.
    private static func headlineScanRegion(from html: String) -> String {
        let maximumCharacters = 768 * 1_024
        let limit = html.index(html.startIndex, offsetBy: maximumCharacters, limitedBy: html.endIndex)
            ?? html.endIndex
        return String(html[..<limit])
    }

    static func extractWebArticleTitleEvidence(from html: String) -> WebArticleTitleEvidence {
        let metadataHTML = metadataScanRegion(from: html)
        return extractWebArticleTitleEvidence(
            from: html,
            metadataHTML: metadataHTML,
            meta: HeadMetaTags(html: metadataHTML)
        )
    }

    private static func extractWebArticleTitleEvidence(
        from html: String,
        metadataHTML: String,
        meta: HeadMetaTags
    ) -> WebArticleTitleEvidence {
        var evidence = WebArticleTitleEvidence()
        evidence.documentTitle = firstElementText(tag: "title", in: metadataHTML)
        evidence.socialTitle = cleanEvidence(
            meta.content(property: "og:title") ?? meta.content(name: "twitter:title")
        )
        evidence.siteName = cleanEvidence(
            meta.content(property: "og:site_name") ?? meta.content(name: "application-name")
        )
        let bodyRegion = headlineScanRegion(from: html)
        evidence.headline = firstElementText(tag: "h1", in: bodyRegion)
        let structured = structuredArticleRecord(in: bodyRegion)
        evidence.structuredHeadline = structured.headline
        evidence.structuredAuthor = structured.author
        return evidence
    }

    /// The visible text of the first `<tag>` element that has any: tags
    /// stripped, entities decoded, whitespace collapsed. Elements longer than a
    /// title could be are skipped as the page's prose rather than its name.
    private static func firstElementText(tag: String, in html: String) -> String? {
        let pattern = #"<\#(tag)\b[^>]*>([\s\S]*?)</\#(tag)\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let inner = String(html[range])
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            if let text = cleanEvidence(inner) { return text }
        }
        return nil
    }

    private static func cleanEvidence(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = decodeHTML(raw)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 300 else { return nil }
        return text
    }

    /// The headline and author of the page's JSON-LD Article record, when it
    /// carries one. Article-like types only (`Article`, `BlogPosting`,
    /// `NewsArticle`, `ScholarlyArticle`, …); a `WebSite` or `Organization`
    /// record's `name` is the site's, not the page's. `@graph` bundles and
    /// arrays of records are walked.
    private static func structuredArticleRecord(in html: String) -> (headline: String?, author: String?) {
        let pattern = #"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (nil, nil)
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let json = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            if let record = firstArticleRecord(in: root) {
                let headline = cleanEvidence(record["headline"] as? String)
                return (headline, structuredAuthorName(record["author"]))
            }
        }
        return (nil, nil)
    }

    private static func firstArticleRecord(in node: Any) -> [String: Any]? {
        if let array = node as? [Any] {
            for element in array {
                if let record = firstArticleRecord(in: element) { return record }
            }
            return nil
        }
        guard let object = node as? [String: Any] else { return nil }
        if let graph = object["@graph"], let record = firstArticleRecord(in: graph) { return record }
        let types: [String]
        if let type = object["@type"] as? String {
            types = [type]
        } else if let list = object["@type"] as? [String] {
            types = list
        } else {
            types = []
        }
        let isArticle = types.contains { type in
            let lower = type.lowercased()
            return lower.hasSuffix("article") || lower.hasSuffix("posting") || lower == "report"
        }
        if isArticle, object["headline"] is String { return object }
        if let main = object["mainEntity"], let record = firstArticleRecord(in: main) { return record }
        return nil
    }

    private static func structuredAuthorName(_ node: Any?) -> String? {
        guard let node else { return nil }
        var names: [String] = []
        func collect(_ value: Any) {
            if let list = value as? [Any] {
                list.forEach(collect)
            } else if let object = value as? [String: Any], let name = cleanEvidence(object["name"] as? String) {
                names.append(name)
            } else if let name = cleanEvidence(value as? String) {
                names.append(name)
            }
        }
        collect(node)
        return byline(of: names)
    }

    /// Extract title, DOI, and citation metadata from a scholarly landing page.
    /// `url` is the address the page was served from, when known; a title that
    /// is only the host's name is then recognised as the page's, not the paper's.
    static func extractPaperPageMetadata(from html: String, url: String? = nil) -> PaperPageMetadata? {
        let metadataHTML = metadataScanRegion(from: html)
        let meta = HeadMetaTags(html: metadataHTML)
        let title = extractPaperTitleCandidate(from: metadataHTML, meta: meta, url: url)
        let citationAuthors = meta.contents(attribute: "name", value: "citation_author")
        let authorsDisplay = authorsDisplay(from: citationAuthors.isEmpty
            ? meta.contents(attribute: "name", value: "dc.creator")
            : citationAuthors
        )
        let journal =
            meta.content(name: "citation_journal_title")
            ?? meta.content(name: "citation_conference_title")
            ?? meta.content(name: "prism.publicationName")
            ?? meta.content(name: "dc.source")
        let year =
            meta.content(name: "citation_publication_date").flatMap(extractYear)
            ?? meta.content(name: "citation_online_date").flatMap(extractYear)
            ?? meta.content(name: "citation_date").flatMap(extractYear)
            ?? meta.content(name: "dc.date").flatMap(extractYear)
            ?? meta.content(name: "prism.publicationDate").flatMap(extractYear)
        let doi =
            meta.content(name: "citation_doi").flatMap(normalizeExtractedDOI)
            ?? meta.content(name: "dc.identifier").flatMap(normalizeExtractedDOI)
            ?? meta.content(name: "dc.identifier.doi").flatMap(normalizeExtractedDOI)
            ?? meta.content(name: "prism.doi").flatMap(normalizeExtractedDOI)
        let pdfURL = meta.content(name: "citation_pdf_url")

        if title == nil, authorsDisplay == nil, journal == nil, year == nil, doi == nil, pdfURL == nil {
            return nil
        }

        return PaperPageMetadata(
            title: title,
            authorsDisplay: authorsDisplay,
            journal: journal,
            year: year,
            doi: doi,
            pdfURL: pdfURL
        )
    }

    private static func extractPaperTitleCandidate(
        from html: String,
        meta: HeadMetaTags,
        url: String? = nil
    ) -> String? {
        // Try <meta> og:title or citation_title first (most reliable)
        let metaTitles = [
            meta.content(name: "citation_title"),
            meta.content(property: "og:title"),
            meta.content(name: "dc.title"),
        ]
        for title in metaTitles {
            if let title, !title.isEmpty, title.count < 300, !isInterstitialPageTitle(title, url: url) {
                return title
            }
        }

        // Fallback: <title> tag. A page that is only passing the browser on
        // titles the wait, not the document — Elsevier's linkinghub announces
        // a meta refresh — so a redirect page gets no title from here at all:
        // the caller falls through to the DOI record.
        guard !meta.announcesRefresh else { return nil }
        let titlePattern = #"<title[^>]*>([^<]+)</title>"#
        if let regex = try? NSRegularExpression(pattern: titlePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            var title = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip common suffixes like " | Nature", " - ScienceDirect"
            for sep in [" | ", " - ", " — ", " · "] {
                if let sepRange = title.range(of: sep, options: .backwards) {
                    title = String(title[..<sepRange.lowerBound])
                }
            }
            if !title.isEmpty && title.count < 300 && !isInterstitialPageTitle(title, url: url) {
                return title
            }
        }

        return nil
    }

    // MARK: - Metadata Lookup

    /// Paper metadata returned by Crossref.
    struct CrossrefMetadata {
        let authorsDisplay: String?
        let journal: String?
        let year: String?
        /// Plain text: a catalog's `H<sub>2</sub>O<sub>2</sub>` arrives as `H₂O₂`.
        let title: String?
        let doi: String?

        init(authorsDisplay: String?, journal: String?, year: String?, title: String? = nil, doi: String? = nil) {
            self.authorsDisplay = authorsDisplay
            self.journal = journal
            self.year = year
            self.title = title?.decodingTitleMarkup()
            self.doi = doi
        }
    }

    /// Try all available metadata sources for a paper, in order of specificity.
    /// Returns the first successful result.
    static func fetchPaperMetadata(url: String, title: String, doi: String?) async -> CrossrefMetadata? {
        // 1. Crossref by DOI (most authoritative for published papers)
        if let doi {
            if let meta = await fetchCrossrefMetadata(doi: doi) { return meta }
        }

        // 2. Source-specific APIs based on URL
        if let arxivID = extractArxivID(from: url) {
            if let meta = await fetchArxivMetadata(arxivID: arxivID) { return meta }
        }
        if let doi, (url.lowercased().contains("biorxiv.org") || url.lowercased().contains("medrxiv.org") || doi.hasPrefix("10.1101/") || doi.hasPrefix("10.64898/")) {
            if let meta = await fetchBiorxivMetadata(doi: doi) { return meta }
        }
        if let forumID = extractOpenReviewID(from: url) {
            if let meta = await fetchOpenReviewMetadata(forumID: forumID) { return meta }
        }

        // 3. Crossref by title (works for published papers without extractable DOI)
        if !title.isEmpty {
            if let meta = await searchCrossrefByTitle(title) { return meta }
        }

        // 4. OpenAlex by title (best coverage of preprints)
        if !title.isEmpty {
            if let meta = await searchOpenAlexByTitle(title) { return meta }
        }

        return nil
    }

    /// Fetch paper metadata (authors, journal, year) from Crossref for a given DOI.
    static func fetchCrossrefMetadata(doi: String) async -> CrossrefMetadata? {
        guard let url = URL(string: "https://api.crossref.org/works/\(doi)") else { return nil }
        let json: [String: Any]?
        do {
            json = try await fetchJSONObject(from: url, userAgent: "ForeverLM/1.0 (mailto:flashcards@foreverlm.app)")
        } catch {
            logger.error("fetchCrossrefMetadata: transport failure for DOI \(doi, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let msg = json?["message"] as? [String: Any] else { return nil }

        let authorsDisplay = (msg["author"] as? [[String: Any]]).flatMap(Self.crossrefAuthorsDisplay)

        // Journal
        let journal = (msg["container-title"] as? [String])?.first

        // Year
        var year: String?
        let publishedDict = (msg["published"] as? [String: Any])
            ?? (msg["published-print"] as? [String: Any])
            ?? (msg["published-online"] as? [String: Any])
        if let dateParts = publishedDict?["date-parts"] as? [[Int]], let first = dateParts.first, let y = first.first {
            year = String(y)
        }

        let title = (msg["title"] as? [String])?.first
        let resolvedDOI = msg["DOI"] as? String

        return CrossrefMetadata(authorsDisplay: authorsDisplay, journal: journal, year: year, title: title, doi: resolvedDOI)
    }

    // MARK: - Registered Title

    /// What a DOI's registration agency calls the work.
    enum RegisteredTitle: Equatable, Sendable {
        /// The registered title, as plain text (`H₂O₂`, not the catalog's
        /// `H<sub>2</sub>O<sub>2</sub>`).
        case title(String)
        /// Neither Crossref nor DataCite has the DOI, or its record names no
        /// title. Asking again will not change that.
        case unregistered
        /// The agency could not be asked — offline, rate-limited, a server
        /// error — so the question stands for later.
        case unavailable(String)
    }

    /// The title a DOI is registered under: Crossref first, which registers
    /// most journal DOIs, then DataCite, which registers arXiv's and most
    /// repositories'. Nothing else is asked: a title search answers with some
    /// work's title, not this DOI's. `RegisteredPaperTitle` decides what the
    /// answer may change.
    static func registeredTitle(forDOI doi: String) async -> RegisteredTitle {
        let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("10."),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return .unregistered
        }
        let crossref = await registeredTitle(
            at: "https://api.crossref.org/works/\(encoded)",
            agency: "Crossref"
        ) { json in
            ((json["message"] as? [String: Any])?["title"] as? [String])?.first
        }
        guard crossref == .unregistered else { return crossref }
        return await registeredTitle(
            at: "https://api.datacite.org/dois/\(encoded)",
            agency: "DataCite"
        ) { json in
            let attributes = (json["data"] as? [String: Any])?["attributes"] as? [String: Any]
            return (attributes?["titles"] as? [[String: Any]])?.first?["title"] as? String
        }
    }

    /// The title a DOI is registered under, when an agency answers with one.
    /// Ingestion asks this beside the metadata model; no answer leaves the
    /// model's title as it is.
    static func registeredTitleIfKnown(forDOI doi: String?) async -> String? {
        guard let doi else { return nil }
        let answer = await registeredTitle(forDOI: doi)
        guard case .title(let title) = answer else { return nil }
        return title
    }

    private static func registeredTitle(
        at address: String,
        agency: String,
        reading title: ([String: Any]) -> String?
    ) async -> RegisteredTitle {
        guard let url = URL(string: address) else { return .unregistered }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("ForeverLM/1.0 (mailto:flashcards@foreverlm.app)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .unregistered }
            guard status == 200 else { return .unavailable("\(agency) answered HTTP \(status)") }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unavailable("\(agency) answered with a record that is not JSON")
            }
            let plain = (title(json) ?? "")
                .decodingTitleMarkup()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? .unregistered : .title(plain)
        } catch {
            return .unavailable("\(agency): \(error.localizedDescription)")
        }
    }

    /// Search Crossref by paper title to find metadata when DOI is unavailable.
    /// Uses Crossref's query API and verifies the top result title is a close match.
    static func searchCrossrefByTitle(_ title: String) async -> CrossrefMetadata? {
        guard let url = makeQueryURL("https://api.crossref.org/works", queryItems: [
            URLQueryItem(name: "query.bibliographic", value: title),
            URLQueryItem(name: "rows", value: "3"),
            URLQueryItem(name: "select", value: "author,container-title,published,published-print,published-online,title"),
        ]) else { return nil }
        let json: [String: Any]?
        do {
            json = try await fetchJSONObject(from: url, userAgent: "ForeverLM/1.0 (mailto:flashcards@foreverlm.app)")
        } catch {
            logger.error("searchCrossrefByTitle: transport failure for title query: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let msg = json?["message"] as? [String: Any],
              let items = msg["items"] as? [[String: Any]] else { return nil }

        guard let best = items.first(where: { item in
            guard let resultTitles = item["title"] as? [String], let resultTitle = resultTitles.first else {
                return false
            }
            return titlesMatch(title, resultTitle)
        }) else { return nil }

        let authorsDisplay = (best["author"] as? [[String: Any]]).flatMap(Self.crossrefAuthorsDisplay)
        let journal = (best["container-title"] as? [String])?.first
        var year: String?
        let publishedDict = (best["published"] as? [String: Any])
            ?? (best["published-print"] as? [String: Any])
            ?? (best["published-online"] as? [String: Any])
        if let dateParts = publishedDict?["date-parts"] as? [[Int]], let first = dateParts.first, let y = first.first {
            year = String(y)
        }
        let bestTitle = (best["title"] as? [String])?.first
        let resolvedDOI = best["DOI"] as? String
        return CrossrefMetadata(authorsDisplay: authorsDisplay, journal: journal, year: year, title: bestTitle, doi: resolvedDOI)
    }

    // MARK: - arXiv Metadata

    /// Fetch paper metadata from the arXiv Atom API.
    static func fetchArxivMetadata(arxivID: String) async -> CrossrefMetadata? {
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(arxivID)&max_results=1") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        // Parse authors — <author><name>First Last</name></author>
        let authorPattern = #"<author>\s*<name>([^<]+)</name>"#
        var names: [String] = []
        if let regex = try? NSRegularExpression(pattern: authorPattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for m in matches {
                if let r = Range(m.range(at: 1), in: xml) {
                    let fullName = String(xml[r]).trimmingCharacters(in: .whitespaces)
                    names.append(fullName)
                }
            }
        }
        let authorsDisplay = Self.authorsDisplay(from: names)

        // Parse year from <published>YYYY-MM-DDTHH:MM:SSZ</published>
        var year: String?
        let datePattern = #"<published>(\d{4})-"#
        if let regex = try? NSRegularExpression(pattern: datePattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           let r = Range(match.range(at: 1), in: xml) {
            year = String(xml[r])
        }

        guard authorsDisplay != nil || year != nil else { return nil }
        var title: String?
        let titlePattern = #"<title>([^<]+)</title>"#
        if let regex = try? NSRegularExpression(pattern: titlePattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           let range = Range(match.range(at: 1), in: xml) {
            title = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return CrossrefMetadata(
            authorsDisplay: authorsDisplay,
            journal: "arXiv",
            year: year,
            title: title,
            doi: "10.48550/arXiv.\(arxivID)"
        )
    }

    // MARK: - bioRxiv / medRxiv Metadata

    /// Fetch paper metadata from the bioRxiv/medRxiv API using a DOI.
    static func fetchBiorxivMetadata(doi: String) async -> CrossrefMetadata? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        for server in ["biorxiv", "medrxiv"] {
            guard let url = URL(string: "https://api.biorxiv.org/details/\(server)/\(encoded)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let collection = json["collection"] as? [[String: Any]],
                  let first = collection.first else { continue }

            let authorsDisplay = (first["authors"] as? String).flatMap(Self.commaSeparatedFamilyAuthorDisplay)

            var year: String?
            if let date = first["date"] as? String, date.count >= 4 {
                year = String(date.prefix(4))
            }

            let journal = server == "biorxiv" ? "bioRxiv" : "medRxiv"
            guard authorsDisplay != nil || year != nil else { continue }
            let title = first["title"] as? String
            return CrossrefMetadata(authorsDisplay: authorsDisplay, journal: journal, year: year, title: title, doi: doi)
        }
        return nil
    }

    // MARK: - Preprint Published Version Lookup

    /// Known preprint server names (lowercased) — used to filter out non-journal results.
    private static let preprintServerNames = ["arxiv", "biorxiv", "medrxiv", "openreview", "research square", "ssrn", "preprints.org", "chemrxiv", "eartharxiv", "engrxiv", "psyarxiv", "socarxiv", "techrxiv"]

    /// Whether a journal name refers to a preprint server rather than a peer-reviewed venue.
    static func isPreprintVenue(_ journal: String) -> Bool {
        let j = journal.lowercased()
        return preprintServerNames.contains(where: { j == $0 || j.contains($0) })
    }

    /// Hosts that serve preprints, matched against a source URL. A preprint that
    /// was saved from its PDF has no such URL, which is why `isPreprintPaper`
    /// also consults the recorded venue.
    private static let preprintHosts = [
        "arxiv.org", "biorxiv.org", "medrxiv.org", "openreview.net",
        "researchsquare.com", "ssrn.com", "preprints.org", "chemrxiv.org",
        "eartharxiv.org", "engrxiv.org", "psyarxiv.com", "socarxiv.org",
        "techrxiv.org",
    ]

    /// DOI prefixes the preprint servers mint under: bioRxiv and medRxiv (both
    /// prefixes), arXiv's DataCite DOIs, Research Square, preprints.org, SSRN,
    /// OSF (PsyArXiv, SocArXiv, EngrXiv, EarthArXiv), ChemRxiv, TechRxiv and
    /// Authorea. A journal's DOI is never under one of these.
    private static let preprintDOIPrefixes = [
        "10.1101/", "10.64898/", "10.48550/", "10.21203/", "10.20944/", "10.2139/",
        "10.31219/", "10.31234/", "10.31235/", "10.31224/", "10.31223/", "10.26434/",
        "10.36227/", "10.22541/",
    ]

    /// Whether a DOI was minted by a preprint server rather than a journal.
    static func isPreprintDOI(_ doi: String) -> Bool {
        let lower = doi.lowercased()
        return preprintDOIPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    /// Whether a saved paper is a preprint, and therefore worth asking the
    /// catalogs whether a peer-reviewed version has appeared since.
    static func isPreprintPaper(url: String, journal: String?) -> Bool {
        let lower = url.lowercased()
        if preprintHosts.contains(where: { lower.contains($0) }) { return true }
        if let journal, !journal.isEmpty, isPreprintVenue(journal) { return true }
        return false
    }

    /// Result of checking whether a preprint has been published.
    struct PublishedVersionResult: Sendable {
        let publishedDOI: String
        let publishedURL: String
        let journal: String
        let year: String?
    }

    /// Check if a bioRxiv/medRxiv preprint has been published using their authoritative `/pubs/` API.
    static func checkBiorxivPublished(doi: String) async -> PublishedVersionResult? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        for server in ["biorxiv", "medrxiv"] {
            guard let url = URL(string: "https://api.biorxiv.org/pubs/\(server)/\(encoded)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let collection = json["collection"] as? [[String: Any]],
                  let pub = collection.first,
                  let pubDOI = pub["published_doi"] as? String, !pubDOI.isEmpty else { continue }
            let journal = (pub["published_journal"] as? String) ?? "Published"
            let year = (pub["published_date"] as? String).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
            return PublishedVersionResult(publishedDOI: pubDOI, publishedURL: "https://doi.org/\(pubDOI)", journal: journal, year: year)
        }
        return nil
    }

    /// Check if a preprint has a published version via the Crossref `relation.is-preprint-of` field.
    static func checkCrossrefRelation(doi: String) async -> PublishedVersionResult? {
        guard let url = URL(string: "https://api.crossref.org/works/\(doi)?select=relation") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ForeverLM/1.0 (mailto:flashcards@foreverlm.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let relation = msg["relation"] as? [String: Any] else { return nil }

        guard let links = relation["is-preprint-of"] as? [[String: Any]] else { return nil }
        for link in links {
            guard let pubDOI = link["id"] as? String, !pubDOI.isEmpty else { continue }
            if let meta = await fetchCrossrefMetadata(doi: pubDOI),
               let journal = meta.journal, !isPreprintVenue(journal) {
                return PublishedVersionResult(publishedDOI: pubDOI, publishedURL: "https://doi.org/\(pubDOI)", journal: journal, year: meta.year)
            }
        }
        return nil
    }

    /// Search Crossref by title to find a published version of a preprint.
    static func searchCrossrefForPublished(title: String) async -> PublishedVersionResult? {
        guard let url = makeQueryURL("https://api.crossref.org/works", queryItems: [
            URLQueryItem(name: "query.bibliographic", value: title),
            URLQueryItem(name: "rows", value: "5"),
            URLQueryItem(name: "select", value: "DOI,title,container-title,published,published-print,published-online,type"),
        ]) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ForeverLM/1.0 (mailto:flashcards@foreverlm.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let items = msg["items"] as? [[String: Any]] else { return nil }

        for item in items {
            guard let titles = item["title"] as? [String], let resultTitle = titles.first,
                  titlesMatch(title, resultTitle) else { continue }
            let itemType = item["type"] as? String ?? ""
            if itemType == "posted-content" { continue }
            guard let journal = (item["container-title"] as? [String])?.first,
                  !isPreprintVenue(journal) else { continue }
            let pubDOI = item["DOI"] as? String ?? ""
            var year: String?
            let pubDict = (item["published"] as? [String: Any])
                ?? (item["published-print"] as? [String: Any])
                ?? (item["published-online"] as? [String: Any])
            if let dateParts = pubDict?["date-parts"] as? [[Int]], let first = dateParts.first, let y = first.first {
                year = String(y)
            }
            return PublishedVersionResult(publishedDOI: pubDOI, publishedURL: "https://doi.org/\(pubDOI)", journal: journal, year: year)
        }
        return nil
    }

    /// Search OpenAlex by title as a last-resort fallback.
    static func searchOpenAlexForPublished(title: String) async -> PublishedVersionResult? {
        guard let url = makeQueryURL("https://api.openalex.org/works", queryItems: [
            URLQueryItem(name: "search", value: "\"\(title)\""),
            URLQueryItem(name: "per_page", value: "5"),
            URLQueryItem(name: "select", value: "title,doi,primary_location,publication_year,type"),
            URLQueryItem(name: "mailto", value: "support@foreverlm.com"),
        ]) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        for result in results {
            guard let resultTitle = result["title"] as? String, titlesMatch(title, resultTitle) else { continue }
            guard let loc = result["primary_location"] as? [String: Any],
                  let source = loc["source"] as? [String: Any],
                  let journal = source["display_name"] as? String,
                  !isPreprintVenue(journal) else { continue }
            let pubDOI = (result["doi"] as? String)?.replacingOccurrences(of: "https://doi.org/", with: "") ?? ""
            let year = (result["publication_year"] as? Int).map(String.init)
            let pubURL = (result["doi"] as? String) ?? "https://doi.org/\(pubDOI)"
            return PublishedVersionResult(publishedDOI: pubDOI, publishedURL: pubURL, journal: journal, year: year)
        }
        return nil
    }

    /// Unified preprint → published lookup. Tries APIs in order of reliability.
    static func findPublishedVersion(url: String, title: String) async -> PublishedVersionResult? {
        let lower = url.lowercased()
        let doi = extractDOI(from: url)

        // 1. bioRxiv/medRxiv authoritative API
        if lower.contains("biorxiv.org") || lower.contains("medrxiv.org"), let doi {
            if let result = await checkBiorxivPublished(doi: doi) { return result }
        }

        // 2. Crossref relation field (works for any preprint with a Crossref DOI)
        if let doi {
            if let result = await checkCrossrefRelation(doi: doi) { return result }
        }

        // 3. Crossref title search (finds published journal article by title)
        if let result = await searchCrossrefForPublished(title: title) { return result }

        // 4. OpenAlex title search (last resort)
        return await searchOpenAlexForPublished(title: title)
    }

    // MARK: - OpenAlex Metadata

    /// A title-only catalog lookup may enrich a record only when the returned
    /// title is exactly the same normalized identity string. Typography is not
    /// identity: the catalog's `H<sub>2</sub>O<sub>2</sub>`, the library's
    /// `H₂O₂` and a PDF's `H2O2` are one title.
    private static func titlesMatch(_ input: String, _ result: String) -> Bool {
        exactPaperIdentityKey(input) == exactPaperIdentityKey(result)
    }

    private static func exactPaperIdentityKey(_ title: String) -> String {
        title.decodingTitleMarkup()
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search OpenAlex by title to find paper metadata. Free API, excellent preprint coverage.
    static func searchOpenAlexByTitle(_ title: String) async -> CrossrefMetadata? {
        guard let url = makeQueryURL("https://api.openalex.org/works", queryItems: [
            URLQueryItem(name: "search", value: "\"\(title)\""),
            URLQueryItem(name: "per_page", value: "3"),
            URLQueryItem(name: "select", value: "title,authorships,publication_year,primary_location"),
            URLQueryItem(name: "mailto", value: "support@foreverlm.com"),
        ]) else { return nil }
        let json: [String: Any]?
        do {
            json = try await fetchJSONObject(from: url)
        } catch {
            logger.error("searchOpenAlexByTitle: transport failure for title query: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let results = json?["results"] as? [[String: Any]],
              let best = results.first else { return nil }

        if let resultTitle = best["title"] as? String {
            if !titlesMatch(title, resultTitle) { return nil }
        }

        let authorsDisplay = (best["authorships"] as? [[String: Any]]).flatMap { authorships in
            Self.authorsDisplay(from: authorships.compactMap { a -> String? in
                (a["author"] as? [String: Any])?["display_name"] as? String
            })
        }

        var year: String?
        if let y = best["publication_year"] as? Int {
            year = String(y)
        }

        var journal: String?
        if let loc = best["primary_location"] as? [String: Any],
           let source = loc["source"] as? [String: Any] {
            journal = source["display_name"] as? String
        }

        guard authorsDisplay != nil || year != nil else { return nil }
        let resolvedDOI = (best["doi"] as? String)?.replacingOccurrences(of: "https://doi.org/", with: "")
        let resolvedTitle = best["title"] as? String
        return CrossrefMetadata(authorsDisplay: authorsDisplay, journal: journal, year: year, title: resolvedTitle, doi: resolvedDOI)
    }

    // MARK: - OpenReview Metadata

    /// Fetch paper metadata from the OpenReview API.
    static func fetchOpenReviewMetadata(forumID: String) async -> CrossrefMetadata? {
        guard let url = URL(string: "https://api2.openreview.net/notes?id=\(forumID)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = json["notes"] as? [[String: Any]],
              let note = notes.first,
              let content = note["content"] as? [String: Any] else { return nil }

        let paperTitle = (content["title"] as? [String: Any])?["value"] as? String

        let authorsValue = (content["authors"] as? [String: Any])?["value"] as? [String]
        let authorsDisplay = authorsValue.flatMap(Self.authorsDisplay)

        let venue = ((content["venue"] as? [String: Any])?["value"] as? String)
            ?? ((content["venueid"] as? [String: Any])?["value"] as? String)

        var year: String?
        if let cdate = note["cdate"] as? Double {
            // The Gregorian year, whatever calendar the Mac is set to: a
            // DateFormatter with no calendar follows the device's, and a
            // Buddhist-calendar Mac stored OpenReview papers as year 2569.
            let date = Date(timeIntervalSince1970: cdate / 1000)
            year = String(Calendar(identifier: .gregorian).component(.year, from: date))
        }

        guard authorsDisplay != nil || year != nil || paperTitle != nil else { return nil }
        return CrossrefMetadata(authorsDisplay: authorsDisplay, journal: venue ?? "OpenReview", year: year, title: paperTitle)
    }

    // MARK: - PubMed Central Lookup

    /// Result from a PMC lookup: may contain a direct PDF URL and/or a PMCID for text fallback.
    struct PMCLookupResult {
        let pdfURL: String?
        let pmcid: String?
        let doi: String?

        /// The PDF candidates this lookup names, in the order they are tried:
        /// NCBI's own route for the article first, then the PDF Europe PMC's
        /// record lists (a publisher's open copy, or Europe PMC's own render).
        var orderedPDFURLs: [String] {
            var urls: [String] = []
            if let pmcid, !pmcid.isEmpty {
                urls.append(PaperService.ncbiPMCPDFURL(pmcid: pmcid))
            }
            if let pdfURL, !pdfURL.isEmpty, !urls.contains(pdfURL) {
                urls.append(pdfURL)
            }
            return urls
        }
    }

    /// Query EuropePMC for a DOI and return PMC lookup result.
    static func lookupPMC(doi: String) async -> PMCLookupResult? {
        guard let url = makeQueryURL("https://www.ebi.ac.uk/europepmc/webservices/rest/search", queryItems: [
            URLQueryItem(name: "query", value: europePMCDOIQuery(doi)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "resultType", value: "core"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]) else { return nil }
        return await performPMCLookup(apiURL: url.absoluteString)
    }

    /// Europe PMC's search is Lucene syntax, where a bare `(` opens a group:
    /// `DOI:10.1016/s0140-6736(04)16983-3` matched nothing (2026-09-28) while
    /// the quoted DOI finds the record. Quoting leaves an ordinary DOI's
    /// answer unchanged.
    static func europePMCDOIQuery(_ doi: String) -> String {
        "DOI:\"\(doi.replacingOccurrences(of: "\"", with: ""))\""
    }

    // MARK: - eLife

    /// An eLife article or reviewed preprint named by its URL: the API path
    /// segment (`articles` or `reviewed-preprints`) and the numeric id.
    struct ELifeArticle: Equatable {
        let collection: String
        let id: String
    }

    /// eLife's pages are a JavaScript app that advertises no `citation_pdf_url`
    /// and answers a request without `Accept-Encoding` with 406, so neither the
    /// page scan nor a path rewrite finds the PDF; on 2026-09-07 an open-access
    /// eLife paper sat in Papers that need attention for that reason. The public
    /// API names the file on eLife's CDN.
    static func eLifeArticle(from urlString: String) -> ELifeArticle? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "elifesciences.org" || host.hasSuffix(".elifesciences.org") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              parts[0] == "articles" || parts[0] == "reviewed-preprints" else { return nil }
        // `93172`, `93172v2`, `93172/figures`: the id is the leading digits.
        let digits = parts[1].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return ELifeArticle(collection: parts[0], id: String(digits))
    }

    /// The PDF eLife's API names for the article, or nil when the API has none
    /// (a reviewed preprint before its version of record) or cannot be reached.
    static func lookupELifePDFURL(_ article: ELifeArticle) async -> String? {
        guard let url = URL(string: "https://api.elifesciences.org/\(article.collection)/\(article.id)") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let pdf = json["pdf"] as? String, isDirectPDFURL(pdf) { return pdf }
            // A reviewed preprint's versions carry their own files.
            if let versions = json["versions"] as? [[String: Any]],
               let pdf = versions.reversed().compactMap({ $0["pdf"] as? String }).first,
               isDirectPDFURL(pdf) {
                return pdf
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Query EuropePMC by PMCID and return PMC lookup result.
    static func lookupPMCByPMCID(pmcid: String) async -> PMCLookupResult? {
        let apiURL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=PMCID:\(pmcid)&format=json&resultType=core&pageSize=1"
        return await performPMCLookup(apiURL: apiURL)
    }

    /// Query EuropePMC by PubMed ID (PMID) and return PMC lookup result.
    static func lookupPMCByPMID(pmid: String) async -> PMCLookupResult? {
        let apiURL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=EXT_ID:\(pmid)%20AND%20SRC:MED&format=json&resultType=core&pageSize=1"
        return await performPMCLookup(apiURL: apiURL)
    }

    /// Shared EuropePMC lookup logic.
    private static func performPMCLookup(apiURL: String) async -> PMCLookupResult? {
        guard let url = URL(string: apiURL) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultList = json["resultList"] as? [String: Any],
                  let results = resultList["result"] as? [[String: Any]],
                  let first = results.first else { return nil }

            let pmcid = first["pmcid"] as? String
            let doi = first["doi"] as? String

            // Try fullTextUrlList: prefer OA PDF from non-publisher sources
            if let urlListWrapper = first["fullTextUrlList"] as? [String: Any],
               let urlList = urlListWrapper["fullTextUrl"] as? [[String: Any]] {
                // Prefer non-EuropePMC sources (direct publisher OA PDFs)
                let preferredCandidates = urlList.filter { entry in
                    let style = entry["documentStyle"] as? String ?? ""
                    let site = entry["site"] as? String ?? ""
                    let avail = entry["availabilityCode"] as? String ?? ""
                    return style == "pdf"
                        && (avail == "OA" || avail == "F")
                        && site != "DOI"
                        && site != "Europe_PMC"
                        && !(entry["url"] as? String ?? "").contains("ptpmcrender")
                }
                if let best = preferredCandidates.first, let pdfURL = best["url"] as? String {
                    return PMCLookupResult(pdfURL: pdfURL, pmcid: pmcid, doi: doi)
                }
                // Fallback: accept any remaining OA PDF (EuropePMC rendered, ptpmcrender, etc.)
                let fallbackCandidates = urlList.filter { entry in
                    let style = entry["documentStyle"] as? String ?? ""
                    let avail = entry["availabilityCode"] as? String ?? ""
                    return style == "pdf"
                        && (avail == "OA" || avail == "F")
                }
                if let best = fallbackCandidates.first, let pdfURL = best["url"] as? String {
                    return PMCLookupResult(pdfURL: pdfURL, pmcid: pmcid, doi: doi)
                }
            }

            // No direct PDF URL found, but we have the PMCID for text fallback
            guard let pmcid, !pmcid.isEmpty else { return nil }
            return PMCLookupResult(pdfURL: nil, pmcid: pmcid, doi: doi)
        } catch {
            return nil
        }
    }

    /// Fetch full text of a PMC article via the NCBI BioC API.
    /// Returns the concatenated passage text, or nil if the article is not available.
    static func fetchPMCFullText(pmcid: String) async -> String? {
        let apiURL = "https://www.ncbi.nlm.nih.gov/research/bionlp/RESTful/pmcoa.cgi/BioC_json/\(pmcid)/unicode"
        guard let url = URL(string: apiURL) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            guard let collections = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

            var passages: [String] = []
            for collection in collections {
                guard let documents = collection["documents"] as? [[String: Any]] else { continue }
                for document in documents {
                    guard let docPassages = document["passages"] as? [[String: Any]] else { continue }
                    for passage in docPassages {
                        if let text = passage["text"] as? String, !text.isEmpty {
                            passages.append(text)
                        }
                    }
                }
            }

            let fullText = passages.joined(separator: "\n\n")
            return fullText.isEmpty ? nil : fullText
        } catch {
            return nil
        }
    }

    /// Fetch full text of a PMC article via the NCBI efetch API (JATS XML).
    /// Works for all PMC articles (not just the open-access subset that BioC covers).
    static func fetchPMCFullTextViaEfetch(pmcid: String) async -> String? {
        let pmcNumber = pmcid.hasPrefix("PMC") ? pmcid : "PMC\(pmcid)"
        let apiURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pmc&id=\(pmcNumber)&rettype=full&retmode=xml"
        guard let url = URL(string: apiURL) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            guard let xml = String(data: data, encoding: .utf8), xml.contains("<article") else { return nil }

            return extractTextFromJATSXML(xml)
        } catch {
            return nil
        }
    }

    /// Extract readable text from JATS XML (title, abstract, body sections).
    private static func extractTextFromJATSXML(_ xml: String) -> String? {
        let parser = JATSXMLParser(xml: xml)
        let text = parser.parse()
        return text.split(separator: " ").count >= 100 ? text : nil
    }

    // MARK: - Unpaywall API

    /// Query the Unpaywall API for an open-access PDF URL given a DOI.
    /// Free API — no key required, just an email for polite usage.
    /// Returns Unpaywall's preferred open-access PDF URL, or nil if unavailable.
    /// Callers performing a download should use `lookupUnpaywallPDFURLs` and try
    /// every candidate, because Unpaywall ranks scholarly copies rather than
    /// testing whether each URL is reachable by an unattended client.
    static func lookupUnpaywall(doi: String) async -> String? {
        await lookupUnpaywallPDFURLs(doi: doi).first
    }

    /// Return every PDF URL advertised by Unpaywall in its declared preference
    /// order. A candidate is only a lead: callers must download it, validate the
    /// PDF bytes, and continue to the next URL after any transport/content failure.
    static func lookupUnpaywallPDFURLs(doi: String) async -> [String] {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        let apiURL = "https://api.unpaywall.org/v2/\(encoded)?email=support@foreverlm.com"
        guard let url = URL(string: apiURL) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            return unpaywallPDFURLs(from: json)
        } catch {
            return []
        }
    }

    static func unpaywallPDFURLs(from json: [String: Any]) -> [String] {
        if let isOA = json["is_oa"] as? Bool, !isOA { return [] }

        var locations: [[String: Any]] = []
        if let best = json["best_oa_location"] as? [String: Any] {
            locations.append(best)
        }
        locations.append(contentsOf: json["oa_locations"] as? [[String: Any]] ?? [])

        var seen = Set<String>()
        return locations.compactMap { location in
            guard let pdfURL = location["url_for_pdf"] as? String,
                  let url = URL(string: pdfURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !pdfURL.isEmpty else { return nil }

            let canonical = canonicalAlternativeURL(pdfURL)
            guard seen.insert(canonical).inserted else { return nil }
            return pdfURL
        }
    }

    // MARK: - OpenAlex open-access locations

    /// Every open-access copy OpenAlex lists for a DOI, as candidates to try.
    /// Empty when OpenAlex has none or cannot be reached.
    static func lookupOpenAlexOpenAccessURLs(doi: String) async -> [String] {
        let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.openalex.org/works/https://doi.org/\(encodedDOI)?select=best_oa_location,locations&mailto=support@foreverlm.com") else {
            return []
        }
        do {
            guard let work = try await fetchJSONObject(from: url, timeout: 10) else { return [] }
            return openAlexOpenAccessURLs(from: work)
        } catch {
            return []
        }
    }

    /// The candidates an OpenAlex work's open-access locations name, in the
    /// order they are tried: every location's own PDF first, then PubMed
    /// Central article pages, then other repositories' landing pages.
    ///
    /// Not only `best_oa_location`. A green copy is often listed with a landing
    /// page and no `pdf_url` — a HAL record, a DSpace `hdl.handle.net` item, a
    /// PMC page marked `submittedVersion` — and those pages lead to the file:
    /// a PMC page becomes NCBI's PDF route in the resolvers, and a repository
    /// page is scanned for its `citation_pdf_url`. A publisher's own landing
    /// page is left out: it is the page the paper was already fetched from.
    /// Whatever a candidate yields is downloaded and checked for PDF bytes, so a
    /// page is never taken for the paper.
    static func openAlexOpenAccessURLs(from work: [String: Any]) -> [String] {
        var locations: [[String: Any]] = []
        if let best = work["best_oa_location"] as? [String: Any] { locations.append(best) }
        locations.append(contentsOf: work["locations"] as? [[String: Any]] ?? [])

        func httpURL(_ value: Any?) -> String? {
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let scheme = URLComponents(string: string)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return string
        }

        var pdfs: [String] = []
        var pmcPages: [String] = []
        var laterPDFs: [String] = []
        var repositoryPages: [String] = []
        for location in locations {
            guard location["is_oa"] as? Bool == true else { continue }
            if let pdf = httpURL(location["pdf_url"]) {
                guard !isSupplementaryPDFURL(pdf) else { continue }
                // Europe PMC's render of a PMC article goes after NCBI's own
                // route for the same article, as everywhere else.
                if isEuropePMCRenderedPDFURL(pdf), let pmcid = pmcidInEuropePMCURL(pdf) {
                    pmcPages.append(pmcArticleURL(for: pmcid))
                    laterPDFs.append(pdf)
                } else {
                    pdfs.append(pdf)
                }
                continue
            }
            guard let landing = httpURL(location["landing_page_url"]) else { continue }
            if let pmcid = extractPMCID(from: landing) {
                pmcPages.append(pmcArticleURL(for: pmcid))
                continue
            }
            let sourceType = (location["source"] as? [String: Any])?["type"] as? String
            if sourceType == "repository" {
                repositoryPages.append(landing)
            }
        }

        var seen = Set<String>()
        return (pdfs + pmcPages + laterPDFs + repositoryPages).filter {
            seen.insert(canonicalAlternativeURL($0)).inserted
        }
    }

    /// The PMCID in a Europe PMC address (`/articles/pmc6212323`, `accid=PMC6212323`).
    private static func pmcidInEuropePMCURL(_ urlString: String) -> String? {
        guard let range = urlString.range(of: #"PMC\d+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return "PMC" + urlString[range].dropFirst(3)
    }

    // MARK: - Open-Access Alternative Lookup

    struct OpenAccessAlternativeResult {
        let replacementURL: String
        let sourceName: String
    }

    static func findOpenAccessAlternative(
        url: String,
        title: String,
        doi storedDOI: String? = nil
    ) async -> OpenAccessAlternativeResult? {
        await findOpenAccessAlternatives(url: url, title: title, doi: storedDOI).first
    }

    /// Discover all legitimate OA leads without pretending discovery proves
    /// downloadability. Publisher anti-bot challenges, expiring links, mirrors,
    /// and repository lag are normal on the scholarly web, so the consumer must
    /// attempt and validate each result until one succeeds.
    static func findOpenAccessAlternatives(
        url: String,
        title: String,
        doi storedDOI: String? = nil
    ) async -> [OpenAccessAlternativeResult] {
        let currentURL = canonicalAlternativeURL(url)
        let doi = openAccessLookupDOI(url: url, storedDOI: storedDOI)
        var results: [OpenAccessAlternativeResult] = []
        var seen = Set([currentURL])

        func append(_ replacementURL: String, sourceName: String? = nil) {
            let canonical = canonicalAlternativeURL(replacementURL)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { return }
            results.append(
                OpenAccessAlternativeResult(
                    replacementURL: replacementURL,
                    sourceName: sourceName ?? sourceDisplayName(for: replacementURL)
                )
            )
        }

        // The indexes are independent, so they are asked at once: asked one
        // after another, each with its own 10–15 s timeout, a single paper's
        // lookups outran the 60 s an MCP call has (2026-09-23). The order in
        // which their answers are appended below is the order candidates are
        // tried, and it is unchanged by asking in parallel.
        async let biorxivPublished: [OpenAccessAlternativeResult] = { () async -> [OpenAccessAlternativeResult] in
            guard let doi, isBiorxivOrMedrxivDOI(doi),
                  let published = await checkBiorxivPublished(doi: doi) else { return [] }
            var found = await lookupUnpaywallPDFURLs(doi: published.publishedDOI).map {
                OpenAccessAlternativeResult(replacementURL: $0, sourceName: sourceDisplayName(for: $0))
            }
            if await pageAdvertisesOpenAccessPDF(at: published.publishedURL) {
                found.append(OpenAccessAlternativeResult(replacementURL: published.publishedURL, sourceName: published.journal))
            }
            return found
        }()
        async let pmcByDOI: PMCLookupResult? = { () async -> PMCLookupResult? in
            guard let doi else { return nil }
            return await lookupPMC(doi: doi)
        }()
        async let unpaywallURLs: [String] = { () async -> [String] in
            guard let doi else { return [] }
            return await lookupUnpaywallPDFURLs(doi: doi)
        }()
        async let openAlexURLs: [String] = { () async -> [String] in
            guard let doi else { return [] }
            return await lookupOpenAlexOpenAccessURLs(doi: doi)
        }()
        async let pmcByPMID: PMCLookupResult? = { () async -> PMCLookupResult? in
            guard let pmid = extractPMID(from: url) else { return nil }
            return await lookupPMCByPMID(pmid: pmid)
        }()
        async let preprint = findPreprintVersion(url: url, title: title, doi: doi)

        for alternative in await biorxivPublished {
            append(alternative.replacementURL, sourceName: alternative.sourceName)
        }

        // A PMC record is offered as the article's page, which the PDF
        // resolvers turn into NCBI's own route first; the PDF Europe PMC's
        // record names comes after it.
        func appendPMC(_ result: PMCLookupResult?) {
            guard let result else { return }
            if let pmcid = result.pmcid {
                append(pmcArticleURL(for: pmcid), sourceName: "PubMed Central")
            }
            if let pdfURL = result.pdfURL {
                append(pdfURL)
            }
        }
        appendPMC(await pmcByDOI)

        for unpaywallURL in await unpaywallURLs {
            append(unpaywallURL)
        }

        for openAlexURL in await openAlexURLs {
            append(openAlexURL)
        }

        appendPMC(await pmcByPMID)

        if let pmcid = extractPMCID(from: url) {
            append(pmcArticleURL(for: pmcid), sourceName: "PubMed Central")
        }

        if let preprint = await preprint {
            if let pdfURL = preprint.pdfURL {
                append(pdfURL, sourceName: preprint.server)
            }
            append(preprint.preprintURL, sourceName: preprint.server)
        }

        return results
    }

    /// Prefer the catalog's durable DOI over reconstructing one from the source
    /// URL. Publisher landing URLs frequently do not contain the DOI even though
    /// paper metadata does, and those are exactly the records most likely to need
    /// a later open-access recheck.
    static func openAccessLookupDOI(url: String, storedDOI: String?) -> String? {
        if let storedDOI, let normalized = normalizeExtractedDOI(storedDOI) {
            return normalized
        }
        return extractDOI(from: url)
    }

    private static func isBiorxivOrMedrxivDOI(_ doi: String) -> Bool {
        let lower = doi.lowercased()
        return lower.hasPrefix("10.1101/") || lower.hasPrefix("10.64898/")
    }

    private static func pmcArticleURL(for pmcid: String) -> String {
        let normalized = pmcid.hasPrefix("PMC") ? pmcid : "PMC\(pmcid)"
        return "https://pmc.ncbi.nlm.nih.gov/articles/\(normalized)/"
    }

    private static func canonicalAlternativeURL(_ url: String) -> String {
        url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func sourceDisplayName(for urlString: String) -> String {
        let lower = urlString.lowercased()
        if lower.contains("pmc.ncbi.nlm.nih.gov") || lower.contains("ncbi.nlm.nih.gov/pmc/") {
            return "PubMed Central"
        }
        if lower.contains("biorxiv.org") { return "bioRxiv" }
        if lower.contains("medrxiv.org") { return "medRxiv" }
        if lower.contains("arxiv.org") { return "arXiv" }
        if lower.contains("openreview.net") { return "OpenReview" }
        if let host = URLComponents(string: urlString)?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "open-access source"
    }

    // MARK: - Preprint Lookup (Published → Preprint)

    /// Result of finding a preprint version of a published paper.
    struct PreprintResult {
        let preprintURL: String
        let pdfURL: String?
        let server: String  // e.g. "arXiv", "bioRxiv"
    }

    /// Find a preprint version of a published paper. Searches Crossref (has-preprint relation),
    /// then OpenAlex for preprint locations on arXiv, bioRxiv, medRxiv, etc.
    static func findPreprintVersion(
        url: String,
        title: String,
        doi storedDOI: String? = nil
    ) async -> PreprintResult? {
        let doi = openAccessLookupDOI(url: url, storedDOI: storedDOI)

        // 1. Crossref `relation.has-preprint` field (most authoritative)
        if let doi, let result = await checkCrossrefHasPreprint(doi: doi) { return result }

        // 2. OpenAlex: look for preprint locations or alternate versions
        if let result = await searchOpenAlexForPreprint(title: title, doi: doi) { return result }

        // 3. arXiv title search as last resort
        if let result = await searchArxivByTitle(title) { return result }

        return nil
    }

    /// Check Crossref for a `has-preprint` relation on a published DOI.
    private static func checkCrossrefHasPreprint(doi: String) async -> PreprintResult? {
        // The single-work route takes no `select`: with one it answers 400
        // ("This route does not support select"), so this step never found a
        // preprint until 2026-09-28.
        guard let url = URL(string: "https://api.crossref.org/works/\(doi)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ForeverLM/1.0 (mailto:flashcards@foreverlm.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let relation = msg["relation"] as? [String: Any] else { return nil }

        guard let links = relation["has-preprint"] as? [[String: Any]] else { return nil }
        for link in links {
            guard let preprintDOI = link["id"] as? String, !preprintDOI.isEmpty else { continue }
            let preprintURL = "https://doi.org/\(preprintDOI)"
            let pdfURL = paperPDFURL(from: preprintURL)
            let server = classifyPreprintServer(doi: preprintDOI, url: preprintURL)
            return PreprintResult(preprintURL: preprintURL, pdfURL: pdfURL, server: server)
        }
        return nil
    }

    /// Search OpenAlex for a preprint version of a paper (by DOI or title).
    private static func searchOpenAlexForPreprint(title: String, doi: String?) async -> PreprintResult? {
        // Try DOI lookup first (exact match)
        if let doi {
            let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
            if let url = URL(string: "https://api.openalex.org/works/https://doi.org/\(encodedDOI)?select=locations,title,best_oa_location&mailto=support@foreverlm.com") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = extractPreprintFromOpenAlexWork(json) {
                    return result
                }
            }
        }

        // Fall back to title search
        guard let url = makeQueryURL("https://api.openalex.org/works", queryItems: [
            URLQueryItem(name: "search", value: "\"\(title)\""),
            URLQueryItem(name: "per_page", value: "5"),
            URLQueryItem(name: "select", value: "title,doi,locations,best_oa_location"),
            URLQueryItem(name: "mailto", value: "support@foreverlm.com"),
        ]) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        for work in results {
            guard let resultTitle = work["title"] as? String, titlesMatch(title, resultTitle) else { continue }
            if let result = extractPreprintFromOpenAlexWork(work) { return result }
        }
        return nil
    }

    /// Extract a preprint location from an OpenAlex work object.
    private static func extractPreprintFromOpenAlexWork(_ work: [String: Any]) -> PreprintResult? {
        guard let locations = work["locations"] as? [[String: Any]] else { return nil }
        for loc in locations {
            guard let source = loc["source"] as? [String: Any],
                  let sourceName = source["display_name"] as? String,
                  isPreprintVenue(sourceName) else { continue }
            // Prefer the PDF URL if available
            let landingURL = loc["landing_page_url"] as? String
            let pdfURL = loc["pdf_url"] as? String
            guard let preprintURL = landingURL ?? pdfURL else { continue }
            let resolvedPDF = pdfURL ?? paperPDFURL(from: preprintURL)
            return PreprintResult(preprintURL: preprintURL, pdfURL: resolvedPDF, server: sourceName)
        }
        return nil
    }

    /// Search the arXiv API by title.
    private static func searchArxivByTitle(_ title: String) async -> PreprintResult? {
        guard let url = makeQueryURL("https://export.arxiv.org/api/query", queryItems: [
            URLQueryItem(name: "search_query", value: "ti:\"\(title)\""),
            URLQueryItem(name: "max_results", value: "3"),
        ]) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return nil }

        // Simple XML extraction — arXiv API returns Atom feed
        let entries = xml.components(separatedBy: "<entry>").dropFirst()
        for entry in entries {
            // Extract title
            guard let titleStart = entry.range(of: "<title>"),
                  let titleEnd = entry.range(of: "</title>") else { continue }
            let entryTitle = String(entry[titleStart.upperBound..<titleEnd.lowerBound])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard titlesMatch(title, entryTitle) else { continue }

            // Extract abs URL from <id> tag
            guard let idStart = entry.range(of: "<id>"),
                  let idEnd = entry.range(of: "</id>") else { continue }
            let absURL = String(entry[idStart.upperBound..<idEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            let pdfURL = paperPDFURL(from: absURL)
            return PreprintResult(preprintURL: absURL, pdfURL: pdfURL, server: "arXiv")
        }
        return nil
    }

    /// Classify which preprint server a DOI or URL belongs to.
    private static func classifyPreprintServer(doi: String, url: String) -> String {
        let lower = (doi + url).lowercased()
        if lower.contains("arxiv") { return "arXiv" }
        if lower.contains("10.1101") || lower.contains("biorxiv") { return "bioRxiv" }
        if lower.contains("medrxiv") { return "medRxiv" }
        if lower.contains("ssrn") { return "SSRN" }
        if lower.contains("chemrxiv") { return "ChemRxiv" }
        return "Preprint"
    }
}

// MARK: - JATS XML Parser

/// Lightweight parser that extracts readable text from NCBI JATS XML.
/// Pulls title, abstract, and body sections without deleting nested source text.
private final class JATSXMLParser: NSObject, XMLParserDelegate {
    private let xmlString: String
    private var sections: [String] = []
    private var currentText = ""
    private var capturing = false
    private var depth = 0
    // Elements whose text content we want to capture
    private static let captureRoots: Set<String> = ["article-title", "abstract", "body"]

    init(xml: String) {
        self.xmlString = xml
    }

    func parse() -> String {
        guard let data = xmlString.data(using: .utf8) else { return "" }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return sections.joined(separator: "\n\n")
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if Self.captureRoots.contains(element) {
            capturing = true
            depth = 1
            currentText = ""
        } else if capturing {
            depth += 1
            // Add whitespace for block-level elements
            if element == "p" || element == "sec" || element == "title" {
                if !currentText.isEmpty && !currentText.hasSuffix("\n") {
                    currentText += "\n"
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if capturing {
            if Self.captureRoots.contains(element) {
                let trimmed = currentText
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !trimmed.isEmpty {
                    sections.append(trimmed)
                }
                capturing = false
                currentText = ""
                depth = 0
            } else {
                depth -= 1
                if element == "p" || element == "title" {
                    currentText += "\n"
                }
            }
        }
    }
}
