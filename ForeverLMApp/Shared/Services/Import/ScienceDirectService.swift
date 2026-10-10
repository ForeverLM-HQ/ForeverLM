import AppKit
import Foundation
import Security
import WebKit

enum ScienceDirectService {
    private static let canonicalHost = "www.sciencedirect.com"

    /// Shared Safari user-agent for every ScienceDirect WebView. The interactive
    /// challenge window and the silent downloader MUST use the same UA: Cloudflare
    /// binds the `cf_clearance` cookie to the user-agent, so a mismatch would make
    /// the cookie the user just earned invalid for the follow-up silent download.
    static let browserUserAgent = SharedWebKit.desktopSafariUserAgent

    static func isScienceDirectURL(_ urlString: String) -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else {
            return false
        }
        return host == "sciencedirect.com" || host.hasSuffix(".sciencedirect.com")
    }

    static func pii(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "sciencedirect.com" || host.hasSuffix(".sciencedirect.com") else {
            return nil
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard let piiIndex = pathParts.firstIndex(where: { $0.lowercased() == "pii" }),
              pathParts.indices.contains(piiIndex + 1) else {
            return nil
        }

        let rawPII = pathParts[piiIndex + 1]
        let pii = (rawPII.removingPercentEncoding ?? rawPII)
            .replacingOccurrences(of: ".pdf", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pii.isEmpty ? nil : pii
    }

    static func pdfURL(from urlString: String) -> String? {
        guard isScienceDirectURL(urlString) else { return nil }

        if let components = URLComponents(string: urlString),
           components.path.lowercased().contains("/pdfft") {
            return ensuringPDFDownloadQuery(urlString)
        }

        guard let pii = pii(from: urlString) else { return nil }
        let escapedPII = pii.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pii
        return "https://\(canonicalHost)/science/article/pii/\(escapedPII)/pdfft?isDTMRedir=true&download=true"
    }

    static func abstractURL(from urlString: String) -> String? {
        guard let pii = pii(from: urlString) else { return nil }
        let escapedPII = pii.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pii
        return "https://\(canonicalHost)/science/article/pii/\(escapedPII)"
    }

    @MainActor
    static func downloadPDFWithAuthenticatedWebSession(
        from urlString: String,
        to destinationPath: String,
        label: String? = nil
    ) async throws {
        guard let pdfURL = pdfURL(from: urlString),
              let url = URL(string: pdfURL) else {
            throw SourceError.invalidURL
        }

        // Warm up cookies by loading the article landing page first. ScienceDirect's
        // `isDTMRedir` PDF endpoint only redirects to the actual file once the session
        // cookie set by the article page is present; hitting `/pdfft` cold (as we used
        // to) returns an HTML interstitial instead of the PDF, which is why even
        // open-access papers failed to download.
        let warmupURL = abstractURL(from: urlString).flatMap(URL.init(string:))

        // The downloader runs headless: it opens the article page, requests the
        // PDF, and captures the download in an off-screen WebView. It only asks
        // for a window — through `WebVerificationRequests`, and only if the user
        // accepts — when a page needs a human (Cloudflare, CAPTCHA, MFA, or a
        // sign-in that the stored credentials cannot complete).
        let downloader = ScienceDirectAuthenticatedPDFDownloader(label: label)
        let tempURL = try await downloader.downloadPDF(from: url, warmupFrom: warmupURL)
        try await installDownloadedPDF(from: tempURL, to: destinationPath)
    }

    private nonisolated static func installDownloadedPDF(from tempURL: URL, to destinationPath: String) async throws {
        let task = Task.detached(priority: .userInitiated) {
            guard SourceService.canOpenPDF(at: tempURL.path) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw SourceError.pdfReadFailed
            }

            let destination = URL(fileURLWithPath: destinationPath)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func ensuringPDFDownloadQuery(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
        }
        var items = components.queryItems ?? []
        let existing = Set(items.map { $0.name.lowercased() })
        if !existing.contains("isdtmredir") {
            items.append(URLQueryItem(name: "isDTMRedir", value: "true"))
        }
        if !existing.contains("download") {
            items.append(URLQueryItem(name: "download", value: "true"))
        }
        components.queryItems = items
        return components.string ?? urlString
    }
}

/// Downloads a ScienceDirect PDF in an off-screen WKWebView: it opens the article
/// page to establish the session cookie, requests the PDF endpoint, and captures
/// the download without ever taking over the screen.
///
/// A Cloudflare / CAPTCHA / MFA challenge or a sign-in the stored credentials
/// cannot complete is the one thing this cannot do unattended. Rather than
/// popping a window into the user's face, it parks a request in
/// `WebVerificationRequests`; Studio offers it as a banner, and the window is
/// built only if the user takes it up. The WebView shares
/// `WKWebsiteDataStore.default()`, so a challenge cleared once carries its
/// `cf_clearance` cookie into every later download.
@MainActor
private final class ScienceDirectAuthenticatedPDFDownloader: NSObject, WKNavigationDelegate, WKDownloadDelegate, NSWindowDelegate {
    private struct Credentials {
        let username: String
        let password: String
    }

    private struct LoginActionResult: Decodable {
        let attempted: Bool
        let filledEmail: Bool
        let filledPassword: Bool
        let submitted: Bool
    }

    private enum Phase {
        /// Loading the article landing page to establish ScienceDirect session cookies.
        case warmup
        /// Loading the PDF endpoint itself.
        case pdf
    }

    private var loadContinuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingDownloadURL: URL?
    private var webView: WKWebView?
    private var targetPDFURL: URL?
    private var warmupURL: URL?
    private var phase: Phase = .pdf
    private var loginAttempts = 0
    private let maxLoginAttempts = 4
    // Generous: the user may need time to work through a CAPTCHA in the window.
    private let overallDeadlineSeconds: UInt64 = 300

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    /// Last narration line, kept so a window built later opens already captioned.
    private var statusText = "Opening the article page…"
    /// Human-readable name of the paper, for the verification banner.
    private let label: String?
    /// Identifier of the parked `WebVerificationRequests` entry, if any.
    private var verificationRequestID: UUID?
    /// Grace period before a challenge is escalated to the user — most
    /// Cloudflare managed checks clear themselves within a few seconds.
    private var verificationEscalationTask: Task<Void, Never>?

    init(label: String?) {
        self.label = label
        super.init()
    }

    // Hosts that are permitted to receive the stored Elsevier/ScienceDirect
    // credentials. Credential injection must NEVER happen on any other host,
    // even if the landed page superficially looks like a login form.
    private static let credentialInjectionAllowedHosts: Set<String> = [
        "id.elsevier.com",
        "www.sciencedirect.com",
        "sciencedirect.com",
        "www.elsevier.com",
        "elsevier.com",
    ]

    private func isCredentialInjectionAllowed(for url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        if Self.credentialInjectionAllowedHosts.contains(host) { return true }
        return host.hasSuffix(".elsevier.com") || host.hasSuffix(".sciencedirect.com")
    }

    /// The single, atomic resume point for `loadContinuation`. Reads and nils
    /// out the continuation so any of the many completion paths (navigation
    /// failure, download failure/finish, login abort, or the overall deadline)
    /// resumes exactly once; a second call is a no-op rather than a crash.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        clearVerificationRequest()
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        continuation.resume(with: result)
    }

    func windowWillClose(_ notification: Notification) {
        // User closed the window before the download completed.
        finish(.failure(SourceError.accessDenied))
    }

    func downloadPDF(from url: URL, warmupFrom warmupURL: URL?) async throws -> URL {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // An off-screen WebView still has to look like a real browser window:
        // Cloudflare's managed challenge inspects viewport properties, and a
        // zero-sized WebView can stay pinned to the interstitial forever even
        // where a normally sized one passes unattended.
        // Nothing is visible, so an autoplaying embed would be disembodied audio.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration
        )
        webView.customUserAgent = ScienceDirectService.browserUserAgent
        webView.navigationDelegate = self
        self.webView = webView
        self.targetPDFURL = url
        // Only warm up when the landing page is a distinct URL from the PDF endpoint.
        self.warmupURL = (warmupURL == url) ? nil : warmupURL

        return try await startDownload(in: webView)
    }

    /// Builds the browser window around the running WebView and shows it. Called
    /// only when the user accepts a parked verification request, never on its own.
    private func presentWindow() {
        guard window == nil, let webView else { return }
        let contentWidth: CGFloat = 920
        let contentHeight: CGFloat = 820
        let headerHeight: CGFloat = 60

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))

        let header = NSView(frame: NSRect(x: 0, y: contentHeight - headerHeight, width: contentWidth, height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]

        let statusField = NSTextField(labelWithString: statusText)
        statusField.frame = NSRect(x: 16, y: 20, width: contentWidth - 300, height: 20)
        statusField.autoresizingMask = [.width]
        statusField.lineBreakMode = .byTruncatingTail
        statusField.textColor = .secondaryLabelColor
        header.addSubview(statusField)
        statusLabel = statusField

        let downloadButton = NSButton(title: "Download PDF", target: self, action: #selector(downloadTapped))
        downloadButton.frame = NSRect(x: contentWidth - 16 - 140, y: 14, width: 140, height: 32)
        downloadButton.autoresizingMask = [.minXMargin]
        downloadButton.bezelStyle = .rounded
        header.addSubview(downloadButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.frame = NSRect(x: contentWidth - 16 - 140 - 8 - 90, y: 14, width: 90, height: 32)
        cancelButton.autoresizingMask = [.minXMargin]
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        header.addSubview(cancelButton)

        webView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight - headerHeight)
        webView.autoresizingMask = [.width, .height]

        container.addSubview(webView)
        container.addSubview(header)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloading paper PDF"
        window.contentView = container
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        // No `NSApp.activate(ignoringOtherApps:)`: the user reached this window by
        // clicking the banner, so the app is already frontmost, and grabbing focus
        // is the behaviour this whole path exists to stop.
        window.makeKeyAndOrderFront(nil)

        // The clock restarts when a human takes over: the headless deadline was
        // sized for an unattended fetch, not for working through a CAPTCHA.
        restartDeadline()
    }

    private func setStatus(_ text: String) {
        statusText = text
        statusLabel?.stringValue = text
    }

    /// Parks a request for the user instead of stealing the screen.
    ///
    /// `grace` gives an automatic challenge time to clear itself first — most
    /// Cloudflare managed checks pass in a few seconds with nobody watching, and
    /// a banner for those would be exactly the interruption we are removing. A
    /// dead end that will never self-clear (a manual sign-in) passes `.zero`.
    private func requestVerification(reason: String, grace: Duration) {
        setStatus(reason)
        // Already escalated, already visible, or already waiting out the grace.
        guard window == nil, verificationRequestID == nil, verificationEscalationTask == nil else { return }

        verificationEscalationTask = Task { @MainActor [weak self] in
            if grace > .zero {
                try? await Task.sleep(for: grace)
            }
            guard !Task.isCancelled, let self, self.loadContinuation != nil, self.window == nil else { return }
            self.verificationEscalationTask = nil
            let detail = self.label
            self.verificationRequestID = WebVerificationRequests.shared.request(
                message: "ScienceDirect needs a quick verification to download this paper.",
                detail: detail,
                open: { [weak self] in
                    self?.verificationRequestID = nil
                    self?.presentWindow()
                },
                skip: { [weak self] in
                    self?.verificationRequestID = nil
                    self?.finish(.failure(SourceError.accessDenied))
                }
            )
        }
    }

    /// Withdraws a parked request and cancels a pending escalation. Called when
    /// the challenge clears on its own and when the download ends either way.
    private func clearVerificationRequest() {
        verificationEscalationTask?.cancel()
        verificationEscalationTask = nil
        WebVerificationRequests.shared.withdraw(verificationRequestID)
        verificationRequestID = nil
    }

    private func restartDeadline() {
        guard loadContinuation != nil else { return }
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.overallDeadlineSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.finish(.failure(SourceError.fetchFailed))
        }
    }

    @objc private func downloadTapped() {
        guard let webView, let targetPDFURL else { return }
        phase = .pdf
        setStatus("Fetching the PDF…")
        load(targetPDFURL, in: webView, preferPDF: true)
    }

    @objc private func cancelTapped() {
        finish(.failure(SourceError.accessDenied))
    }

    private func startDownload(in webView: WKWebView) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            loadContinuation = continuation
            // Overall deadline: a swallowed login click (submitted with no
            // navigation) could otherwise hang the continuation forever.
            restartDeadline()
            if let warmupURL {
                phase = .warmup
                setStatus("Opening the article page…")
                load(warmupURL, in: webView, preferPDF: false)
            } else if let targetPDFURL {
                phase = .pdf
                setStatus("Fetching the PDF…")
                load(targetPDFURL, in: webView, preferPDF: true)
            } else {
                finish(.failure(SourceError.invalidURL))
            }
        }
    }

    private func load(_ url: URL, in webView: WKWebView, preferPDF: Bool) {
        var request = URLRequest(url: url)
        request.setValue(
            preferPDF
                ? "application/pdf,application/octet-stream;q=0.9,text/html;q=0.8,*/*;q=0.5"
                : "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        webView.load(request)
    }

    /// Handles a PDF-phase page that loaded as HTML rather than downloading — i.e.
    /// a login page, entitlement wall, or dead end. Challenges are already handled
    /// in `didFinish` before this runs. `bodyText` is passed in so we don't
    /// re-scrape the DOM.
    private func finishLoadWithoutPDF(bodyText: String, in webView: WKWebView) async {
        guard loadContinuation != nil else { return }
        let lower = bodyText.lowercased()

        if Self.pageLooksLikeLogin(lower),
           loginAttempts < maxLoginAttempts,
           let credentials = Self.loadScienceDirectCredentials() {
            // Only ever inject the stored Elsevier credentials on a trusted
            // Elsevier/ScienceDirect host. If the page merely looks like a
            // login form but we landed somewhere else (open redirect, ad
            // iframe, etc.), abort loudly rather than leaking credentials.
            guard isCredentialInjectionAllowed(for: webView.url) else {
                finish(.failure(SourceError.accessDenied))
                return
            }
            setStatus("Signing in…")
            do {
                let result = try await submitLoginStep(credentials: credentials, in: webView)
                if result.attempted {
                    loginAttempts += 1
                    if result.submitted {
                        return
                    }
                }
            } catch {
                finish(.failure(error))
                return
            }
        }

        if Self.pageRequiresAccessEntitlement(lower) {
            finish(.failure(SourceError.accessDenied))
            return
        }

        if loginAttempts > 0, let targetPDFURL {
            loginAttempts += 1
            if loginAttempts <= maxLoginAttempts {
                setStatus("Fetching the PDF…")
                load(targetPDFURL, in: webView, preferPDF: true)
                return
            }
        }

        if Self.pageLooksLikeLogin(lower) {
            // Automatic sign-in is exhausted, so offer the user the window rather
            // than failing outright. This one will never clear itself, so there is
            // no grace period. A completed sign-in navigates and re-enters this
            // handler; the overall deadline bounds the wait.
            requestVerification(
                reason: "Sign in to your institution here to download, or close this window.",
                grace: .zero
            )
            return
        }
        finish(.failure(SourceError.fetchFailed))
    }

    private func submitLoginStep(credentials: Credentials, in webView: WKWebView) async throws -> LoginActionResult {
        let payload = [
            "username": credentials.username,
            "password": credentials.password,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let js = """
        (() => {
          const credentials = \(json);
          const isVisible = (element) => {
            if (!element || element.disabled) return false;
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const fire = (element) => {
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const inputs = Array.from(document.querySelectorAll('input')).filter(isVisible);
          const scoreEmail = (input) => {
            const haystack = [
              input.type,
              input.name,
              input.id,
              input.autocomplete,
              input.placeholder,
              input.getAttribute('aria-label')
            ].join(' ').toLowerCase();
            if (input.type === 'email') return 5;
            if (haystack.includes('email')) return 4;
            if (haystack.includes('username')) return 4;
            if (haystack.includes('login')) return 3;
            if (haystack.includes('user')) return 2;
            return 0;
          };
          const emailInput = inputs
            .filter((input) => input.type !== 'hidden' && input.type !== 'password')
            .sort((a, b) => scoreEmail(b) - scoreEmail(a))[0];
          const passwordInput = inputs.find((input) => input.type === 'password');
          let filledEmail = false;
          let filledPassword = false;
          if (emailInput && scoreEmail(emailInput) > 0 && emailInput.value !== credentials.username) {
            emailInput.focus();
            emailInput.value = credentials.username;
            fire(emailInput);
            filledEmail = true;
          }
          if (passwordInput && passwordInput.value !== credentials.password) {
            passwordInput.focus();
            passwordInput.value = credentials.password;
            fire(passwordInput);
            filledPassword = true;
          }
          const activeForm = (passwordInput || emailInput) ? (passwordInput || emailInput).form : null;
          const buttons = Array.from(document.querySelectorAll('button, input[type="submit"], input[type="button"], [role="button"]')).filter(isVisible);
          const buttonScore = (button) => {
            const text = [
              button.innerText,
              button.textContent,
              button.value,
              button.id,
              button.name,
              button.getAttribute('aria-label')
            ].join(' ').toLowerCase();
            if (text.includes('sign in') || text.includes('signin')) return 6;
            if (text.includes('log in') || text.includes('login')) return 5;
            if (text.includes('continue')) return 4;
            if (text.includes('next')) return 3;
            if (text.includes('submit')) return 2;
            return 0;
          };
          const button = buttons.sort((a, b) => buttonScore(b) - buttonScore(a))[0];
          const shouldSubmit = Boolean((passwordInput && passwordInput.value) || (emailInput && emailInput.value));
          if (shouldSubmit && button && buttonScore(button) > 0) {
            button.click();
            return JSON.stringify({ attempted: true, filledEmail, filledPassword, submitted: true });
          }
          if (shouldSubmit && activeForm) {
            if (activeForm.requestSubmit) activeForm.requestSubmit();
            else activeForm.submit();
            return JSON.stringify({ attempted: true, filledEmail, filledPassword, submitted: true });
          }
          return JSON.stringify({ attempted: Boolean(filledEmail || filledPassword), filledEmail, filledPassword, submitted: false });
        })();
        """

        guard let raw = try await webView.evaluateJavaScript(js) as? String,
              let resultData = raw.data(using: .utf8) else {
            throw SourceError.fetchFailed
        }
        return try JSONDecoder().decode(LoginActionResult.self, from: resultData)
    }

    private static func pageLooksLikeLogin(_ lowerBodyText: String) -> Bool {
        lowerBodyText.contains("sign in")
            || lowerBodyText.contains("log in")
            || lowerBodyText.contains("email")
            || lowerBodyText.contains("password")
            || lowerBodyText.contains("elsevier")
    }

    private static func pageRequiresImmediateHumanIntervention(_ lowerBodyText: String) -> Bool {
        lowerBodyText.contains("captcha")
            || lowerBodyText.contains("multi-factor")
            || lowerBodyText.contains("multifactor")
            || lowerBodyText.contains("verification code")
            || lowerBodyText.contains("two-step")
    }

    private static func pageRequiresAccessEntitlement(_ lowerBodyText: String) -> Bool {
        lowerBodyText.contains("purchase pdf")
            || lowerBodyText.contains("get access")
    }

    private static func loadScienceDirectCredentials() -> Credentials? {
        for server in ["www.sciencedirect.com", "sciencedirect.com"] {
            if let credentials = loadInternetPassword(server: server) {
                return credentials
            }
        }
        return nil
    }

    private static func loadInternetPassword(server: String) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            return nil
        }

        return Credentials(username: account, password: password)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loadContinuation != nil else { return }
        Task { @MainActor in
            guard loadContinuation != nil, let webView = self.webView else { return }
            let bodyText = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
            let lower = bodyText.lowercased()
            let title = (webView.title ?? "").lowercased()

            // A Cloudflare / CAPTCHA / MFA challenge can appear on either the landing
            // page or the PDF request. It can't be solved headlessly, but the window
            // is visible — narrate and wait. Completing the check triggers a fresh
            // navigation (another didFinish), which re-evaluates from the top.
            if title.contains("just a moment") || title.contains("attention required")
                || lower.contains("are you a robot") || lower.contains("verify you are human")
                || lower.contains("checking your browser")
                || Self.pageRequiresImmediateHumanIntervention(lower) {
                requestVerification(
                    reason: "Complete the verification shown here to continue…",
                    grace: .seconds(6)
                )
                return
            }

            // Past the challenge — withdraw any banner still offering to show it.
            clearVerificationRequest()

            if phase == .warmup {
                // The article page loaded and set its session cookies. Now request the
                // PDF endpoint, which should resolve straight to the file.
                guard let targetPDFURL else { finish(.failure(SourceError.invalidURL)); return }
                phase = .pdf
                setStatus("Fetching the PDF…")
                load(targetPDFURL, in: webView, preferPDF: true)
                return
            }

            await finishLoadWithoutPDF(bodyText: bodyText, in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            startWKDownload(webView: webView, request: navigationAction.request)
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let mimeType = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mimeType == "application/pdf" || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
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

    private func startWKDownload(webView: WKWebView, request: URLRequest) {
        webView.startDownload(using: request) { download in
            download.delegate = self
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        setStatus("Downloading the PDF…")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScienceDirect-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: destination)
        pendingDownloadURL = destination
        completionHandler(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloadURL = nil
        finish(.failure(error))
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = pendingDownloadURL else {
            finish(.failure(SourceError.fetchFailed))
            return
        }
        pendingDownloadURL = nil
        finish(.success(url))
    }
}
