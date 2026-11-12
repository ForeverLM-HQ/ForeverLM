// The in-app web session, publisher PDF download and web content extraction behind source fetching.
import Foundation
import PDFKit
import os
import WebKit

private let logger = Logger(subsystem: "com.foreverlm", category: "SourceService")

// MARK: - WKWebView Content Extractor (macOS)

#if os(macOS)
/// Extracts article text by loading a URL in a hidden WKWebView, allowing
/// JavaScript to render, then reading `document.body.innerText`.
/// The cookie jar every in-app web view shares, read for ForeverLM's own
/// HTTP requests.
///
/// The reader is a real browsing session on `WKWebsiteDataStore.default()`, so
/// a learner who signs in to a publisher there has, from that moment, access
/// that ForeverLM's `URLSession` fetches knew nothing about: `URLSession` keeps
/// its own `HTTPCookieStorage`, and the two never meet. That is why a paper the
/// learner could read on screen still came back "paywalled" when the app went
/// for its PDF. Requests that carry these cookies are made as the signed-in
/// learner, exactly as the reader's own loads are.
enum InAppWebSession {
    /// The cookies the app's web views hold that apply to `url`.
    @MainActor
    static func cookies(for url: URL) async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return applicable(all, to: url)
    }

    /// Ordinary RFC 6265 domain/path/secure/expiry matching.
    nonisolated static func applicable(_ cookies: [HTTPCookie], to url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = url.scheme?.lowercased() == "https"
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches: Bool
            if domain.hasPrefix(".") {
                domainMatches = host == String(domain.dropFirst()) || host.hasSuffix(domain)
            } else {
                domainMatches = host == domain
            }
            guard domainMatches else { return false }
            guard path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path) else { return false }
            if cookie.isSecure, !isSecure { return false }
            if let expires = cookie.expiresDate, expires < Date() { return false }
            return true
        }
    }

    /// Lend the in-app session's cookies to a request, through the jar
    /// `URLSession` itself reads: `HTTPCookieStorage.shared`, which every
    /// download session here is configured on.
    ///
    /// They are not set as a fixed `Cookie` header with cookie handling turned
    /// off, which is how this worked until build 71. A publisher's sign-in
    /// bounce sets cookies in the middle of a redirect chain — nature.com
    /// answers an article or its PDF with a 303 to `idp.nature.com/authorize`,
    /// whose `transit` hop sets fresh `idp_session` cookies and sends the
    /// request back — and a request that neither stores nor sends those is
    /// bounced again, until `URLSession` gives up with "too many HTTP
    /// redirects". That is what every Nature paper's PDF fetch does
    /// without them, subscriber or not. With the cookies in the jar and handling
    /// left on, each hop carries what the previous one set, exactly as the
    /// reader's own web view does.
    nonisolated static func apply(_ cookies: [HTTPCookie], to request: inout URLRequest) {
        guard !cookies.isEmpty else { return }
        let jar = HTTPCookieStorage.shared
        // `URLSession.shared` (the reader's remote-PDF load) keeps the default
        // main-document-only policy; a cookie the sign-in host sets for the
        // publisher's domain must be kept too, or the bounce loops just the same.
        jar.cookieAcceptPolicy = .always
        for cookie in cookies {
            jar.setCookie(cookie)
        }
        request.httpShouldHandleCookies = true
    }
}

// MARK: - Publisher PDF through the reader's web session

/// Whether a publisher's PDF that ForeverLM's own `URLSession` was refused
/// should be fetched again through the reader's web session.
///
/// Some publishers tell a browser from anything else. nature.com answers a
/// `URLSession` request for `/articles/<id>.pdf` with a 3 KB "Client
/// Challenge" page — JavaScript a browser runs and a plain HTTP client
/// cannot — and it does so even when the request carries the cookies the
/// reader holds: the check reads the client, not the jar. The
/// reader's `WKWebView` passes it, which is why a Nature Neuroscience paper
/// showed its full text on screen under a Nature+ subscription while the
/// pipeline reported "Failed to fetch source content" for its PDF.
/// A `WKDownload` started from a hidden web view on the same
/// `WKWebsiteDataStore` is the reader's own Download PDF, so it is answered
/// the way the reader is.
///
/// The decision is deliberately narrow, and every gate is a fact the caller
/// already knows: the paper has no PDF yet, the file is the paper and not a
/// supplementary one, the app's own request was answered with something other
/// than the file, and the reader holds cookies for the host. Without cookies
/// the learner has never opened the publisher in the reader, and a hidden web
/// view would only meet the wall the download did.
enum WebSessionPDFDownload {
    enum Decision: Equatable {
        case attempt
        case skipped(Reason)
    }

    enum Reason: Equatable, CustomStringConvertible {
        /// The paper already has its file; nothing to fetch.
        case paperHasPDF
        /// A Reporting Summary, Source Data or other supplementary file is
        /// never the paper, whichever client could fetch it.
        case supplementaryFile
        case invalidURL
        /// A 404, a network error, an unreadable PDF: the publisher did not
        /// turn the client away, so another client changes nothing.
        case notARefusedPDFRequest
        /// The reader holds no session for the host.
        case noReaderSession(host: String)
        /// The host's only objection to a plain client is a check the app
        /// answers itself (PubMed Central's proof of work).
        case checkAnsweredByApp(host: String)

        var description: String {
            switch self {
            case .paperHasPDF: return "the paper already has a PDF"
            case .supplementaryFile: return "the file is supplementary material, not the paper"
            case .invalidURL: return "the PDF URL is not a URL"
            case .notARefusedPDFRequest: return "the publisher did not refuse the app's request"
            case .noReaderSession(let host): return "the reader holds no session for \(host)"
            case .checkAnsweredByApp(let host): return "ForeverLM answers \(host)'s download check itself; the reader has nothing more to offer"
            }
        }
    }

    nonisolated static func decision(
        pdfURL: String,
        after error: Error,
        cookies: [HTTPCookie],
        paperHasPDF: Bool
    ) -> Decision {
        if paperHasPDF { return .skipped(.paperHasPDF) }
        guard let url = URL(string: pdfURL), let host = url.host, !host.isEmpty else {
            return .skipped(.invalidURL)
        }
        if PaperService.isSupplementaryPDFURL(pdfURL) { return .skipped(.supplementaryFile) }
        guard publisherRefusedTheFile(error) else { return .skipped(.notARefusedPDFRequest) }
        // PubMed Central is a distinct protocol, not a publisher wall: its only
        // gate for a plain client is the "Preparing to download ..." proof of
        // work, which `downloadPDF` answers, and it has no subscriptions for
        // the reader's cookies to carry. What refuses the app after that — an
        // embargo's 403 — refuses the reader too. The hidden web view never gets
        // a PMC file and spends 15–35 s a paper finding that out.
        if PaperService.isNCBIPMCURL(pdfURL) { return .skipped(.checkAnsweredByApp(host: host)) }
        guard !InAppWebSession.applicable(cookies, to: url).isEmpty else {
            return .skipped(.noReaderSession(host: host))
        }
        return .attempt
    }

    /// The failures that mean the publisher answered the app's request and
    /// declined to hand over the file: an HTML page in place of the PDF
    /// (`fetchFailed` — a bot check or a sign-in page served with 200) or a
    /// 403 (`accessDenied` — a challenge that refuses non-browser clients
    /// outright, as J Neurosci's does). A 404, a network error or a PDF that
    /// would not open are not answered differently by another client.
    nonisolated static func publisherRefusedTheFile(_ error: Error) -> Bool {
        guard let sourceError = SourceError.classifying(error) else { return false }
        switch sourceError {
        case .fetchFailed, .accessDenied: return true
        default: return false
        }
    }
}

/// The script the reader runs behind its Download PDF button, and the one the
/// hidden web view runs on a publisher's page: find the page's own PDF control
/// and click it.
///
/// Shared so that the two agree on what a PDF control is. A supplementary file
/// (Reporting Summary, Source Data) is never a candidate, whatever its link text;
/// among the rest, a control that calls itself Download PDF wins. A bare PDF
/// link is usable only when its URL carries the current article's identity;
/// bibliography links are never controls. This matters on publisher pages that
/// link to cited papers as PDFs before rendering their own download action.
/// The click is dispatched as real mouse events so a link with a `download`
/// attribute becomes a download and a link the page handles in script still
/// runs its handler.
enum PublisherPDFDownloadControl {
    static let clickScript: String = """
    (() => {
      const absolute = (value) => {
        if (!value) return '';
        try { return new URL(value, document.baseURI).href; } catch (e) { return value || ''; }
      };
      const supplementary = new RegExp(\(jsStringLiteral(PaperService.supplementaryPDFURLJavaScriptPattern)), 'i');
      const pageURL = (() => {
        try { return new URL(document.baseURI); } catch (e) { return new URL(window.location.href); }
      })();
      const ignoredPathTokens = new Set([
        'article', 'articles', 'content', 'download', 'fulltext', 'journal', 'journals',
        'paper', 'papers', 'reference', 'references'
      ]);
      const identityTokens = (value) => {
        try { value = decodeURIComponent(value); } catch (e) {}
        return String(value || '').toLowerCase().split(/[^a-z0-9]+/).filter((token) =>
          token.length >= 5 && !ignoredPathTokens.has(token) && !/^\\d{4}$/.test(token)
        );
      };
      const pageIdentity = new Set(identityTokens(pageURL.pathname + pageURL.search));
      const belongsToThisArticle = (url) => {
        const candidateIdentity = identityTokens(url.pathname + url.search);
        return candidateIdentity.some((token) => pageIdentity.has(token));
      };
      const isBibliographyLink = (node) => Boolean(node.closest(
        '[role="doc-bibliography"], [role="doc-biblioentry"], ol.references, ul.references, ' +
        '[class*="article-references" i], [class*="bibliography" i], [class*="reference-list" i], ' +
        '[id*="article-references" i], [id*="bibliography" i], [id*="reference-list" i]'
      ));
      const nodes = Array.from(document.querySelectorAll('a[href]'));
      const candidates = nodes.flatMap((node) => {
        const href = absolute(node.href || node.getAttribute('href') || node.getAttribute('data-href'));
        const declaredType = node.getAttribute('type') || '';
        if (supplementary.test(href) || isBibliographyLink(node)) return [];
        if (!/\\.pdf(?:[?#]|$)/i.test(href) && declaredType.toLowerCase() !== 'application/pdf') return [];
        let url;
        try { url = new URL(href, document.baseURI); } catch (e) { return []; }
        const label = (node.textContent || '') + ' ' +
          (node.getAttribute('aria-label') || '') + ' ' + (node.getAttribute('title') || '');
        const explicitlyNamed = /\\b(?:download|view|read|get)\\s+(?:the\\s+)?pdf\\b/i.test(label) ||
          /\\bpdf\\s+(?:download|version)\\b/i.test(label);
        return [{ node, explicitlyNamed, articleLocal: belongsToThisArticle(url) }];
      });

      const best = candidates.find((candidate) => candidate.explicitlyNamed) ||
        candidates.find((candidate) => candidate.articleLocal);
      if (!best) return false;
      best.node.scrollIntoView({ block: 'center', inline: 'center' });
      best.node.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
      best.node.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
      best.node.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      return true;
    })();
    """

    /// A Swift string as a JavaScript string literal, quotes included.
    static func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode([value])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        // `["…"]` → `"…"`
        return String(array.dropFirst().dropLast())
    }
}

/// Downloads a publisher's PDF through a hidden `WKWebView` on
/// `WKWebsiteDataStore.default()`: the reader's session and the reader's
/// client, with no window.
///
/// Three routes, in order, each taken only when the one before came back as a
/// page rather than the file.
///
/// 1. A `WKDownload` started directly for the PDF URL, which is the whole story
///    for a publisher whose only objection was the client.
/// 2. The paper's own page, loaded as the reader loads it, and a click on the
///    page's Download PDF control — the reader's Download PDF, without the
///    reader. This is the route nature.com needs: measured, a
///    bare request for `/articles/<id>.pdf` is answered with a 303 to the
///    article page whatever client, cookies or Referer it carries, while the
///    page's own control (`/articles/<id>_reference.pdf`, a `download` link)
///    hands over the file. A bot check the page shows first gets its wait
///    budget, since it clears itself and reloads.
/// 3. The PDF URL loaded as a navigation, for a page whose control could not be
///    found: the publisher's script runs, and a PDF response that follows is
///    turned into a download the way the reader turns one.
///
/// A page that stays a page — the publisher's sign-in or purchase wall — ends
/// the attempt with `SourceError.fetchFailed`, which every caller already reads
/// as "not the file".
@MainActor
final class WebSessionPDFDownloader: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    /// A download keeps itself here until it finishes; nothing else holds the
    /// web view or its delegate.
    private static var active = Set<WebSessionPDFDownloader>()

    /// How long a page may keep showing a bot check before the attempt is
    /// given up. A managed challenge that clears on its own does so within a
    /// few seconds and reloads; one that wants a click never will.
    static let challengeWaitBudget: TimeInterval = 12

    /// How long a rendered page is given to redirect or reload itself before
    /// it is read as the publisher's answer. A challenge the detector does not
    /// know by name still gets to run its script.
    static let pageSettleGrace: Duration = .seconds(3)

    /// How long a clicked control has to start a navigation or a download
    /// before the click is read as having done nothing.
    static let clickResponseGrace: Duration = .seconds(8)

    /// `landingPage` is the paper's own page, whose Download PDF control is
    /// clicked when the direct download comes back as a page. Without one, the
    /// page is taken to be the PDF URL without its `.pdf`, which is how Nature,
    /// Springer and Science lay theirs out; a host that does not is simply a
    /// page that fails to load, and the PDF URL is tried as a navigation.
    static func download(_ url: URL, landingPage: URL? = nil, timeout: TimeInterval = 90) async throws -> Data {
        let downloader = WebSessionPDFDownloader(url: url, landingPage: landingPage ?? landingPageURL(forPDF: url))
        active.insert(downloader)
        defer { active.remove(downloader) }
        // A caller with a deadline (an MCP batch has 60 s) cancels its task;
        // the web view is torn down then rather than at its own timeout.
        return try await withTaskCancellationHandler {
            try await downloader.run(timeout: timeout)
        } onCancel: {
            Task { @MainActor in downloader.finish(.failure(CancellationError())) }
        }
    }

    /// The paper's page implied by its PDF URL: the same path without the
    /// `.pdf`, query and fragment dropped. Nil when the URL is not a `.pdf`.
    nonisolated static func landingPageURL(forPDF url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "pdf",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = url.deletingPathExtension().path
        guard !path.isEmpty, path != "/" else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The reader's rule for turning a response into a download rather than a
    /// page: a PDF (WebKit would otherwise render it in place), anything it
    /// cannot show, or an attachment.
    nonisolated static func responseIsDownload(
        mimeType: String?,
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> Bool {
        let mime = mimeType?.lowercased() ?? ""
        if mime == "application/pdf" || !canShowMIMEType { return true }
        if let disposition = contentDisposition?.lowercased(),
           disposition.contains("attachment") || disposition.contains(".pdf") {
            return true
        }
        return false
    }

    private enum Phase {
        /// Route 1: a `WKDownload` for the PDF URL.
        case directDownload
        /// Route 2: the paper's page is loading; its control is clicked once
        /// the page has settled.
        case landingPage
        /// Route 2: the control was clicked; a download or a navigation is
        /// expected to follow.
        case controlClicked
        /// Route 3: the PDF URL as a navigation.
        case pdfNavigation
    }

    private let url: URL
    private let landingPage: URL?
    private var phase: Phase = .directDownload
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingDownloadURL: URL?
    private var timeoutTask: Task<Void, Never>?
    private var challengeFirstSeenAt: Date?
    /// The title of the last page the web view rendered, for the error.
    private var lastPageTitle: String?
    /// Bumped by every navigation start, so a page inspection scheduled for
    /// one document is dropped when the page has moved on.
    private var navigationGeneration = 0

    private init(url: URL, landingPage: URL?) {
        self.url = url
        self.landingPage = landingPage
        super.init()
    }

    private func run(timeout: TimeInterval) async throws -> Data {
        if Task.isCancelled { throw CancellationError() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = SharedWebKit.desktopSafariUserAgent
        webView = wv

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public) timed out")
                self.finish(.failure(PDFFetchRefusal.readerSession(
                    host: self.url.host ?? self.url.absoluteString, pageTitle: nil, timedOut: true
                )))
            }
            self.startDirectDownload(in: wv)
        }
    }

    private func request(for target: URL) -> URLRequest {
        var request = URLRequest(url: target)
        request.timeoutInterval = 60
        return request
    }

    private func startDirectDownload(in webView: WKWebView) {
        webView.startDownload(using: request(for: url)) { download in
            download.delegate = self
        }
    }

    /// The direct download came back as a page. Open the paper's page as the
    /// reader and click its Download PDF control.
    private func beginLandingPageRoute() {
        guard continuation != nil, let webView else { return }
        guard let landingPage else {
            beginPDFNavigationRoute()
            return
        }
        phase = .landingPage
        challengeFirstSeenAt = nil
        logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public) came back as a page; opening \(landingPage.absoluteString, privacy: .public) as the reader to click its PDF control")
        webView.load(request(for: landingPage))
    }

    /// No control to click, or the click went nowhere. Load the PDF URL as a
    /// navigation so the publisher's script can run; a PDF response then
    /// becomes a download through `decidePolicyFor navigationResponse`.
    private func beginPDFNavigationRoute() {
        guard continuation != nil, let webView else { return }
        phase = .pdfNavigation
        challengeFirstSeenAt = nil
        logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public): loading the PDF URL as the reader")
        webView.load(request(for: url))
    }

    /// The route that follows a page where the file was expected.
    private func pageInsteadOfFile() {
        switch phase {
        case .directDownload:
            beginLandingPageRoute()
        case .landingPage, .controlClicked:
            beginPDFNavigationRoute()
        case .pdfNavigation:
            logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public) ended on a page, not the file")
            finish(.failure(PDFFetchRefusal.readerSession(
                host: url.host ?? url.absoluteString, pageTitle: lastPageTitle, timedOut: false
            )))
        }
    }

    fileprivate func finish(_ result: Result<Data, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        cont.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Only the document itself can be the file; an ad frame that serves
        // something WebKit cannot show is not a PDF download.
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        // A publisher's Cloudflare check never clears under the Safari user
        // agent; the page is asked for again under WebKit's own.
        if SharedWebKit.retryCloudflareChallengeWithWebKitUserAgent(navigationResponse, in: webView) {
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if Self.responseIsDownload(
            mimeType: navigationResponse.response.mimeType,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            contentDisposition: disposition
        ) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, phase != .directDownload else { return }
        let generation = navigationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pageSettleGrace)
            guard let self, self.continuation != nil, self.webView === webView,
                  self.navigationGeneration == generation, self.pendingDownloadURL == nil else { return }
            await self.inspectRenderedPage(in: webView, generation: generation)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if SharedWebKit.isCloudflareRetryInterruption(error, in: webView) { return }
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        // Turning a response into a download cancels the navigation that
        // fetched it; the download carries on.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        switch phase {
        case .directDownload:
            return
        case .landingPage, .controlClicked:
            // The page would not load, or the click led nowhere: the PDF URL
            // itself is the last route.
            beginPDFNavigationRoute()
        case .pdfNavigation:
            finish(.failure(error))
        }
    }

    // MARK: WKUIDelegate

    /// A control that opens the file in a new window opens it here instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = navigationAction.request.url, target.scheme?.hasPrefix("http") == true {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private static let pageProbeJS = """
    (function() {
        return {
            title: document.title || '',
            text: document.body ? (document.body.innerText || '') : '',
            url: location.href
        };
    })()
    """

    /// The navigation rendered a page and it has had time to move on. A bot
    /// check still on screen gets its wait budget. On the paper's page, the
    /// Download PDF control is clicked. Anywhere else a page is the
    /// publisher's answer, and it is not the file.
    private func inspectRenderedPage(in webView: WKWebView, generation: Int) async {
        let probe = try? await webView.evaluateJavaScript(Self.pageProbeJS)
        guard continuation != nil, self.webView === webView,
              navigationGeneration == generation, pendingDownloadURL == nil else { return }
        if let title = (probe as? [String: Any])?["title"] as? String {
            lastPageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let probe = probe as? [String: Any],
           SourceDiscovery.isSecurityVerificationPage(
               title: probe["title"] as? String ?? "",
               visibleText: probe["text"] as? String ?? "",
               url: probe["url"] as? String ?? ""
           ) {
            let firstSeen = challengeFirstSeenAt ?? Date()
            challengeFirstSeenAt = firstSeen
            if Date().timeIntervalSince(firstSeen) < Self.challengeWaitBudget {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.continuation != nil, self.webView === webView,
                          self.navigationGeneration == generation, self.pendingDownloadURL == nil else { return }
                    await self.inspectRenderedPage(in: webView, generation: generation)
                }
                return
            }
        }
        guard phase == .landingPage else {
            pageInsteadOfFile()
            return
        }
        await clickDownloadControl(in: webView, generation: generation)
    }

    private func clickDownloadControl(in webView: WKWebView, generation: Int) async {
        let clicked = (try? await webView.evaluateJavaScript(PublisherPDFDownloadControl.clickScript) as? Bool) ?? false
        guard continuation != nil, self.webView === webView,
              navigationGeneration == generation, pendingDownloadURL == nil else { return }
        guard clicked else {
            logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public): the page has no PDF control to click")
            beginPDFNavigationRoute()
            return
        }
        phase = .controlClicked
        logger.info("Web-session PDF download of \(self.url.absoluteString, privacy: .public): clicked the page's PDF control")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.clickResponseGrace)
            guard let self, self.continuation != nil, self.webView === webView,
                  self.phase == .controlClicked,
                  self.navigationGeneration == generation, self.pendingDownloadURL == nil else { return }
            // Nothing followed the click: no download, no navigation.
            self.beginPDFNavigationRoute()
        }
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeverLM-WebSession-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: destination)
        pendingDownloadURL = destination
        completionHandler(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloadURL = nil
        pageInsteadOfFile()
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = pendingDownloadURL else {
            finish(.failure(SourceError.fetchFailed))
            return
        }
        pendingDownloadURL = nil
        Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            await MainActor.run { self.handleDownloadedBytes(data) }
        }
    }

    private func handleDownloadedBytes(_ data: Data?) {
        guard continuation != nil else { return }
        if let data, SourceService.looksLikePDFData(data) {
            logger.info("Downloaded \(self.url.absoluteString, privacy: .public) through the reader's web session (\(data.count) bytes)")
            finish(.success(data))
            return
        }
        // What came down is a page, not the file.
        pageInsteadOfFile()
    }
}

/// Used as a fallback when plain HTTP fetching returns 403 or JS-only content.
@MainActor
final class WebViewContentExtractor: NSObject, WKNavigationDelegate {
    static let shared = WebViewContentExtractor()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// When true, extract full HTML instead of plain text.
    private var extractHTMLMode = false
    /// Tail of the serial request chain. Each request waits for its predecessor
    /// to fully complete before touching the shared WKWebView, so a new caller
    /// never cancels an in-flight load.
    private var lastRequest: Task<String, Error>?

    func extractContent(from url: URL) async throws -> String {
        return try await loadAndExtract(from: url, htmlMode: false)
    }

    /// Extract the rendered HTML (after JS execution) instead of plain text.
    func extractHTML(from url: URL) async throws -> String {
        return try await loadAndExtract(from: url, htmlMode: true)
    }

    /// Serialize requests onto the shared WKWebView. Concurrent callers queue up
    /// and run one at a time instead of cancelling each other's in-flight loads.
    private func loadAndExtract(from url: URL, htmlMode: Bool) async throws -> String {
        let predecessor = lastRequest
        let request = Task { [weak self] () throws -> String in
            // Wait for the previous request to finish; ignore its outcome.
            _ = try? await predecessor?.value
            guard let self else { throw CancellationError() }
            return try await self.performLoadAndExtract(from: url, htmlMode: htmlMode)
        }
        lastRequest = request
        return try await request.value
    }

    private func performLoadAndExtract(from url: URL, htmlMode: Bool) async throws -> String {
        // Clean up any previous state
        cleanup()
        extractHTMLMode = htmlMode
        securityChallengeFirstSeenAt = nil

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            // Persistent across ForeverLM web views, including the live Reader
            // where a learner may have established a publisher subscription.
            config.websiteDataStore = .default()
            // macOS WKWebView autoplays media *with sound* by default; this view is
            // invisible, so autoplaying ads/embeds would leak random audio into the app.
            config.mediaTypesRequiringUserActionForPlayback = .all
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = SharedWebKit.desktopSafariUserAgent
            self.webView = wv

            wv.load(URLRequest(url: url))

            // Timeout after 20 seconds, or, for a page showing a bot check,
            // once the check's own wait has run out.
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.continuation != nil else { return }
                // A check in progress is left to `extractText`'s polling,
                // which hands the page over itself when its budget runs out.
                // Only step in once that budget has passed too, so a poll
                // that never came back cannot leave the caller hanging.
                if let firstSeen = self.securityChallengeFirstSeenAt {
                    let remaining = Self.securityChallengeWaitBudget + 4 - Date().timeIntervalSince(firstSeen)
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    guard self.continuation != nil else { return }
                }
                // A check that never cleared is handed over as the page it
                // is, so the caller's guard can name the block instead of a
                // timeout.
                if self.securityChallengeFirstSeenAt != nil, let wv = self.webView {
                    self.extractDocumentText(from: wv)
                } else {
                    self.finishWith(error: SourceError.fetchFailed)
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Wait a moment for JS frameworks to render content
            try? await Task.sleep(for: .milliseconds(1500))
            self.extractText()
        }
    }

    /// A publisher's Cloudflare check never clears under the Safari user
    /// agent; the page is asked for again under WebKit's own.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if SharedWebKit.retryCloudflareChallengeWithWebKitUserAgent(navigationResponse, in: webView) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finishWith(error: SourceError.fetchFailed)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // The Cloudflare retry's cancel; the page asked for again reports
        // for itself.
        let retrying = MainActor.assumeIsolated {
            SharedWebKit.isCloudflareRetryInterruption(error, in: webView)
        }
        guard !retrying else { return }
        Task { @MainActor in
            self.finishWith(error: SourceError.fetchFailed)
        }
    }

    // MARK: - Private

    /// How long a page may keep showing a publisher bot check before its text
    /// is taken as-is. A managed challenge that clears on its own does so in a
    /// few seconds and reloads the page, which reaches `didFinish` again; one
    /// that wants a click never will, and the caller's guard then parks the
    /// source as blocked, as before, rather than storing the wall. The budget
    /// covers the origin too: LinkedIn's check read *Verification successful.
    /// Waiting for www.linkedin.com to respond* at twelve seconds, and the
    /// article arrived after that.
    private static let securityChallengeWaitBudget: TimeInterval = 30

    /// The moment the current load was first seen showing a bot check.
    private var securityChallengeFirstSeenAt: Date?

    private static let securityChallengeProbeJS = """
    (function() {
        return {
            title: document.title || '',
            text: document.body ? (document.body.innerText || '') : '',
            url: location.href
        };
    })()
    """

    private func extractText() {
        guard let wv = webView else {
            finishWith(error: SourceError.fetchFailed)
            return
        }

        wv.evaluateJavaScript(Self.securityChallengeProbeJS) { [weak self] result, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.continuation != nil, self.webView === wv else { return }
                if let probe = result as? [String: Any],
                   SourceDiscovery.isSecurityVerificationPage(
                       title: probe["title"] as? String ?? "",
                       visibleText: probe["text"] as? String ?? "",
                       url: probe["url"] as? String ?? ""
                   ) {
                    let firstSeen = self.securityChallengeFirstSeenAt ?? Date()
                    self.securityChallengeFirstSeenAt = firstSeen
                    if Date().timeIntervalSince(firstSeen) < Self.securityChallengeWaitBudget {
                        // Still the interstitial. Look again shortly; the
                        // reload a cleared check performs also lands here
                        // through `didFinish`, whichever comes first.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            guard let self, self.continuation != nil, self.webView === wv else { return }
                            self.extractText()
                        }
                        return
                    }
                }
                self.extractDocumentText(from: wv)
            }
        }
    }

    private func extractDocumentText(from wv: WKWebView) {
        let js: String
        if extractHTMLMode {
            js = """
            (function() {
                ['script','style','nav','header','footer','aside','.sidebar','.ad','.advertisement'].forEach(sel => {
                    document.querySelectorAll(sel).forEach(el => el.remove());
                });
                return document.documentElement.outerHTML;
            })()
            """
        } else {
            js = """
            (function() {
                return document.body ? document.body.innerText : '';
            })()
            """
        }

        wv.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let text = result as? String {
                    if self.extractHTMLMode {
                        // For HTML mode, return as-is (caller does its own validation)
                        self.finishWith(text: text)
                    } else {
                        let cleaned = self.cleanExtractedText(text)
                        if !cleaned.isEmpty {
                            self.finishWith(text: cleaned)
                        } else {
                            self.finishWith(error: SourceError.accessDenied)
                        }
                    }
                } else {
                    self.finishWith(error: SourceError.fetchFailed)
                }
            }
        }
    }

    private func cleanExtractedText(_ text: String) -> String {
        // `innerText` keeps the page's soft hyphens; they are not the text's.
        var result = text.removingSoftHyphens()
        // Collapse excessive whitespace
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private func finishWith(text: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        webView = nil
        cont?.resume(returning: text)
    }

    private func finishWith(error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        webView = nil
        cont?.resume(throwing: error)
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: CancellationError())
        }
        webView = nil
    }
}
#endif
