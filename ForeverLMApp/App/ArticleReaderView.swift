#if os(macOS)
import AppKit
import Combine
import SwiftUI
import WebKit

enum ArticleMathRendering {
    static let injectionScript = """
    (function() {
        function hasLikelyMath() {
            var body = document.body;
            if (!body) { return false; }
            var text = body.innerText || '';
            return /(\\$\\$|\\\\\\(|\\\\\\[|\\\\begin\\{|\\\\frac|\\\\cdot|\\\\sum|\\\\int|\\\\epsilon|\\\\alpha|\\\\beta|\\\\gamma|\\\\delta|\\\\theta|\\\\lambda|\\\\mu|\\\\pi|\\\\sigma|\\\\sim|[^\\\\]\\$[^\\s\\$][\\s\\S]{0,180}[^\\\\]\\$)/.test(text);
        }

        function typesetMath() {
            if (window.MathJax && window.MathJax.typesetPromise) {
                window.MathJax.typesetPromise().catch(function(error) {
                    console.warn('[ForeverLM] MathJax typeset failed', error);
                });
            }
        }

        if (window.foreverLMMathRenderingInstalled) {
            typesetMath();
            return;
        }
        if (!hasLikelyMath()) { return; }

        window.foreverLMMathRenderingInstalled = true;
        window.MathJax = window.MathJax || {};
        window.MathJax.tex = Object.assign({}, window.MathJax.tex || {}, {
            inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
            displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
            processEscapes: true
        });
        window.MathJax.options = Object.assign({}, window.MathJax.options || {}, {
            skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code'],
            ignoreHtmlClass: 'tex2jax_ignore'
        });

        if (window.MathJax && window.MathJax.typesetPromise) {
            typesetMath();
        } else if (!document.getElementById('foreverlm-mathjax-script')) {
            var script = document.createElement('script');
            script.id = 'foreverlm-mathjax-script';
            script.async = true;
            script.src = 'https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js';
            script.onload = typesetMath;
            (document.head || document.documentElement).appendChild(script);
        }

        var pendingTypeset = null;
        function scheduleTypeset() {
            if (pendingTypeset) { clearTimeout(pendingTypeset); }
            pendingTypeset = setTimeout(function() {
                pendingTypeset = null;
                typesetMath();
            }, 350);
        }

        setTimeout(typesetMath, 800);
        setTimeout(typesetMath, 1800);
        if (document.body && window.MutationObserver) {
            new MutationObserver(scheduleTypeset).observe(document.body, {
                childList: true,
                subtree: true,
                characterData: true
            });
        }
    })();
    """
}

// MARK: - Article Reader View

/// The browser-history surface the reader chrome controls. Keeping the small
/// contract separate from `WKWebView` lets the state and its toolbar actions be
/// exercised without constructing a live web process.
@MainActor
protocol ArticleReaderNavigationTarget: AnyObject {
    var readerCanGoBack: Bool { get }
    var readerCanGoForward: Bool { get }
    var readerCurrentURL: URL? { get }

    @discardableResult func navigateReaderBack() -> Bool
    @discardableResult func navigateReaderForward() -> Bool
}

@MainActor
extension WKWebView: ArticleReaderNavigationTarget {
    var readerCanGoBack: Bool { backForwardList.backItem != nil }
    var readerCanGoForward: Bool { backForwardList.forwardItem != nil }
    var readerCurrentURL: URL? { url }

    @discardableResult
    func navigateReaderBack() -> Bool {
        navigateReader(to: backForwardList.backItem)
    }

    @discardableResult
    func navigateReaderForward() -> Bool {
        navigateReader(to: backForwardList.forwardItem)
    }

    /// Navigate to the exact history item represented by the enabled toolbar
    /// state. A page can change its history between SwiftUI's render and the
    /// click; if WebKit rejects that item, loading its URL still honors the
    /// user's action instead of leaving an enabled button as a silent no-op.
    private func navigateReader(to item: WKBackForwardListItem?) -> Bool {
        guard let item else { return false }
        stopLoading()
        if go(to: item) != nil { return true }
        return load(URLRequest(url: item.url)) != nil
    }
}

/// A WKWebView-based article reader for the Studio detail pane.
/// Shows the actual rendered webpage instead of extracted text, with a browser-like toolbar
/// and text selection → card generation support.
@MainActor
@Observable
final class ArticleReaderChromeState {
    var isLoading = true
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var currentURL: URL?
    var zoomScale: CGFloat = ArticleReaderZoom.defaultScale

    /// The navigation surface currently represented by this chrome. Keeping it here
    /// makes the action and its enabled state one piece of state: an outgoing
    /// reader can no longer clear a closure after the incoming reader has already
    /// published `canGoBack = true`.
    @ObservationIgnored private weak var navigationTarget: (any ArticleReaderNavigationTarget)?
    @ObservationIgnored var downloadPDF: (() -> Void)?
    /// Take the page on screen as the paper: its text, and a PDF printed from
    /// it. The learner's opt-in for a paper the publisher shows but will not
    /// hand over.
    @ObservationIgnored var savePaperFromPage: (() -> Void)?
    @ObservationIgnored var zoomIn: (() -> Void)?
    @ObservationIgnored var zoomOut: (() -> Void)?
    @ObservationIgnored var resetZoom: (() -> Void)?
    @ObservationIgnored var setZoom: ((CGFloat) -> Void)?

    var hasNavigationTarget: Bool {
        navigationTarget != nil
    }

    func liveBrowserURL() -> URL? {
        navigationTarget?.readerCurrentURL
    }

    func bindNavigation(to target: any ArticleReaderNavigationTarget) {
        navigationTarget = target
        updateNavigationState(from: target)
    }

    /// Identity-checking matters during source switches: dismantling the old
    /// representable may happen after the replacement has bound its WebView.
    func unbindNavigation(from target: any ArticleReaderNavigationTarget) {
        guard navigationTarget === target else { return }
        navigationTarget = nil
        canGoBack = false
        canGoForward = false
    }

    func updateNavigationState(
        from target: any ArticleReaderNavigationTarget,
        currentURL: URL? = nil
    ) {
        guard navigationTarget === target else { return }
        canGoBack = target.readerCanGoBack
        canGoForward = target.readerCanGoForward
        let resolvedURL = currentURL ?? target.readerCurrentURL
        if let resolvedURL, resolvedURL.hasWebScheme {
            self.currentURL = resolvedURL
        }
    }

    func setLoading(_ loading: Bool, from target: any ArticleReaderNavigationTarget) {
        guard navigationTarget === target else { return }
        isLoading = loading
    }

    func goBack() {
        guard let target = navigationTarget else { return }
        guard target.readerCanGoBack, target.navigateReaderBack() else {
            updateNavigationState(from: target)
            return
        }
        updateNavigationState(from: target)
    }

    func goForward() {
        guard let target = navigationTarget else { return }
        guard target.readerCanGoForward, target.navigateReaderForward() else {
            updateNavigationState(from: target)
            return
        }
        updateNavigationState(from: target)
    }

    func reset() {
        isLoading = true
        canGoBack = false
        canGoForward = false
        currentURL = nil
        zoomScale = ArticleReaderZoom.defaultScale
        navigationTarget = nil
        downloadPDF = nil
        savePaperFromPage = nil
        zoomIn = nil
        zoomOut = nil
        resetZoom = nil
        setZoom = nil
    }
}

/// "Back to article": offered while the reader shows a page one of the
/// article's links led to, and taking the reader straight back to the article
/// — past every page in between — to where it was left.
@MainActor
@Observable
final class ArticleReaderReturnState {
    private(set) var isAwayFromArticle = false
    @ObservationIgnored private var returnAction: (() -> Void)?

    func update(isAwayFromArticle: Bool, returnAction: @escaping () -> Void) {
        self.returnAction = returnAction
        // Observation fires on every write, equal or not, and this is written
        // on every change of address.
        guard self.isAwayFromArticle != isAwayFromArticle else { return }
        self.isAwayFromArticle = isAwayFromArticle
    }

    func returnToArticle() {
        returnAction?()
    }

    /// The history entry that holds the article: its latest visit behind the
    /// page on screen, else the first ahead of it.
    static func articleEntry<Item>(
        back: [Item],
        forward: [Item],
        isArticle: (Item) -> Bool
    ) -> Item? {
        back.last(where: isArticle) ?? forward.first(where: isArticle)
    }

    static func title(for sourceType: StudioSourceType) -> String {
        sourceType == .paper ? "Back to paper" : "Back to article"
    }
}

/// The pill over a linked page that takes the reader back to the article.
struct ArticleReaderReturnButton: View {
    let title: String
    let articleTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.uturn.backward")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.12))
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .help(articleTitle)
        .accessibilityIdentifier("studio.reader.backToArticle")
    }
}

enum ArticleReaderZoom {
    static let minScale: CGFloat = 0.7
    static let maxScale: CGFloat = 1.8
    static let defaultScale: CGFloat = 1.0
    static let step: CGFloat = 0.1
    static let tolerance: CGFloat = 0.001

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    static func differs(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) > tolerance
    }

    @MainActor
    static func apply(_ scale: CGFloat, to webView: WKWebView) {
        let clamped = clamped(scale)
        guard differs(webView.pageZoom, clamped) else { return }
        ReaderPinchAnchor.setPageZoom(clamped, of: webView)
    }
}

/// Back/forward control for reader toolbars, wherever the toolbar is mounted.
///
/// Docked in a Studio window the row hangs in the titlebar band. There an
/// `NSButton` — the previous form of this control — lit up under the pointer
/// (its tracking area still fired) but never received the mouse-down: AppKit's
/// `hitTest(_:)` returns SwiftUI's hosting view for a point in the band and the
/// press became a window drag, so Back looked live and did nothing. On the
/// shipped 0.10.0 (50) that was every Back press while reading a book. The band
/// host says so through `studioTitlebarBandControls`, and this then renders a
/// `TitlebarBandButton`, whose surface the titlebar mouse router delivers the
/// click to. The pop-out reader's `NSToolbar` and in-flow toolbars keep the
/// native button, which works there.
struct ReaderNavigationButton: View {
    let systemImage: String
    let title: String?
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.studioTitlebarBandControls) private var onTitlebarBand

    init(
        systemImage: String,
        title: String? = nil,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        if onTitlebarBand {
            TitlebarBandButton(
                help: help,
                accessibilityIdentifier: ReaderTitlebarActionButton.accessibilityIdentifier(forSystemImage: systemImage),
                controlSize: StudioPanelChrome.readerCloseButtonSize,
                controlWidth: ReaderTitlebarActionButton.bandControlWidth(
                    title: title,
                    controlSize: StudioPanelChrome.readerCloseButtonSize
                ),
                isEnabled: isEnabled,
                action: action
            ) {
                ReaderTitlebarActionLabel(systemImage: systemImage, title: title, isEnabled: isEnabled)
            }
        } else {
            ReaderNavigationNativeButton(
                systemImage: systemImage,
                title: title,
                help: help,
                isEnabled: isEnabled,
                action: action
            )
        }
    }
}

/// The SwiftUI-drawn face of a band-mounted reader action: the same 12pt medium
/// symbol and secondary/tertiary tint `ReaderTitlebarActionButton` paints, so
/// the control looks identical whichever surface owns the click.
struct ReaderTitlebarActionLabel: View {
    let systemImage: String
    let title: String?
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isEnabled ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
    }
}

/// The native form of `ReaderNavigationButton`, for toolbars outside the
/// titlebar band: an `NSButton` that owns its hit target and refuses window
/// dragging.
struct ReaderNavigationNativeButton: NSViewRepresentable {
    let systemImage: String
    var title: String? = nil
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> ReaderTitlebarActionButton {
        let button = ReaderTitlebarActionButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction(_:))
        return button
    }

    func updateNSView(_ button: ReaderTitlebarActionButton, context: Context) {
        context.coordinator.action = action
        button.configure(
            systemImage: systemImage,
            title: title,
            help: help,
            isEnabled: isEnabled,
            accessibilityIdentifier: ReaderTitlebarActionButton.accessibilityIdentifier(forSystemImage: systemImage)
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            action()
        }
    }
}

struct ArticleReaderZoomControls: View {
    let zoomScale: CGFloat
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void

    var body: some View {
        Button {
            zoomOut()
        } label: {
            Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(.hoverWash(inset: -3))
        .keyboardShortcut("-", modifiers: .control)
        .disabled(zoomScale <= ArticleReaderZoom.minScale)
        .help("Zoom out — currently \(Int((zoomScale * 100).rounded()))% (Control-minus)")

        Button {
            zoomIn()
        } label: {
            Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(.hoverWash(inset: -3))
        .keyboardShortcut("+", modifiers: .control)
        .disabled(zoomScale >= ArticleReaderZoom.maxScale)
        .help("Zoom in — currently \(Int((zoomScale * 100).rounded()))% (Control-plus)")

        if zoomScale != ArticleReaderZoom.defaultScale {
            Button {
                resetZoom()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .keyboardShortcut("0", modifiers: .control)
            .help("Reset article zoom (Control-0)")
        }
    }
}

/// Whether a loaded URL is still the document a source names.
///
/// Split out of the reader's coordinator so it can be tested: a publisher's
/// sign-in round trip returns to the article with query it added, and the
/// reader has to recognise that page as the source's own before it saves what
/// it renders.
enum ArticleReaderPageIdentity {
    /// True when `url` names the same document as `sourceURL` and differs only
    /// by query the site added. A source URL that carries its own query is
    /// refused: on a site that addresses documents as `?id=…`, a different
    /// query is a different document.
    static func isSameDocumentIgnoringAddedQuery(_ url: URL?, sourceURL: URL?) -> Bool {
        guard let url, let sourceURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sourceParts = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              sourceParts.query == nil,
              let host = parts.host?.lowercased(),
              let sourceHost = sourceParts.host?.lowercased() else { return false }
        guard host == sourceHost else { return false }
        return normalizedPath(parts.path) == normalizedPath(sourceParts.path)
    }

    /// A trailing slash is not a different document.
    private static func normalizedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }
}

struct ArticleReaderView: View {
    let article: StudioArticle
    /// When true, hides the bottom action bar (used inside CardReviewWorkspace left pane)
    var reviewMode = false
    /// Some host reader shells show their own text-to-speech controls in the title toolbar.
    var showsSpeechControls = true
    /// Embedded reader shells can provide the chrome themselves to avoid stacked toolbars.
    var showsBrowserToolbar = true
    private let externalSpeech: ArticleSpeechService?
    private let externalFindState: ReaderFindState?
    private let chromeState: ArticleReaderChromeState?
    private let selectionChanged: ((String) -> Void)?
    private let usesPersistedTextOnLoadFailure: Bool

    @Environment(StudioViewModel.self) private var vm

    @State private var selectedText = ""
    @State private var isLoading = true
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentDomain = ""
    @State private var currentURL: URL?
    @State private var webViewRef: WKWebView?
    @State private var loadError: String?
    @State private var loadFailureFallbackText: String?
    @State private var zoomPasscodeRevision = 0
    @State private var zoomScale = ArticleReaderZoom.defaultScale
    @State private var ownedFindState = ReaderFindState()
    @State private var articleReturn = ArticleReaderReturnState()
    // Kept only so SwiftUI re-renders when the shared service publishes; hosts
    // can still inject their own reference through `externalSpeech`.
    @ObservedObject private var sharedSpeech = ArticleSpeechService.shared

    private var speech: ArticleSpeechService {
        externalSpeech ?? sharedSpeech
    }

    private var findState: ReaderFindState {
        externalFindState ?? ownedFindState
    }

    init(
        article: StudioArticle,
        reviewMode: Bool = false,
        showsSpeechControls: Bool = true,
        showsBrowserToolbar: Bool = true,
        findState: ReaderFindState? = nil,
        chromeState: ArticleReaderChromeState? = nil,
        speech: ArticleSpeechService? = nil,
        usesPersistedTextOnLoadFailure: Bool = false,
        selectionChanged: ((String) -> Void)? = nil
    ) {
        self.article = article
        self.reviewMode = reviewMode
        self.showsSpeechControls = showsSpeechControls
        self.showsBrowserToolbar = showsBrowserToolbar
        self.externalFindState = findState
        self.chromeState = chromeState
        self.externalSpeech = speech
        self.usesPersistedTextOnLoadFailure = usesPersistedTextOnLoadFailure
        self.selectionChanged = selectionChanged
    }

    /// Gates the context menu's "Chat About Selection" item. The selection chat
    /// action now lives on the in-page callout, but the context menu keeps its
    /// own entry for keyboard and right-click users. Pictures count: a
    /// selection that is only a figure is a selection.
    private var hasTextSelection: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !vm.readerSelectionImages(for: article.id).isEmpty
    }

    private var markPaperPaywalledAction: (() -> Void)? {
        guard article.sourceType == .paper, !article.isPaywalled else { return nil }
        return { Task { await vm.markPaywalled(article) } }
    }

    /// Saved scroll position to resume from, preferring the live progress store
    /// over the article snapshot the host passed in (which may predate it).
    private var savedScrollFraction: Double? {
        ArticleReadingPositionLocator(
            encoded: vm.readingPositionLocator(for: article.id) ?? article.readingPositionLocator
        )?.webScrollFraction
    }

    private func persistScrollFraction(_ fraction: Double) {
        guard let encoded = ArticleReadingPositionLocator(scrollFraction: fraction).encoded else { return }
        vm.updateReadingLocator(for: article.id, locator: encoded)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsBrowserToolbar {
                // Browser toolbar
                readerToolbar
                Divider()
                ReaderFindBar(state: findState)
            }

            // WebView content
            ZStack {
                if case .refused = YouTubeContainment.decision(for: article.url) {
                    // A saved channel, playlist or search page: YouTube's own
                    // pages do not open inside ForeverLM.
                    YouTubePageNotShownView()
                } else if let loadFailureFallbackText,
                   !loadFailureFallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InlineTextReaderView(
                        content: loadFailureFallbackText,
                        sourceID: article.id,
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        navigationTarget: nil,
                        zoomScale: zoomScale,
                        readerTheme: .system,
                        zoomInAction: zoomIn,
                        zoomOutAction: zoomOut,
                        resetZoomAction: resetZoom
                    )
                } else if let error = loadError {
                    ContentUnavailableView {
                        Label("Page Load Failed", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            loadError = nil
                            webViewRef?.reload()
                        }
                        Button("Open in Browser") {
                            if let url = currentBrowserURL {
                                BrowserService.open(url, discoveryOrigin: article.discoveryOrigin)
                            }
                        }
                    }
                } else {
                    WebViewReader(
                        urlString: article.url,
                        articleId: article.id,
                        vm: vm,
                        cachedHTMLPath: article.cachedIsArchivedArticle ? article.cachedResolvedLocalPath : nil,
                        initialScrollFraction: savedScrollFraction,
                        scrollFractionChanged: { persistScrollFraction($0) },
                        readingCompletionReached: {
                            Task { await vm.markArticleReadAfterReachingEnd(article.id) }
                        },
                        selectedText: $selectedText,
                        isLoading: $isLoading,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward,
                        currentDomain: $currentDomain,
                        currentURL: $currentURL,
                        webViewRef: $webViewRef,
                        loadError: $loadError,
                        zoomScale: zoomScale,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        zoomPasscodeRevision: zoomPasscodeRevision,
                        chromeState: chromeState,
                        zoomInAction: zoomIn,
                        zoomOutAction: zoomOut,
                        resetZoomAction: resetZoom,
                        textToSpeechAction: ArticleSpeechContent.canAttemptRead(article) ? { startTextToSpeech() } : nil,
                        explainSelectionAction: { explainSelectedText() },
                        openInSafariAction: { openInSafari() },
                        markPaywalledAction: markPaperPaywalledAction,
                        articleReturn: articleReturn
                    )
                }

            }
            .contextMenu { readerContextMenu }
            .overlay(alignment: .bottom) {
                if articleReturn.isAwayFromArticle, loadError == nil, loadFailureFallbackText == nil {
                    ArticleReaderReturnButton(
                        title: ArticleReaderReturnState.title(for: article.sourceType),
                        articleTitle: vm.displayTitle(for: article),
                        action: { articleReturn.returnToArticle() }
                    )
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: articleReturn.isAwayFromArticle)
            .onChange(of: selectedText) { _, newValue in
                selectionChanged?(newValue)
                vm.updateActiveReaderSelection(sourceID: article.id, text: newValue)
            }
            .onChange(of: findState.searchRevision) { _, _ in
                selectedText = ""
                vm.updateActiveReaderSelection(sourceID: article.id, text: "", images: [])
            }

            // Bottom action bar (only in non-review mode)
            if !reviewMode {
                Divider()
                actionBar
            }
        }
        .onAppear {
            installChromeActions()
            chromeState?.downloadPDF = {
                Task { await downloadPDFFromWebView() }
            }
            chromeState?.savePaperFromPage = {
                Task { await savePaperFromRenderedPage() }
            }
        }
        .onChange(of: article.id) { oldId, _ in
            vm.clearActiveReaderSelection(forSourceID: oldId)
            currentURL = nil
            loadError = nil
            loadFailureFallbackText = nil
            setZoomScale(ArticleReaderZoom.defaultScale)
        }
        .task(id: article.id) {
            await vm.loadReaderHighlightsIfNeeded(for: article.id)
        }
        .task(id: loadError) {
            guard usesPersistedTextOnLoadFailure, loadError != nil else {
                loadFailureFallbackText = nil
                return
            }
            loadFailureFallbackText = await ArticleSpeechContent.persistedText(
                sourceID: article.id
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealReaderHighlight)) { notification in
            guard let request = notification.object as? ReaderHighlightRevealRequest,
                  request.sourceID == article.id,
                  let webView = webViewRef,
                  let highlight = vm.highlight(id: request.highlightID, sourceID: article.id) else { return }
            ReaderWebHighlightSupport.reveal(highlight, in: webView, world: WebViewReader.scriptWorld)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .zoomRecordingPasscodeDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard notification.userInfo?["sourceID"] as? String == article.id else { return }
            zoomPasscodeRevision &+= 1
        }
        .onDisappear {
            vm.clearActiveReaderSelection(forSourceID: article.id)
        }
        .alert("Text to Speech Error", isPresented: Binding(
            get: { speech.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    speech.errorMessage = nil
                }
            }
        )) {
            Button(speech.errorSuggestsProviderSwitch ? "Switch Voice Provider" : "Text to Speech Settings") {
                speech.errorMessage = nil
                TextToSpeechSettingsNavigation.open()
            }
            Button("Open in Safari") {
                speech.errorMessage = nil
                openInSafari()
            }
            Button("OK", role: .cancel) {
                speech.errorMessage = nil
            }
        } message: {
            Text(speech.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    private var readerToolbar: some View {
        HStack(spacing: 8) {
            // Navigation buttons
            ReaderNavigationButton(
                systemImage: "chevron.left",
                help: "Go back",
                isEnabled: canGoBack
            ) {
                webViewRef?.goBack()
            }

            ReaderNavigationButton(
                systemImage: "chevron.right",
                help: "Go forward",
                isEnabled: canGoForward
            ) {
                webViewRef?.goForward()
            }

            // Domain display
            Text(currentDomain.isEmpty ? article.domain : currentDomain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if speech.isVisible && externalSpeech == nil {
                if speech.showsToolbarProgress {
                    ArticleSpeechToolbarProgress(speech: speech)
                }
                ArticleSpeechTransportControls(speech: speech)
            } else if showsSpeechControls {
                ArticleSpeechControls(speech: speech, article: article, showsTitle: false)
            }

            Button {
                findState.show()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Find in reader")

            zoomControls

            // Download PDF button — uses the WebView's session cookies to fetch
            // PDF from publisher sites that block unauthenticated downloads
            // (e.g., Cell.com ePDF viewer, Science.org).
            if article.sourceType == .paper && article.localFilePath == nil {
                Button {
                    Task { await downloadPDFFromWebView() }
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                        .font(.callout)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("Download PDF using browser session")

                // The learner's opt-in for a paper the publisher shows but will
                // not hand over: the page becomes the paper's text and is
                // printed to its PDF.
                Button {
                    Task { await savePaperFromRenderedPage() }
                } label: {
                    Label("Save Paper from Page", systemImage: "doc.text.viewfinder")
                        .font(.callout)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("Save this page as the paper's text and print it to a PDF")
            }

            // Open in browser
            Button {
                openInSafari()
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Open in browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var zoomControls: some View {
        ArticleReaderZoomControls(
            zoomScale: zoomScale,
            zoomIn: zoomIn,
            zoomOut: zoomOut,
            resetZoom: resetZoom
        )
    }

    private func installChromeActions() {
        chromeState?.zoomScale = zoomScale
        chromeState?.zoomIn = { zoomIn() }
        chromeState?.zoomOut = { zoomOut() }
        chromeState?.resetZoom = { resetZoom() }
        chromeState?.setZoom = { setZoomScale($0) }
    }

    private func zoomIn() {
        setZoomScale(zoomScale + ArticleReaderZoom.step)
    }

    private func zoomOut() {
        setZoomScale(zoomScale - ArticleReaderZoom.step)
    }

    private func resetZoom() {
        setZoomScale(ArticleReaderZoom.defaultScale)
    }

    private func setZoomScale(_ scale: CGFloat) {
        let clamped = ArticleReaderZoom.clamped(scale)
        guard ArticleReaderZoom.differs(zoomScale, clamped) else { return }
        zoomScale = clamped
        if let webViewRef {
            ArticleReaderZoom.apply(clamped, to: webViewRef)
        }
        chromeState?.zoomScale = clamped
    }

    @ViewBuilder
    private var readerContextMenu: some View {
        if hasTextSelection {
            Button {
                explainSelectedText()
            } label: {
                Label("Chat About Selection", systemImage: "text.bubble")
            }
        }

        if ArticleSpeechContent.canAttemptRead(article) {
            Button {
                startTextToSpeech()
            } label: {
                Label("Text to Speech", systemImage: "speaker.wave.2")
            }
        }

        if URL(string: article.url) != nil {
            Button {
                openInSafari()
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
        }

        if let markPaperPaywalledAction {
            Button {
                markPaperPaywalledAction()
            } label: {
                Label("Mark Paper as Paywalled", systemImage: "lock.doc")
            }
        }
    }

    private func startTextToSpeech() {
        speech.listen(to: article)
    }

    private func openInSafari() {
        guard let url = currentBrowserURL else { return }
        BrowserService.open(url, discoveryOrigin: article.discoveryOrigin, preference: .safari)
    }

    private func explainSelectedText() {
        vm.requestReaderSelectionExplanation(
            sourceID: article.id,
            selectedText: selectedText,
            images: vm.readerSelectionImages(for: article.id),
            pictureSnapshot: webViewRef.map(ReaderSelectionImageResolver.snapshotter(for:))
        )
    }

    private var currentBrowserURL: URL? {
        if let url = chromeState?.liveBrowserURL(), url.hasWebScheme {
            return url
        }
        if let url = webViewRef?.url, url.hasWebScheme {
            return url
        }
        if let url = currentURL, url.hasWebScheme {
            return url
        }
        return URL(string: article.url)
    }

    private static func isPDFLikeURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        let segments = url.pathComponents.map { $0.lowercased() }
        return segments.contains("pdf") || segments.contains("epdf")
    }

    /// Take the page on screen as the paper, because the learner asked.
    ///
    /// A paper is a PDF. Some publishers show a subscriber the paper on the
    /// site and never offer the file; this is the one route from such a page
    /// to a paper, and it runs only when the learner presses **Save Paper from
    /// Page** with the page in front of them. The page has to be the paper —
    /// not the publisher's access wall, and not a page too short to be one —
    /// and then its text goes through the paper pipeline, the publisher is
    /// asked for the PDF once more with this session, and when it still
    /// refuses, the page is printed to the paper's PDF.
    private func savePaperFromRenderedPage() async {
        guard let webView = webViewRef else { return }
        guard vm.readerCanSavePaperFromPage(article.id) else {
            vm.showToast("This paper already has a PDF, or is still being fetched")
            return
        }
        guard await !pageRequiresHumanVerification(in: webView) else {
            vm.showToast("Complete the human verification in the page, then try Save Paper from Page again")
            return
        }
        guard let page = await WebViewReader.Coordinator.renderedPageSnapshot(of: webView) else {
            vm.showToast("The page has not finished loading")
            return
        }
        let adoption = await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: page.html,
            pageTitle: page.title,
            visibleText: page.text,
            learnerAsked: true
        )
        switch adoption {
        case .adoptedPaperText(needsPDF: true):
            await vm.attachPDFForAdoptedPaperPage(articleId: article.id, printing: webView)
        case .adoptedPaperText(needsPDF: false), .adoptedArticle:
            break
        case .notAdopted(.accessWall):
            vm.showToast("This page is the publisher's access wall, not the paper. Sign in on the page first.")
        case .notAdopted(.tooShort):
            vm.showToast("This page is too short to be the paper: only the abstract and front matter are on it")
        case .notAdopted(.ineligible):
            vm.showToast("This paper already has a PDF, or is still being fetched")
        case .notAdopted(.failed):
            vm.showToast("Could not save the paper from this page")
        }
    }

    /// Download the paper PDF using the WebView's authenticated session.
    /// This works for paywalled sites where the user has logged in via the WebView
    /// (e.g., Cell.com, Science.org) — the cookies carry institutional access.
    private func downloadPDFFromWebView() async {
        guard let webView = webViewRef else { return }
        guard let coordinator = webView.navigationDelegate as? WebViewReader.Coordinator else { return }

        guard await !pageRequiresHumanVerification(in: webView) else {
            vm.showToast("Complete the human verification in the page, then try Download PDF again")
            return
        }

        // PMC may serve an HTML proof-of-work/interstitial response to WKDownload.
        // Route it through SourceService instead, which validates PDF bytes and handles PMC PoW.
        if isPMCDownloadContext(webView: webView) {
            await downloadResolvedPDFThroughSourceService(webView: webView, sourceName: "PubMed Central")
            return
        }

        // Prefer the page's own download control. This more closely matches
        // Safari behavior for sites whose PDF link depends on JS, target=_blank,
        // download attributes, cookies, or redirect chains.
        if await clickPDFDownloadControl(in: webView) {
            vm.showToast("Starting PDF download…")
            return
        }

        guard let url = await resolvedPDFURLForWebViewDownload(webView: webView) else {
            vm.showToast("No PDF link found on this page")
            return
        }

        // Use the WebView's built-in download mechanism so cookies are included
        coordinator.startDownload(URLRequest(url: url), in: webView)
    }

    private func isPMCDownloadContext(webView: WKWebView) -> Bool {
        for raw in [webView.url?.absoluteString, currentBrowserURL?.absoluteString, article.url].compactMap({ $0 }) {
            if PaperService.extractPMCID(from: raw) != nil { return true }
            guard let host = URL(string: raw)?.host?.lowercased() else { continue }
            if host == "pmc.ncbi.nlm.nih.gov" || host.hasSuffix(".ncbi.nlm.nih.gov") {
                return raw.lowercased().contains("/pmc/articles/")
            }
        }
        return false
    }

    @discardableResult
    private func downloadResolvedPDFThroughSourceService(webView: WKWebView, sourceName: String) async -> Bool {
        guard let url = await resolvedPDFURLForWebViewDownload(webView: webView) else {
            vm.showToast("No PDF link found on this page")
            return false
        }

        do {
            vm.showToast("Downloading PDF from \(sourceName)…")
            try await vm.attachPDFFromURL(to: article.id, urlString: url.absoluteString)
            return true
        } catch {
            vm.showToast("Could not download PDF from \(sourceName): \(error.localizedDescription)")
            return false
        }
    }

    private func pageRequiresHumanVerification(in webView: WKWebView) async -> Bool {
        let js = """
        (() => {
          if (document.querySelector('iframe[src*="captcha"], iframe[src*="challenge"], input[name*="cf-turnstile"], .cf-turnstile')) return true;
          return false;
        })();
        """

        return (try? await webView.evaluateJavaScript(js) as? Bool) ?? false
    }

    /// Click the page's own PDF download control. Supplementary files — Nature's
    /// Reporting Summary and Source Data sit under `MediaObjects` on the same
    /// page as the paper — are never candidates, and a control that names the
    /// download ("Download PDF") is preferred over any other `.pdf` link.
    /// Clicks the page's own Download PDF control; the same script the pipeline's
    /// hidden web view runs on a publisher's page (`PublisherPDFDownloadControl`).
    private func clickPDFDownloadControl(in webView: WKWebView) async -> Bool {
        (try? await webView.evaluateJavaScript(PublisherPDFDownloadControl.clickScript) as? Bool) ?? false
    }

    private func resolvedPDFURLForWebViewDownload(webView: WKWebView) async -> URL? {
        var pageURLs: [String] = []
        for raw in [webView.url?.absoluteString, currentBrowserURL?.absoluteString, article.url].compactMap({ $0 }) {
            if !pageURLs.contains(raw) {
                pageURLs.append(raw)
            }
        }

        for raw in pageURLs {
            if let derived = PaperService.paperPDFURL(from: raw),
               let url = URL(string: derived) {
                return url
            }
        }

        // eLife's page advertises no PDF link; its API names the file on the CDN.
        for raw in pageURLs {
            guard let elife = PaperService.eLifeArticle(from: raw),
                  let pdfURL = await PaperService.lookupELifePDFURL(elife),
                  let url = URL(string: pdfURL) else { continue }
            return url
        }

        // PMC article pages deliberately do not have a simple path rewrite.
        // Ask EuropePMC for the actual PDF URL instead of downloading the HTML page.
        for raw in pageURLs {
            guard let pmcid = PaperService.extractPMCID(from: raw),
                  let result = await PaperService.lookupPMCByPMCID(pmcid: pmcid),
                  let pdfURL = result.pdfURL,
                  let url = URL(string: pdfURL) else {
                continue
            }
            return url
        }

        if let livePagePDF = await extractPDFURLFromLoadedPage(webView) {
            return livePagePDF
        }

        for raw in pageURLs {
            if let extracted = await PaperService.extractPDFURLFromWebPage(at: raw),
               let url = URL(string: extracted) {
                return url
            }
        }

        for raw in pageURLs {
            guard let url = URL(string: raw),
                  url.hasWebScheme,
                  Self.isPDFLikeURL(url) else {
                continue
            }
            return url
        }

        return nil
    }

    private func extractPDFURLFromLoadedPage(_ webView: WKWebView) async -> URL? {
        let js = """
        (() => {
          const absolute = (value) => {
            if (!value) return null;
            try { return new URL(value, document.baseURI).href; } catch (e) { return null; }
          };
          const metaSelectors = [
            'meta[name="citation_pdf_url"]',
            'meta[property="citation_pdf_url"]',
            'meta[name="dc.identifier"][content$=".pdf"]'
          ];
          for (const selector of metaSelectors) {
            const value = document.querySelector(selector)?.getAttribute('content');
            const url = absolute(value);
            if (url) return url;
          }
          const supplementary = new RegExp(\(Self.jsStringLiteral(PaperService.supplementaryPDFURLJavaScriptPattern)), 'i');
          const exact = Array.from(document.querySelectorAll('a[href], link[href]')).map((node) => {
            const href = absolute(node.getAttribute('href'));
            const declaredType = (node.getAttribute('type') || '').toLowerCase();
            return { href, declaredType };
          }).filter(item => item.href && !supplementary.test(item.href)
            && (/\\.pdf(?:[?#]|$)/i.test(item.href) || item.declaredType === 'application/pdf'));
          return exact[0]?.href || null;
        })();
        """

        guard let raw = try? await webView.evaluateJavaScript(js) as? String,
              let url = URL(string: raw),
              url.hasWebScheme,
              !PaperService.isSupplementaryPDFURL(url.absoluteString) else {
            return nil
        }
        return url
    }

    /// A Swift string as a JavaScript string literal, for a pattern or value
    /// interpolated into a page script.
    private static func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode([value])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        // `["…"]` → `"…"`
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Bottom Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
        }
        .padding(16)
    }
}

#endif

// MARK: - Reading view

/// Asks for the learner's words and makes their reading version of an article
/// (`ArticleReadingViewService`). One run per source at a time; the Reader
/// redraws on its own when the saved view changes.
@MainActor
@Observable
final class ArticleReadingViewMaker {
    static let shared = ArticleReadingViewMaker()

    private(set) var making: Set<String> = []

    func askAndMake(for article: StudioArticle) {
        guard !making.contains(article.id) else { return }
        let alert = NSAlert()
        alert.messageText = "How do you want to read this?"
        alert.informativeText = "Say it in your own words. The article itself is not changed, and you can switch back to the original any time."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "Remove the inline citations"
        field.stringValue = ArticleReadingViewStore.load(sourceID: article.id)?.instruction
            ?? "Remove the inline citations"
        alert.accessoryView = field
        alert.addButton(withTitle: "Make Reading View")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        make(article, instruction: field.stringValue)
    }

    func make(_ article: StudioArticle, instruction: String) {
        guard !making.contains(article.id) else { return }
        making.insert(article.id)
        Task { [weak self] in
            defer { self?.making.remove(article.id) }
            do {
                let view = try await ArticleReadingViewService.make(
                    sourceID: article.id,
                    title: article.title,
                    instruction: instruction
                )
                if view.removals.isEmpty {
                    Self.tell("Nothing to hide", "The model found nothing in this article that matches “\(view.instruction)”.")
                }
            } catch {
                Self.tell("Couldn't make a reading view", error.localizedDescription)
            }
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The ⋯ menu's reading-view items for an article.
struct ArticleReadingViewMenuItems: View {
    let article: StudioArticle

    var body: some View {
        let maker = ArticleReadingViewMaker.shared
        let isMaking = maker.making.contains(article.id)
        let view = ArticleReadingViewStore.load(sourceID: article.id)

        Button {
            maker.askAndMake(for: article)
        } label: {
            Label(isMaking ? "Making Reading View…" : "Reading View…", systemImage: "text.badge.minus")
        }
        .disabled(isMaking)

        if let view {
            Button {
                ArticleReadingViewStore.setShown(!view.isShown, sourceID: article.id)
            } label: {
                Label(
                    view.isShown ? "Show Original" : "Show My Reading View",
                    systemImage: view.isShown ? "doc.plaintext" : "text.badge.checkmark"
                )
            }
            Button {
                ArticleReadingViewStore.remove(sourceID: article.id)
            } label: {
                Label("Remove Reading View", systemImage: "trash")
            }
        }
    }
}

extension URL {
    /// Whether the address is an http or https link, the kind a reader can
    /// hand to a browser.
    var hasWebScheme: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - A paper's reading view

/// Makes a paper's reading view when the learner asks for one in the Reader's
/// ⋯ menu (`PaperReadingViewService`). One run per paper at a time; the
/// Reader redraws on its own when the saved view changes.
@MainActor
@Observable
final class PaperReadingViewMaker {
    static let shared = PaperReadingViewMaker()

    private(set) var making: Set<String> = []

    func make(_ article: StudioArticle) {
        guard !making.contains(article.id) else { return }
        making.insert(article.id)
        Task { [weak self] in
            defer { self?.making.remove(article.id) }
            do {
                // The click is the learner's ask: the two passes are theirs,
                // not background work.
                try await AIUsageAttribution.$learnerAsked.withValue(true) {
                    _ = try await PaperReadingViewService.make(sourceID: article.id, title: article.title)
                }
            } catch {
                Self.tell("Couldn't make a reading view", error.localizedDescription)
            }
        }
    }

    func setShown(_ shown: Bool, for article: StudioArticle) {
        do {
            try PaperReadingViewStore.setShown(shown, sourceID: article.id)
        } catch {
            Self.tell("Couldn't switch the reading view", error.localizedDescription)
        }
    }

    func remove(for article: StudioArticle) {
        do {
            try PaperReadingViewStore.remove(sourceID: article.id)
        } catch {
            Self.tell("Couldn't remove the reading view", error.localizedDescription)
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The ⋯ menu's reading-view items for a paper: make one, switch between it
/// and the PDF, remove it.
struct PaperReadingViewMenuItems: View {
    let article: StudioArticle

    var body: some View {
        let maker = PaperReadingViewMaker.shared
        let isMaking = maker.making.contains(article.id)
        let view = PaperReadingViewStore.load(sourceID: article.id)

        if let view {
            Button {
                maker.setShown(!view.isShown, for: article)
            } label: {
                Label(
                    view.isShown ? "Show PDF" : "Show Reading View",
                    systemImage: view.isShown ? "doc.richtext" : "text.justify.left"
                )
            }
            Button {
                maker.make(article)
            } label: {
                Label(isMaking ? "Making Reading View…" : "Make Reading View Again", systemImage: "arrow.clockwise")
            }
            .disabled(isMaking)
            Button {
                maker.remove(for: article)
            } label: {
                Label("Remove Reading View", systemImage: "trash")
            }
        } else {
            Button {
                maker.make(article)
            } label: {
                Label(isMaking ? "Making Reading View…" : "Reading View", systemImage: "text.justify.left")
            }
            .disabled(isMaking)
            .help("Re-sets the paper's text as one column, its citations as superscript numbers")
        }
    }
}

/// A paper's Reader: its reading view while one is shown, else its PDF. A
/// source that is not a paper always shows `pdf`.
struct PaperReaderSwitch<PDF: View>: View {
    let article: StudioArticle
    let zoomScale: CGFloat
    @ViewBuilder let pdf: () -> PDF

    /// Bumped when this paper's reading view is made, switched or removed,
    /// so the store is asked again.
    @State private var changes = 0

    var body: some View {
        Group {
            if article.sourceType == .paper,
               let readingView = PaperReadingViewStore.load(sourceID: article.id),
               readingView.isShown {
                PaperReadingViewPane(article: article, readingView: readingView, zoomScale: zoomScale)
            } else {
                pdf()
            }
        }
        .id(changes)
        .onReceive(NotificationCenter.default.publisher(for: .paperReadingViewChanged)) { note in
            guard note.userInfo?["sourceID"] as? String == article.id else { return }
            changes += 1
        }
    }
}

/// The paper as one column of text: headings, paragraphs, and each citation
/// as superscript numbers that open the reference they name.
struct PaperReadingViewPane: View {
    let article: StudioArticle
    let readingView: PaperReadingView
    let zoomScale: CGFloat

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.readerOpensCitedSource) private var opensCitedSource
    @State private var rows: [Row] = []
    @State private var index: PaperReferenceIndex?
    @State private var shown: Shown?

    struct Row: Identifiable {
        let id: Int
        let isHeading: Bool
        let text: AttributedString
    }

    /// The reference a clicked number opened, and the paragraph it is in.
    struct Shown: Equatable {
        let row: Int
        let ordinal: Int
        let number: Int
    }

    private static let citationScheme = "foreverlm-citation"
    private var bodySize: CGFloat { 15 * zoomScale }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14 * zoomScale) {
                ForEach(rows) { row in
                    paragraph(row)
                }
            }
            .frame(maxWidth: 680 * zoomScale, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.citationScheme else { return .systemAction }
            open(url)
            return .handled
        })
        .task(id: "\(article.id)|\(readingView.createdAt.timeIntervalSince1970)|\(zoomScale)") { await build() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.paperReadingView")
    }

    private func paragraph(_ row: Row) -> some View {
        Text(row.text)
            .font(.system(size: row.isHeading ? bodySize * 1.15 : bodySize, weight: row.isHeading ? .semibold : .regular, design: .serif))
            .lineSpacing(bodySize * 0.35)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, row.isHeading ? 10 * zoomScale : 0)
            .popover(
                isPresented: Binding(
                    get: { shown?.row == row.id },
                    set: { if !$0, shown?.row == row.id { shown = nil } }
                ),
                arrowEdge: .trailing
            ) {
                if let shown, let reference = index?.reference(forNumber: shown.ordinal) {
                    PaperReadingReferenceCard(
                        reference: reference,
                        number: shown.number,
                        openSource: { sourceID in
                            self.shown = nil
                            if let opensCitedSource {
                                opensCitedSource(sourceID)
                            } else {
                                Task { await vm.selectReaderSource(sourceID) }
                            }
                        }
                    )
                    .environment(vm)
                }
            }
    }

    /// The rows as drawn: the stored paragraphs with the citations the
    /// paper's reference list can name turned into numbers.
    private func build() async {
        let index = await vm.paperReferenceIndex(forSource: article.id)
        let paragraphs = readingView.paragraphs
        let size = bodySize
        let built = await Task.detached(priority: .userInitiated) {
            let runs = PaperReadingViewBuilder.runs(of: paragraphs, index: index)
            return zip(paragraphs, runs).enumerated().map { offset, pair in
                Row(id: offset, isHeading: pair.0.isHeading, text: Self.attributed(pair.1, row: offset, size: size))
            }
        }.value
        guard !Task.isCancelled else { return }
        self.index = index
        rows = built
    }

    /// A paragraph's runs as text: each citation's numbers small and raised,
    /// each number a link naming its paragraph, its reference and itself.
    nonisolated static func attributed(_ runs: [PaperReadingRun], row: Int, size: CGFloat) -> AttributedString {
        var text = AttributedString()
        func raised(_ string: String) -> AttributedString {
            var piece = AttributedString(string)
            piece.swiftUI.font = .system(size: size * 0.66)
            piece.swiftUI.baselineOffset = size * 0.4
            return piece
        }
        for run in runs {
            switch run {
            case .text(let string):
                text.append(AttributedString(string))
            case .citation(let references):
                for (offset, reference) in references.enumerated() {
                    if offset > 0 { text.append(raised(",")) }
                    var number = raised(String(reference.number))
                    number.link = URL(string: "\(citationScheme)://\(row)/\(reference.ordinal)/\(reference.number)")
                    text.append(number)
                }
            }
        }
        return text
    }

    private func open(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let row = url.host.flatMap(Int.init), parts.count == 2,
              let ordinal = Int(parts[0]), let number = Int(parts[1]) else { return }
        shown = Shown(row: row, ordinal: ordinal, number: number)
    }
}

/// One reference, opened from its number in the reading view: who and what
/// it is, the way to it in the library (or into it), and its link.
private struct PaperReadingReferenceCard: View {
    let reference: PaperReference
    let number: Int
    let openSource: (String) -> Void

    @Environment(StudioViewModel.self) private var vm
    @State private var status: ArtifactReferenceStatus?
    @State private var isAdding = false

    var body: some View {
        let summary = PaperReferenceSummary(entryText: reference.text, stored: reference)
        VStack(alignment: .leading, spacing: 8) {
            if let title = summary.title {
                VStack(alignment: .leading, spacing: 3) {
                    Text([String(number), summary.byline].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
            } else {
                Text(reference.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = reference.linkURL {
                HStack(spacing: 12) {
                    action(href: link.absoluteString)
                    Spacer(minLength: 0)
                    Button { WebLinkOpening.open(link) } label: {
                        Label(ReaderReferenceLink.displayText(for: link), systemImage: "link")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                    .help("Open \(link.absoluteString)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(12)
        .task(id: reference.id) {
            guard let href = reference.linkURL?.absoluteString else { return }
            status = await vm.referenceLibraryStatuses(for: [href])[href]
        }
    }

    @ViewBuilder
    private func action(href: String) -> some View {
        if isAdding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Adding…")
            }
            .fixedSize()
        } else if let status {
            switch status.state {
            case .inLibrary:
                if let sourceID = status.sourceID {
                    Button { openSource(sourceID) } label: { Label("Open", systemImage: "arrow.up.right") }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                        .fixedSize()
                }
            case .absent:
                Button { add(href) } label: { Label("Add to Library", systemImage: "plus") }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                    .fixedSize()
            case .failed:
                Text(status.message ?? "The paper could not be added.")
            case .adding, .requestable, .requested, .fulfillable:
                EmptyView()
            }
        }
    }

    private func add(_ href: String) {
        isAdding = true
        Task {
            let added = await vm.addReferenceToLibrary(href)
            isAdding = false
            status = added
            if added.state == .inLibrary, let sourceID = added.sourceID { openSource(sourceID) }
        }
    }
}
