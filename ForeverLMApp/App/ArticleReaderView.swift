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
        if let resolvedURL, Self.canOpenExternally(resolvedURL) {
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

    private static func canOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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
        if let url = chromeState?.liveBrowserURL(), Self.canOpenExternally(url) {
            return url
        }
        if let url = webViewRef?.url, Self.canOpenExternally(url) {
            return url
        }
        if let url = currentURL, Self.canOpenExternally(url) {
            return url
        }
        return URL(string: article.url)
    }

    private static func canOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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
                  Self.canOpenExternally(url),
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
              Self.canOpenExternally(url),
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

// MARK: - Reader Web View Reuse

/// The reader's slot in the view hierarchy, held separately from the web view
/// that fills it.
///
/// SwiftUI can build a remounted representable's view *before* it dismantles the
/// one it replaces (the same ordering `ArticleReaderChromeState.unbindNavigation`
/// guards against), so at `makeNSView` time a reader cannot yet know whether its
/// predecessor is about to park a loaded page for it to adopt. Returning a host
/// that fills itself in once the current run loop turn has finished makes that
/// answer available in time, whichever order the two calls arrive in.
final class ReaderWebViewHost: NSView {
    private(set) var webView: ForeverLMWebView?
    /// Browser-style load feedback along the top edge, above the page. Owned by
    /// the host rather than the web view so it survives the page moving between
    /// hosts, and driven by KVO so a navigation the delegate never hears about
    /// — a bot check reloading itself, a redirect chain — still shows.
    let progressBar = ReaderLoadProgressBar(frame: .zero)
    private var progressObservations: [NSKeyValueObservation] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(progressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ webView: ForeverLMWebView) {
        guard self.webView !== webView else { return }
        stopObservingProgress()
        self.webView?.removeFromSuperview()
        self.webView = webView
        webView.frame = bounds
        addSubview(webView, positioned: .below, relativeTo: progressBar)
        observeProgress(of: webView)
        needsLayout = true
    }

    /// Hand the web view back to the caller and stop tracking it. Frame-driven
    /// rather than constraint-driven on purpose: the same view moves between
    /// hosts, and constraints would have to be torn down on every move.
    func releaseWebView() -> ForeverLMWebView? {
        guard let webView else { return nil }
        stopObservingProgress()
        self.webView = nil
        webView.removeFromSuperview()
        return webView
    }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        progressBar.frame = CGRect(
            x: 0,
            y: bounds.height - ReaderLoadProgressBar.thickness,
            width: bounds.width,
            height: ReaderLoadProgressBar.thickness
        )
    }

    private func observeProgress(of webView: ForeverLMWebView) {
        let publish: (WKWebView) -> Void = { [weak self] webView in
            self?.progressBar.update(
                isLoading: webView.isLoading,
                estimatedProgress: webView.estimatedProgress
            )
        }
        progressObservations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { webView, _ in
                MainActor.assumeIsolated { publish(webView) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { publish(webView) }
            },
        ]
    }

    private func stopObservingProgress() {
        progressObservations.forEach { $0.invalidate() }
        progressObservations = []
        progressBar.reset()
    }
}

/// Keeps a dismantled reader's loaded page alive long enough for the reader to
/// come back to it.
///
/// Creating a `WKWebView` and loading a publisher's page is the most expensive
/// thing the reader does, and a remount carries no new content: moving a center
/// tab between groups, closing a pane and restoring a workspace all tear the
/// reader's subtree down and rebuild it around the same article. Parking the
/// page means the rebuilt reader shows the document, scroll offset and
/// back/forward list it had a moment ago instead of paying for the network
/// round trip a second time.
///
/// `ChatMarkdownView` keeps a pool of the same shape for chat bubbles, but its
/// members are interchangeable — any parked view can render any message. A
/// reader's page is not interchangeable, so these are claimed by key.
@MainActor
enum ReaderWebViewPark {
    /// How long a page waits to be reclaimed. A remount comes back within the
    /// same run loop turn; the rest of the window is there so a learner who
    /// switches sources and changes their mind lands back on a live page.
    /// Short, because a parked page is a tab nobody can see.
    ///
    /// `nonisolated` so `park` can name it as a default argument: a default
    /// argument is evaluated at the call site, which is a nonisolated position.
    nonisolated static let lifetimeSeconds: TimeInterval = 30

    /// How long a parked page keeps playing before it is silenced. Long enough
    /// for a remount to reclaim it mid-video, short enough that a reader the
    /// learner really closed does not keep talking.
    static let mediaGraceSeconds: TimeInterval = 0.75

    /// Two, so the pages either side of a split can both survive a workspace
    /// restore, and no more: each entry holds a live web process.
    static let capacity = 2

    private static var entries: [Entry] = []

    /// A parked reader: the web view, still holding its document, plus the
    /// page decisions its coordinator had already made about that document.
    @MainActor
    final class Entry {
        let key: String
        let webView: ForeverLMWebView
        let pageState: WebViewReader.ParkedPageState
        fileprivate var expiry: Task<Void, Never>?

        fileprivate init(
            key: String,
            webView: ForeverLMWebView,
            pageState: WebViewReader.ParkedPageState
        ) {
            self.key = key
            self.webView = webView
            self.pageState = pageState
        }
    }

    /// The keys currently holding a page, oldest first. Reflects the park's
    /// own bookkeeping, which is all the tests need to see of it.
    static var parkedKeys: [String] {
        entries.map(\.key)
    }

    static func park(
        _ webView: ForeverLMWebView,
        key: String,
        pageState: WebViewReader.ParkedPageState,
        lifetime: TimeInterval = lifetimeSeconds
    ) {
        webView.prepareForParking()
        let entry = Entry(key: key, webView: webView, pageState: pageState)
        entries.append(entry)
        while entries.count > capacity {
            discard(entries.removeFirst())
        }
        let grace = min(max(mediaGraceSeconds, 0), lifetime)
        entry.expiry = Task { @MainActor [weak entry] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let parked = entry else { return }
            parked.webView.pauseAllMediaPlayback(completionHandler: nil)
            try? await Task.sleep(nanoseconds: UInt64((lifetime - grace) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            entries.removeAll { $0 === parked }
            discard(parked)
        }
    }

    /// Hand back the page parked under `key`, if one is still waiting for it.
    static func claim(key: String) -> Entry? {
        guard let index = entries.lastIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entry.expiry?.cancel()
        entry.expiry = nil
        // A page WebKit has since thrown away, or one a retry sent back to the
        // network while it was parked, would come back blank or half-drawn —
        // both worse than the load this is avoiding.
        guard entry.webView.url != nil, !entry.webView.isLoading else {
            discard(entry)
            return nil
        }
        return entry
    }

    /// Let every parked page go at once, rather than waiting each one out.
    static func evictAll() {
        let leaving = entries
        entries.removeAll()
        leaving.forEach(discard)
    }

    private static func discard(_ entry: Entry) {
        entry.expiry?.cancel()
        entry.expiry = nil
        // The teardown the reader used to do inline: stop whatever the page is
        // still running before letting go of it.
        entry.webView.loadHTMLString("", baseURL: nil)
    }
}

// MARK: - WebView NSViewRepresentable

struct WebViewReader: NSViewRepresentable {
    /// Where the reader's own scripts and their `foreverlm` handler live.
    ///
    /// An article is a publisher's live page, and its script runs in the
    /// page's world: a handler there would take a `chatRequest`, a
    /// `highlightRequest` or a `scrollPosition` that marks the article read
    /// from the publisher as readily as from the reader. A content world of
    /// the app's own shares the page's DOM — selections, events, highlights —
    /// but not its script, so the page cannot see the handler at all. Every
    /// script that posts to it is installed here, and every call into those
    /// scripts (`ReaderWebHighlightSupport`, `ReaderPassageFlash`) is made
    /// here. Scripts that only dress the page (colours, Dark Mode, the
    /// reading view, zoom) stay in the page's world.
    static let scriptWorld = WKContentWorld.world(name: "ForeverLMArticleReader")
    static let messageHandlerName = "foreverlm"

    let urlString: String
    let articleId: String
    let vm: StudioViewModel
    /// Optional path to a cached HTML file used as offline fallback when the live page fails to load
    /// or stalls past the initial-load window (see the Coordinator's stall fallback).
    let cachedHTMLPath: String?
    /// Saved scroll fraction to restore once the article's page finishes loading.
    let initialScrollFraction: Double?
    /// Debounced scroll-position reports from the article's own page (in-reader
    /// navigations to other pages are not reported).
    let scrollFractionChanged: (Double) -> Void
    /// Fires when a user-driven scroll reaches the end of the article's content.
    /// Position restoration and layout-driven scrolling are deliberately excluded.
    let readingCompletionReached: () -> Void
    @Binding var selectedText: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var currentDomain: String
    @Binding var currentURL: URL?
    @Binding var webViewRef: WKWebView?
    @Binding var loadError: String?
    let zoomScale: CGFloat
    let findState: ReaderFindState
    let findRevision: Int
    /// Changes whenever this source's saved Zoom passcode changes, allowing an
    /// already-open password gate to react without reloading or polling.
    let zoomPasscodeRevision: Int
    let chromeState: ArticleReaderChromeState?
    let zoomInAction: (() -> Void)?
    let zoomOutAction: (() -> Void)?
    let resetZoomAction: (() -> Void)?
    let textToSpeechAction: (() -> Void)?
    let explainSelectionAction: (() -> Void)?
    let openInSafariAction: (() -> Void)?
    let markPaywalledAction: (() -> Void)?
    /// Told whenever the page on screen stops or starts being the article, so
    /// the reader can offer the way back (`ArticleReaderReturnState`).
    var articleReturn: ArticleReaderReturnState? = nil
    /// Read here rather than passed in: this is the one view that renders a
    /// publisher's own page, and reading the environment itself is what makes an
    /// already-open article follow the Mac instead of waiting for a reload.
    @Environment(\.colorScheme) private var colorScheme
    /// The Studio window this reader is drawn in: a passage asked for another
    /// window's Reader is not this one's (`ReaderRequestWindow`).
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The reader's opt-out from the forced-dark pass. A page with a dark design
    /// of its own is unaffected either way: this only ever governs the inversion.
    @SyncedStorage(ReaderDarkMode.originalPageColorsKey) private var originalPageColors = false

    private var darkensPage: Bool {
        ReaderDarkMode.darkensPage(in: colorScheme, originalPageColors: originalPageColors)
    }

    private static func canOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// The page-scoped decisions a reader has already made, handed to whichever
    /// reader inherits its parked web view. The web view itself brings the
    /// document, the scroll offset and the back/forward list; these are the
    /// things a fresh coordinator would otherwise re-derive from a first load
    /// that is never going to happen again.
    struct ParkedPageState {
        var initialPageURL: URL?
        var didFallBackToCache: Bool
        var hasCommittedNavigation: Bool
        var hasCheckedLivePageReadability: Bool
        var lastArticleScrollOffset: Double? = nil
        var hasLeftArticlePage = false
        var pageScrollOffsets: [String: Double] = [:]
    }

    func makeNSView(context: Context) -> ReaderWebViewHost {
        WebPagePolicy.library = vm
        let host = ReaderWebViewHost()
        if let parked = ReaderWebViewPark.claim(key: context.coordinator.reuseKey) {
            adopt(parked, into: host, coordinator: context.coordinator)
            return host
        }
        // The reader this one replaces may not have been dismantled yet, so its
        // page may not be parked yet either. Deciding at the end of the run
        // loop turn instead of here is what makes moving a reader between panes
        // cost nothing, rather than a second full load of the page already on
        // screen.
        let coordinator = context.coordinator
        let key = coordinator.reuseKey
        DispatchQueue.main.async { [weak host] in
            guard let host, host.webView == nil else { return }
            if let parked = ReaderWebViewPark.claim(key: key) {
                self.adopt(parked, into: host, coordinator: coordinator)
            } else {
                self.startLoading(in: host, coordinator: coordinator)
            }
        }
        return host
    }

    /// Take over the page a departing reader parked: same document, same scroll
    /// offset, same history, no load.
    private func adopt(
        _ parked: ReaderWebViewPark.Entry,
        into host: ReaderWebViewHost,
        coordinator: Coordinator
    ) {
        let webView = parked.webView
        coordinator.adoptParkedPage(parked.pageState)
        // The user scripts are still installed on the page's own content
        // controller; only the message handler the departing reader detached
        // has to be put back.
        webView.configuration.userContentController.add(
            coordinator,
            contentWorld: Self.scriptWorld,
            name: Self.messageHandlerName
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        host.install(webView)
        coordinator.observeLocation(of: webView)
        apply(to: webView, coordinator: coordinator)

        DispatchQueue.main.async { [webView] in
            self.webViewRef = webView
            self.chromeState?.bindNavigation(to: webView)
            // Nothing is going to load, so the navigation callbacks that
            // normally publish the reader's state never fire for this page.
            coordinator.publishAdoptedPageState(in: webView)
        }
    }

    /// Build a reader web view from scratch and send it after the source's page.
    private func startLoading(in host: ReaderWebViewHost, coordinator: Coordinator) {
        let config = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: config)
        SharedWebKit.disableSystemWritingTools(on: config)
        config.websiteDataStore = .default()
        // A YouTube player an article embeds shows no suggestions.
        YouTubeDistractionFilter.attach(to: config.userContentController)

        // The handler the reader's scripts post to, out of the page's reach
        // (`scriptWorld`).
        let contentController = config.userContentController
        contentController.add(coordinator, contentWorld: Self.scriptWorld, name: Self.messageHandlerName)

        // Existing archived files predate the reader color rules. Install the
        // same stylesheet at document start so they become readable immediately,
        // while leaving live publisher pages untouched.
        let archivedArticleColorScript = WKUserScript(
            source: Self.archivedArticleColorJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(archivedArticleColorScript)

        // Inject selection detection script
        let selectionScript = WKUserScript(
            source: Self.selectionDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.scriptWorld
        )
        contentController.addUserScript(selectionScript)
        let linkHoverScript = WKUserScript(
            source: ReaderLinkHoverFeedback.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(linkHoverScript)
        let readingViewScript = WKUserScript(
            source: ReaderReadingView.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(readingViewScript)
        // Injected at document start: a right-click can land before the page has
        // finished loading, and the reader's link commands need the destination.
        let contextLinkScript = WKUserScript(
            source: ReaderContextLinkTracking.injectionScript(handlerName: Self.messageHandlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.scriptWorld
        )
        contentController.addUserScript(contextLinkScript)
        // No math typesetting here: an article renders as its author wrote it, so
        // two dollar amounts in a sentence are never read as a LaTeX span.
        let scrollPreservationScript = WKUserScript(
            source: ReaderScrollPreservation.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(scrollPreservationScript)
        let scrollReportScript = WKUserScript(
            source: Self.scrollReportJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.scriptWorld
        )
        contentController.addUserScript(scrollReportScript)
        // Installed unconditionally and inert until told otherwise, so a switch
        // to Dark Mode reaches the page already on screen.
        let forcedDarkScript = WKUserScript(
            source: ReaderDarkMode.forcedDarkWebPageScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(forcedDarkScript)

        let webView = ForeverLMWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.customUserAgent = SharedWebKit.desktopSafariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        host.install(webView)
        coordinator.observeLocation(of: webView)
        apply(to: webView, coordinator: coordinator)

        // Store reference
        DispatchQueue.main.async { [webView] in
            self.webViewRef = webView
            self.chromeState?.bindNavigation(to: webView)
        }
        Task { @MainActor in
            self.chromeState?.setLoading(true, from: webView)
        }

        // Load the URL
        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                if Self.canOpenExternally(url) {
                    self.currentURL = url
                }
            }
            Task { @MainActor in
                if Self.canOpenExternally(url) {
                    self.chromeState?.updateNavigationState(from: webView, currentURL: url)
                }
            }
            webView.load(URLRequest(url: url))
        }
    }

    func updateNSView(_ host: ReaderWebViewHost, context: Context) {
        // Don't reload on SwiftUI updates — the WebView manages its own navigation
        guard let webView = host.webView else { return }
        chromeState?.bindNavigation(to: webView)
        apply(to: webView, coordinator: context.coordinator)
    }

    /// Everything the reader's SwiftUI state controls, pushed to whichever web
    /// view currently fills the host. Shared by the first fill and every later
    /// update, because a host is filled after `makeNSView` has already returned
    /// and can miss the update that would otherwise have configured it.
    private func apply(to webView: ForeverLMWebView, coordinator: Coordinator) {
        webView.findState = findState
        webView.canTextToSpeech = textToSpeechAction != nil
        webView.textToSpeechAction = textToSpeechAction
        webView.explainSelectionAction = explainSelectionAction
        webView.openInSafariAction = openInSafariAction
        webView.markPaywalledAction = markPaywalledAction
        webView.zoomInAction = zoomInAction
        webView.zoomOutAction = zoomOutAction
        webView.resetZoomAction = resetZoomAction
        Self.applyLinkMenuActions(to: webView, coordinator: coordinator)
        ArticleReaderZoom.apply(zoomScale, to: webView)
        ReaderDarkMode.apply(darkensPage, to: webView)
        coordinator.performFindIfNeeded(in: webView, revision: findRevision, state: findState)
        coordinator.refreshZoomPasscodeIfNeeded(in: webView, revision: zoomPasscodeRevision)
        coordinator.applyHighlightsIfNeeded(vm.highlights(for: articleId), to: webView)
        coordinator.passageTracker.readerWindowID = windowState?.id
        coordinator.applyPassageTargetIfNeeded(to: webView)
    }

    /// Hand the reader's own handlers to the link context menu. Without these
    /// the menu still lists "Open Link", "Open Link in New Window" and "Download
    /// Linked File", but WebKit answers them in the web process, where the
    /// download never becomes a `WKDownload` and the new window is never opened.
    private static func applyLinkMenuActions(to webView: ForeverLMWebView, coordinator: Coordinator) {
        webView.openLinkAction = { [weak webView] url in
            guard let webView else { return }
            coordinator.openLinkFromContextMenu(url, in: webView)
        }
        webView.openLinkInNewTabAction = { url in
            coordinator.openLinkInNewTab(url)
        }
        webView.openLinkExternallyAction = { url in
            BrowserService.open(url)
        }
        webView.downloadLinkAction = { [weak webView] url in
            guard let webView else { return }
            coordinator.downloadLinkedFile(at: url, in: webView)
        }
    }

    static func dismantleNSView(_ host: ReaderWebViewHost, coordinator: Coordinator) {
        guard let webView = host.releaseWebView() else { return }
        coordinator.stopObservingLocation()
        coordinator.parent.chromeState?.unbindNavigation(from: webView)
        // WKUserContentController retains the message handler strongly — remove it
        // to break the retain cycle and prevent use-after-free crashes.
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: messageHandlerName,
            contentWorld: scriptWorld
        )
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        // A page still on its way in has nothing worth keeping, and would come
        // back mid-navigation with no delegate having listened to it.
        guard coordinator.hasSettledPage, !webView.isLoading else {
            // Stop any playing media (e.g. embedded YouTube videos) when the view is removed
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        ReaderWebViewPark.park(
            webView,
            key: coordinator.reuseKey,
            pageState: coordinator.parkedPageState()
        )
    }

    // MARK: - Selection Detection JavaScript

    static let selectionDetectionJS = [
        ReaderSelectionCalloutJavaScript.injectionScript(handlerName: messageHandlerName),
        ReaderWebHighlightSupport.installerScript(handlerName: messageHandlerName),
        ReaderPassageFlash.webInstallerScript,
    ].joined(separator: "\n")

    static let archivedArticleColorJS = """
    (function() {
        if (window.location.protocol !== 'file:') return;
        var style = document.createElement('style');
        style.id = 'foreverlm-archived-article-colors';
        style.textContent = `
    \(SourceService.archivedArticleColorCSS)
        `;
        (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Posts the page's scroll fraction (debounced) through the existing
    /// "foreverlm" handler so the reader can resume where the learner left off.
    static let scrollReportJS = ArticleScrollTracking.injectionScript(handlerName: messageHandlerName)

    /// Fill and submit Zoom's passcode gate without putting the credential in
    /// the source URL, page history, SQLite, or logs. Zoom renders this form
    /// asynchronously, so a short-lived MutationObserver waits for the input
    /// instead of polling the page.
    static func zoomPasscodeAutofillScript(passcode: String) -> String {
        let encodedPasscode = Data(passcode.utf8).base64EncodedString()
        return """
        (function() {
            if (window.__foreverlmZoomPasscodeAutofillCleanup) {
                window.__foreverlmZoomPasscodeAutofillCleanup();
            }

            const bytes = Uint8Array.from(
                atob('\(encodedPasscode)'),
                character => character.charCodeAt(0)
            );
            const passcode = new TextDecoder().decode(bytes);
            let submitted = false;
            var observer = null;
            var expiry = null;

            function fieldSignature(field) {
                return [
                    field.type,
                    field.name,
                    field.id,
                    field.placeholder,
                    field.getAttribute('aria-label')
                ].filter(Boolean).join(' ').toLowerCase();
            }

            function submitPasscode() {
                if (submitted) { return true; }
                const input = Array.from(document.querySelectorAll('input')).find(field => {
                    const signature = fieldSignature(field);
                    return field.type === 'password'
                        || signature.includes('passcode')
                        || signature.includes('password')
                        || signature.includes('passwd');
                });
                if (!input) { return false; }

                submitted = true;
                input.focus();
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLInputElement.prototype,
                    'value'
                )?.set;
                if (setter) {
                    setter.call(input, passcode);
                } else {
                    input.value = passcode;
                }
                input.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    inputType: 'insertText',
                    data: passcode
                }));
                input.dispatchEvent(new Event('change', { bubbles: true }));

                setTimeout(function() {
                    const controls = Array.from(document.querySelectorAll(
                        'button, input[type="submit"], [role="button"]'
                    ));
                    const submit = controls.find(control => {
                        const label = [
                            control.innerText,
                            control.value,
                            control.getAttribute('aria-label')
                        ].filter(Boolean).join(' ');
                        return /watch\\s+recording|view\\s+recording|submit|continue/i.test(label);
                    });
                    if (submit && !submit.disabled) {
                        submit.click();
                    } else if (input.form) {
                        if (input.form.requestSubmit) {
                            input.form.requestSubmit();
                        } else {
                            input.form.submit();
                        }
                    }
                }, 100);
                return true;
            }

            function cleanup() {
                if (observer) { observer.disconnect(); }
                if (expiry) { clearTimeout(expiry); }
                delete window.__foreverlmZoomPasscodeAutofillCleanup;
            }
            window.__foreverlmZoomPasscodeAutofillCleanup = cleanup;

            if (!submitPasscode()) {
                observer = new MutationObserver(function() {
                    if (submitPasscode()) { cleanup(); }
                });
                observer.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
                expiry = setTimeout(cleanup, 15000);
            } else {
                cleanup();
            }
        })();
        """
    }

    /// JavaScript to extract article content from the loaded page (mirrors content.js logic).
    static let contentExtractionJS = """
    (function() {
        const selectors = ['article', 'main', '[role="main"]', '.post-content', '.article-content'];
        let root = null;
        for (const sel of selectors) {
            const node = document.querySelector(sel);
            if (node && node.innerText && node.innerText.length > 400) {
                root = node;
                break;
            }
        }
        if (!root) root = document.body;

        const clone = root.cloneNode(true);
        clone.querySelectorAll('script, style, noscript, nav, footer, aside, form, .sidebar, .ad, .advertisement').forEach(n => n.remove());

        const paragraphs = Array.from(clone.querySelectorAll('p, li, h1, h2, h3, h4, blockquote'))
            .map(n => (n.textContent || '').replace(/\\s+/g, ' ').trim())
            .filter(t => t.length > 40);

        let content = paragraphs.join('\\n\\n');
        if (content.length < 300) {
            content = (clone.innerText || '').replace(/\\s+/g, ' ').trim();
        }

        return content.slice(0, 120000);
    })()
    """

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: WebViewReader
        /// Tracks whether we already fell back to the cached HTML to avoid retry loops.
        private var didFallBackToCache = false
        /// How long the article's first load may run without the live document
        /// committing before the reader shows the saved copy instead. A
        /// connection that is up but effectively dead (in-flight wifi) stalls in
        /// the provisional phase for WebKit's full timeout — near a minute —
        /// without ever reaching the didFail fallback. Instance-settable so
        /// tests can exercise the stall without waiting it out.
        var initialLoadStallFallbackSeconds: TimeInterval = 8
        private var initialLoadStallFallbackTask: Task<Void, Never>?
        /// Once the live document is streaming in, a slow finish is progressive
        /// rendering, not a stall, and swapping in the archive would replace
        /// content the learner can already see.
        private var hasCommittedNavigation = false
        private var lastZoomPasscodeRevision = 0
        private var zoomPasscodeRequest = 0

        /// Identifies this reader's page in `ReaderWebViewPark`: the same
        /// source, at the same URL, for the same reader navigation.
        ///
        /// Captured once here rather than read live, because the navigation
        /// revision is the whole point. Re-selecting a source row bumps it
        /// deliberately, so that an already-open reader that has been browsed
        /// away from its source goes back and loads the source afresh. Reading
        /// it at dismantle time would park the outgoing page under the incoming
        /// reader's key, and the reload that re-selection exists to perform
        /// would quietly become a no-op.
        let reuseKey: String

        init(parent: WebViewReader) {
            self.parent = parent
            self.reuseKey = [
                parent.articleId,
                parent.urlString,
                String(parent.vm.readerNavigationRevision(for: parent.articleId)),
            ].joined(separator: "\n")
        }

        // MARK: Surviving a remount

        /// Whether the page this reader is showing is settled enough to be
        /// worth parking. A reader still waiting for its article's first paint
        /// has nothing to preserve, and a fresh load is what it wants anyway.
        var hasSettledPage: Bool {
            initialPageURL != nil
        }

        /// What this reader knows about its page, for the reader that inherits it.
        func parkedPageState() -> ParkedPageState {
            ParkedPageState(
                initialPageURL: initialPageURL,
                didFallBackToCache: didFallBackToCache,
                hasCommittedNavigation: hasCommittedNavigation,
                hasCheckedLivePageReadability: hasCheckedLivePageReadability,
                lastArticleScrollOffset: lastArticleScrollOffset,
                hasLeftArticlePage: hasLeftArticlePage,
                pageScrollOffsets: pageScrollOffsets
            )
        }

        /// Inherit what the departing reader knew about the page now on screen.
        /// Without this a fresh coordinator would treat the learner's next click
        /// as the article's own first load: re-arming the stall fallback, so a
        /// slow external page gets replaced by the archived article; re-running
        /// the unreadable-page check; and accepting that page's scroll offsets
        /// as the article's saved reading position.
        func adoptParkedPage(_ state: ParkedPageState) {
            initialPageURL = state.initialPageURL
            didFallBackToCache = state.didFallBackToCache
            hasCommittedNavigation = state.hasCommittedNavigation
            hasCheckedLivePageReadability = state.hasCheckedLivePageReadability
            lastArticleScrollOffset = state.lastArticleScrollOffset
            hasLeftArticlePage = state.hasLeftArticlePage
            pageScrollOffsets = state.pageScrollOffsets
            // A remount is not a passcode change, so start the revision count
            // from where the rebuilt host is rather than from zero.
            lastZoomPasscodeRevision = parent.zoomPasscodeRevision
        }

        /// Publish the state of an adopted page. The navigation callbacks that
        /// normally do this only fire for a load, and an adopted page has
        /// already finished the only one it needed.
        @MainActor
        func publishAdoptedPageState(in webView: WKWebView) {
            parent.isLoading = false
            parent.loadError = nil
            updateReaderLocation(for: webView)
            parent.chromeState?.setLoading(false, from: webView)
            publishArticleReturn(for: webView)
        }

        // MARK: Following the page

        private var locationObservations: [NSKeyValueObservation] = []

        /// Watch the page's address, history and loading state directly. The
        /// navigation delegate hears none of a site's own routing — a Substack
        /// link to another of its posts is a `pushState` — so Back stayed
        /// disabled, or left the source, on a page it could have gone back
        /// from. Nor does it hear the end of a return from the back/forward
        /// cache, which fails as cancelled rather than finishing, and left the
        /// toolbar's spinner turning over an article that had long arrived.
        func observeLocation(of webView: WKWebView) {
            stopObservingLocation()
            // Published a turn later, as the delegate callbacks publish: a
            // change can land in the middle of a SwiftUI update.
            let locationChanged: (WKWebView) -> Void = { [weak self] webView in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateReaderLocation(for: webView)
                    self.publishArticleReturn(for: webView)
                }
            }
            let loadingChanged: (WKWebView) -> Void = { [weak self] webView in
                DispatchQueue.main.async {
                    guard let self, !webView.isLoading else { return }
                    self.parent.isLoading = false
                    self.parent.chromeState?.setLoading(false, from: webView)
                }
            }
            locationObservations = [
                webView.observe(\.url, options: [.new]) { webView, _ in locationChanged(webView) },
                webView.observe(\.canGoBack, options: [.new]) { webView, _ in locationChanged(webView) },
                webView.observe(\.canGoForward, options: [.new]) { webView, _ in locationChanged(webView) },
                webView.observe(\.isLoading, options: [.new]) { webView, _ in loadingChanged(webView) },
            ]
        }

        func stopObservingLocation() {
            locationObservations.forEach { $0.invalidate() }
            locationObservations = []
        }

        /// Offer "Back to article" exactly while the page on screen is not the
        /// source's own.
        @MainActor
        private func publishArticleReturn(for webView: WKWebView) {
            guard let articleReturn = parent.articleReturn else { return }
            let isAway = initialPageURL != nil && !isSourceOwnPage(webView.url)
            articleReturn.update(isAwayFromArticle: isAway) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.returnToArticle(in: webView)
            }
        }

        /// "Back to article": straight to the article's history entry, however
        /// many pages back it is. Arriving there is a return like any other, so
        /// the article comes back where it was left
        /// (`restoreScrollAfterReturnIfNeeded`).
        @MainActor
        func returnToArticle(in webView: WKWebView) {
            let history = webView.backForwardList
            if let entry = ArticleReaderReturnState.articleEntry(
                back: history.backList,
                forward: history.forwardList,
                isArticle: { self.isSourceOwnPage($0.url) }
            ) {
                webView.stopLoading()
                webView.go(to: entry)
                return
            }
            // History no longer holds it. Loading it again restores the offset
            // the same way, since the article was left (`hasLeftArticlePage`).
            guard let initialPageURL else { return }
            webView.load(URLRequest(url: initialPageURL))
        }

        /// Attempt to load the cached HTML file as an offline fallback.
        /// Returns true if fallback was triggered, false if unavailable.
        private func attemptCachedFallback(in webView: WKWebView) -> Bool {
            guard !didFallBackToCache, let path = parent.cachedHTMLPath else { return false }
            let fileURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
            didFallBackToCache = true
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            return true
        }

        /// Arms the stall fallback when the article's own page starts loading.
        /// Later navigations are the learner browsing; a slow external page must
        /// not get replaced by the archived article.
        private func scheduleInitialLoadStallFallbackIfNeeded(in webView: WKWebView) {
            guard initialPageURL == nil,
                  initialLoadStallFallbackTask == nil,
                  !didFallBackToCache,
                  parent.cachedHTMLPath != nil else { return }
            let delay = initialLoadStallFallbackSeconds
            initialLoadStallFallbackTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled,
                      let self, let webView,
                      !self.hasCommittedNavigation,
                      self.initialPageURL == nil,
                      self.attemptCachedFallback(in: webView) else { return }
                self.parent.vm.showToast("Slow connection — showing the saved copy")
            }
        }

        private func cancelInitialLoadStallFallback() {
            initialLoadStallFallbackTask?.cancel()
            initialLoadStallFallbackTask = nil
        }

        /// A page that WebKit finishes but cannot be read is a load failure the
        /// navigation delegate never hears about.
        ///
        /// WebKit paints its own document for a Screen Time restriction — the
        /// "Website Not Allowed" card — and a site can answer a permalink with
        /// a sign-in wall or an empty shell. All three finish the navigation
        /// successfully, so `didFail` never runs and the archive fallback the
        /// source already owns never gets its chance. Measure what the finished
        /// page actually painted instead, once, on the source's own first load.
        /// WebKit exposes Screen Time directly on current macOS; the small text
        /// measurement is reserved for empty shells and X's known login shell.
        private var hasCheckedLivePageReadability = false

        private static let unreadableXPageThreshold = 120

        private static let readableLengthJS =
            "(document.body ? (document.body.innerText || '').trim().length : 0)"

        /// Sign-in walls announce themselves in the URL, so a redirect into one
        /// is a fallback trigger without waiting to measure the page.
        private static func isSignInWallURL(_ url: URL?) -> Bool {
            guard let url else { return false }
            let path = url.path.lowercased()
            return path.hasPrefix("/i/flow/login")
                || path == "/login"
                || path.hasPrefix("/login/")
                || path.hasPrefix("/account/login")
        }

        private func fallBackIfLivePageIsUnreadable(in webView: WKWebView) {
            guard !didFallBackToCache,
                  !hasCheckedLivePageReadability,
                  parent.cachedHTMLPath != nil,
                  webView.url?.isFileURL != true else { return }
            hasCheckedLivePageReadability = true

            let landedOnSignInWall = Self.isSignInWallURL(webView.url)
            let blockedByScreenTime: Bool
            if #available(macOS 26.0, *) {
                blockedByScreenTime = webView.isBlockedByScreenTime
            } else {
                blockedByScreenTime = false
            }
            let isXPost = XPostThreadService.postID(from: parent.urlString) != nil
            Task { @MainActor [weak self, weak webView] in
                if !landedOnSignInWall && !blockedByScreenTime {
                    // Client-rendered pages fill in after the load event; give
                    // them a moment before calling the page empty.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
                guard let self, let webView, !self.didFallBackToCache else { return }
                if !landedOnSignInWall && !blockedByScreenTime {
                    let measured = try? await webView.evaluateJavaScript(Self.readableLengthJS)
                    guard let length = (measured as? NSNumber)?.intValue else { return }
                    let threshold = isXPost ? Self.unreadableXPageThreshold : 1
                    guard length < threshold else { return }
                }
                guard self.attemptCachedFallback(in: webView) else { return }
                let message: String
                if blockedByScreenTime {
                    message = "Screen Time blocked this page — showing the saved copy"
                } else if landedOnSignInWall {
                    message = "That page wants a sign-in — showing the saved copy"
                } else {
                    message = "Couldn’t load the live page — showing the saved copy"
                }
                self.parent.vm.showToast(message)
            }
        }

        /// A source whose fetch was blocked, or never ran, and whose page is now
        /// on screen has its content in this web view and nowhere else. Hand
        /// the finished document to the view model, which archives it the way
        /// the fetch would have.
        ///
        /// Runs for the source's own page only, not for pages the learner
        /// browses to from it, and not for the archived copy. It runs on every
        /// finished load of that page rather than once: a publisher bot check
        /// finishes a navigation of its own before the article does, and the
        /// view model turns that snapshot down, so the article's load has to
        /// get its turn too.
        private var renderedPageCaptureTask: Task<Void, Never>?

        static let renderedPageSnapshotJS = """
        (function() {
            return {
                html: document.documentElement ? document.documentElement.outerHTML : '',
                title: document.title || '',
                text: document.body ? (document.body.innerText || '') : ''
            };
        })()
        """

        private func saveRenderedPageIfSourceLacksContent(in webView: WKWebView) {
            guard webView.url?.isFileURL != true,
                  isSourceOwnPage(webView.url) else { return }
            renderedPageCaptureTask?.cancel()
            let articleId = parent.articleId
            let vm = parent.vm
            let pageURL = webView.url
            renderedPageCaptureTask = Task { @MainActor [weak webView] in
                // Client-rendered pages fill in after the load event, the same
                // grace the readability check gives them.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Opening a source without content also starts a fetch, and
                // that fetch is usually still waiting on the publisher when
                // this page finishes. Let it answer first: if it succeeds the
                // page is not needed, and if it is blocked the page is the
                // only copy there is.
                var waitedSeconds = 0
                while !Task.isCancelled, waitedSeconds < 90, vm.sourceFetchIsInFlight(articleId) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waitedSeconds += 1
                }
                guard !Task.isCancelled,
                      let webView,
                      webView.url?.isFileURL != true,
                      Self.isSamePage(webView.url, pageURL),
                      vm.readerPageCanSupplySourceContent(articleId) else { return }
                guard let page = await Self.renderedPageSnapshot(of: webView) else { return }
                // Papers are never taken from a page here: a paper is a PDF,
                // and the learner asks for the page with Save Paper from Page.
                await vm.adoptRenderedReaderPage(
                    articleId: articleId,
                    html: page.html,
                    pageTitle: page.title,
                    visibleText: page.text
                )
            }
        }

        /// The document the web view holds, as the reader sees it. Nil when
        /// the page has no markup to hand over.
        static func renderedPageSnapshot(of webView: WKWebView) async -> (html: String, title: String?, text: String)? {
            let snapshot = try? await webView.evaluateJavaScript(renderedPageSnapshotJS)
            guard let page = snapshot as? [String: Any],
                  let html = page["html"] as? String,
                  !html.isEmpty else { return nil }
            return (html, page["title"] as? String, page["text"] as? String ?? "")
        }

        /// The document's `<head>` as rendered — where a publisher or index
        /// page declares which paper it is (`citation_doi`, `dc.identifier`).
        /// Only the head: the body is not needed to answer identity, and a
        /// full-page snapshot of a long article is work this check must not
        /// cost on every load.
        static func renderedPageHead(of webView: WKWebView) async -> String? {
            let snapshot = try? await webView.evaluateJavaScript(
                "(function(){ return document.head ? document.head.outerHTML : ''; })()"
            )
            guard let head = snapshot as? String, !head.isEmpty else { return nil }
            return head
        }

        /// Tells the view model which paper the page in `webView` says it is,
        /// under the page's own address and — on the source's first load,
        /// before any in-page navigation — the address the reader was asked
        /// for, which a redirect may have replaced. What flips the toolbar
        /// over a PubMed page to View in Sources when the library holds the
        /// paper under its publisher's address.
        private func notePageDeclaredIdentity(in webView: WKWebView, includingRequestedPage: Bool) {
            guard let pageURL = webView.url, !pageURL.isFileURL else { return }
            var pageURLs = [pageURL]
            if includingRequestedPage, let requested = URL(string: parent.urlString),
               requested.absoluteString != pageURL.absoluteString {
                pageURLs.append(requested)
            }
            let vm = parent.vm
            Task { @MainActor [weak webView] in
                guard let webView, Self.isSamePage(webView.url, pageURL),
                      let head = await Self.renderedPageHead(of: webView) else { return }
                await vm.notePageDeclaredIdentity(pageURLs: pageURLs, headHTML: head)
            }
        }

        func refreshZoomPasscodeIfNeeded(in webView: WKWebView, revision: Int) {
            guard revision != lastZoomPasscodeRevision else { return }
            lastZoomPasscodeRevision = revision
            autofillZoomPasscode(in: webView)
        }

        private func autofillZoomPasscode(in webView: WKWebView) {
            guard ZoomRecordingService.isZoomRecordingURL(parent.urlString),
                  let currentURL = webView.url,
                  ZoomRecordingService.isZoomRecordingURL(currentURL.absoluteString) else {
                return
            }

            zoomPasscodeRequest &+= 1
            let request = zoomPasscodeRequest
            let sourceID = parent.articleId
            Task { @MainActor [weak self, weak webView] in
                let passcode = await Task.detached(priority: .userInitiated) {
                    KeychainService.zoomRecordingPasscode(forSourceID: sourceID)
                }.value
                guard let self,
                      let webView,
                      request == self.zoomPasscodeRequest,
                      let passcode,
                      !passcode.isEmpty else {
                    return
                }
                _ = try? await webView.evaluateJavaScript(
                    WebViewReader.zoomPasscodeAutofillScript(passcode: passcode)
                )
            }
        }

        private func updateReaderLocation(for webView: WKWebView, currentURL: URL? = nil) {
            let url = currentURL ?? webView.url
            DispatchQueue.main.async {
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                self.parent.currentDomain = url?.host ?? ""
                if let url, Self.canOpenExternally(url) {
                    self.parent.currentURL = url
                }
            }
            Task { @MainActor in
                self.parent.chromeState?.updateNavigationState(from: webView, currentURL: url)
            }
        }

        private static func canOpenExternally(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        private static func shouldOpenWithSystem(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme)
        }

        // MARK: Link context menu

        /// URLs the learner explicitly asked to open from the link context menu,
        /// exempt from the publisher-PDF interception below until the navigation
        /// resolves.
        private var explicitlyOpenedURLs = Set<String>()
        /// "Download Linked File" saves to disk rather than attaching to the
        /// source, so it runs through its own delegate.
        private lazy var linkDownloader = ReaderLinkDownloader { [weak self] message in
            guard let vm = self?.parent.vm else { return }
            Task { @MainActor in vm.showToast(message) }
        }

        /// "Open Link". Publisher PDF links are normally intercepted and attached
        /// to the source in the background; an explicit open shows the page
        /// instead, which is the only outcome that reads as the menu working.
        func openLinkFromContextMenu(_ url: URL, in webView: WKWebView) {
            explicitlyOpenedURLs.insert(url.absoluteString)
            webView.load(URLRequest(url: url))
        }

        /// "Open Link in New Tab", and a Command-click: the page opens in a
        /// Browser tab behind the reader, the way a browser opens a background
        /// tab, so the learner can collect several links and keep reading.
        @MainActor
        func openLinkInNewTab(_ url: URL) {
            let vm = parent.vm
            let window = vm.activeWindowState
            let workspace = BrowserWorkspace.forWindow(window.id)
            let tab = workspace.openTab(url: url, activate: workspace.tabs.isEmpty)
            // Start loading now, so the page is there when the tab is opened.
            _ = workspace.webView(for: tab)
            vm.showToast(
                "Opened \(tab.displayTitle) in a new Browser tab",
                action: StudioToastAction(title: "Show") { destination in
                    let target = destination ?? window
                    BrowserWorkspace.forWindow(target.id).select(tab)
                    vm.activateCenterTab(.browser, in: target)
                }
            )
        }

        /// "Download Linked File".
        func downloadLinkedFile(at url: URL, in webView: WKWebView) {
            linkDownloader.start(url, in: webView)
        }

        // MARK: WKUIDelegate

        /// Handle target="_blank", form-target, and user-initiated window.open()
        /// navigations in the existing reader. Loading the original request is
        /// important: rebuilding it from only the URL drops its method, body,
        /// referrer, and site-provided headers, which breaks publisher handoffs.
        /// The resulting main-frame navigation returns through the normal policy
        /// delegates below, including download handling.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            if navigationAction.navigationType == .linkActivated,
               navigationAction.modifierFlags.contains(.command),
               let url = navigationAction.request.url,
               Self.canOpenExternally(url) {
                Task { @MainActor in self.openLinkInNewTab(url) }
                return nil
            }
            if let url = navigationAction.request.url,
               Self.shouldOpenWithSystem(url) {
                if navigationAction.navigationType == .linkActivated {
                    _ = NSWorkspace.shared.open(url)
                }
                return nil
            }
            if navigationAction.shouldPerformDownload {
                pageDownloads.start(navigationAction.request, in: webView, returnItem: clickOriginItem)
                return nil
            }
            if let url = navigationAction.request.url,
               Self.canOpenExternally(url) {
                updateReaderLocation(for: webView, currentURL: url)
            }
            // A new-window link loads here, so it is the learner's click the
            // reader returns from once a PDF it leads to has attached.
            if navigationAction.navigationType == .linkActivated {
                clickOriginItem = webView.backForwardList.currentItem
            }
            webView.load(navigationAction.request)
            return nil
        }

        /// JavaScript panels and file inputs, answered as a Browser tab
        /// answers them (`WebPagePanels`).
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            WebPagePanels.alert(message, from: frame, in: webView, completion: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            WebPagePanels.confirm(message, from: frame, in: webView, completion: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            WebPagePanels.prompt(prompt, defaultText: defaultText, from: frame, in: webView, completion: completionHandler)
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            WebPagePanels.chooseFiles(parameters, completion: completionHandler)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the reader's own scripts reach this handler
            // (`WebViewReader.scriptWorld`), and only in the article's main
            // frame (`ScriptMessageSender`).
            guard message.isFrom(.web),
                  message.world.name == WebViewReader.scriptWorld.name,
                  message.name == WebViewReader.messageHandlerName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            if type == "selection" || type == "chatRequest", let text = body["text"] as? String {
                let images = ReaderSelectionImage.list(from: body["images"])
                DispatchQueue.main.async {
                    // Pictures first: the text binding's own change handler
                    // re-reports the words and keeps whatever pictures are
                    // stored here.
                    self.parent.vm.updateActiveReaderSelection(
                        sourceID: self.parent.articleId,
                        text: text,
                        images: images
                    )
                    self.parent.selectedText = text
                    if type == "chatRequest" {
                        self.parent.explainSelectionAction?()
                    }
                }
            }

            if type == "sideChatRequest",
               case .sideChatRequest(let text, let viewportRect)? = ReaderSelectionMessage(body: body) {
                let webView = message.webView
                DispatchQueue.main.async {
                    self.parent.vm.openReaderSideChat(
                        sourceID: self.parent.articleId,
                        passage: text,
                        markOnScreen: ReaderWebViewportRect.onScreen(viewportRect, in: webView),
                        windowNumber: webView?.window?.windowNumber
                    )
                }
            }

            if type == "contextLink" {
                ReaderContextLinkTracking.apply(message, fallbackBase: parent.urlString)
            }

            if type == "highlightRequest", let payload = ReaderWebSelectionAnchor(payload: body) {
                let webView = message.webView
                Task { @MainActor in
                    await self.parent.vm.highlightReaderSelection(
                        sourceID: self.parent.articleId,
                        quote: payload.text,
                        anchor: payload.anchor,
                        pdfAnchor: nil,
                        imageAnchors: payload.imageAnchors,
                        markOnScreen: ReaderWebViewportRect.onScreen(payload.viewportRect, in: webView)
                    )
                }
            }

            if type == "openNote", let highlightID = body["highlightId"] as? String {
                let webView = message.webView
                let viewportRect = ReaderWebViewportRect.parse(body["rect"])
                DispatchQueue.main.async {
                    self.parent.vm.openReaderHighlight(
                        highlightID: highlightID,
                        sourceID: self.parent.articleId,
                        markOnScreen: ReaderWebViewportRect.onScreen(viewportRect, in: webView)
                    )
                }
            }

            if type == "pageRestored", let webView = message.webView {
                // Back brought the page out of the back/forward cache, which
                // finishes no load (`ArticleScrollTracking`). Queued behind the
                // scroll reports already on their way, so the offset put back
                // is the last one the page sent before it was left.
                DispatchQueue.main.async { [weak webView] in
                    guard let webView else { return }
                    self.restoreScrollAfterReturnIfNeeded(in: webView)
                    self.publishArticleReturn(for: webView)
                }
            }

            if type == "scrollPosition", let fraction = (body["fraction"] as? NSNumber)?.doubleValue {
                // Only positions on the article's own page count as reading
                // progress; scrolling an external page reached through the
                // article's links must not overwrite the saved position.
                // The page names itself: its last report is sent as it unloads,
                // when the web view's URL is already the page replacing it.
                let pageURL = (body["href"] as? String).flatMap(URL.init(string:)) ?? message.webView?.url
                let offset = (body["offset"] as? NSNumber)?.doubleValue
                let reachedArticleEnd = (body["reachedArticleEnd"] as? NSNumber)?.boolValue ?? false
                let userInitiated = (body["userInitiated"] as? NSNumber)?.boolValue ?? false
                DispatchQueue.main.async {
                    if let offset, offset.isFinite, let key = Self.historyKey(pageURL) {
                        self.pageScrollOffsets[key] = offset
                    }
                    guard self.initialPageURL == nil || Self.isSamePage(pageURL, self.initialPageURL) else { return }
                    if let offset, offset.isFinite {
                        self.lastArticleScrollOffset = offset
                    }
                    self.parent.scrollFractionChanged(fraction)
                    if reachedArticleEnd && userInitiated {
                        self.parent.readingCompletionReached()
                    }
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            scheduleInitialLoadStallFallbackIfNeeded(in: webView)
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadError = nil
            }
            Task { @MainActor in
                self.parent.chromeState?.setLoading(true, from: webView)
                self.parent.chromeState?.updateNavigationState(from: webView)
            }
        }

        /// First bytes of the document arrived and rendering can begin, so the
        /// live page won the race against the stall fallback.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            hasCommittedNavigation = true
            cancelInitialLoadStallFallback()
            // The article's page is being replaced. Noted here rather than at
            // `didFinish`, because Back can be pressed before the linked page
            // has finished loading, and the article still has to come back to
            // where it was.
            if let initialPageURL, !Self.isSamePage(webView.url, initialPageURL) {
                hasLeftArticlePage = true
            }
            // A history entry this reader has shown before is a return to it,
            // whichever way WebKit got there.
            if let item = webView.backForwardList.currentItem {
                if visitedHistoryItems.contains(where: { $0 === item }) {
                    isReturningThroughHistory = true
                } else {
                    visitedHistoryItems.append(item)
                }
            }
            // A new document is a new `window`: the setting has to be handed to
            // it again, and early enough that a light page is inverted before it
            // has finished painting.
            ReaderDarkMode.push(parent.darkensPage, to: webView)
        }

        private weak var readingViewWebView: WKWebView?
        private var readingViewObserver: NSObjectProtocol?

        /// Dress the page in the learner's reading version of this article, and
        /// keep it current while the Reader stays open: making, switching or
        /// removing the view posts a notification for this source.
        private func applyReadingView(to webView: WKWebView) {
            readingViewWebView = webView
            ReaderReadingView.push(ArticleReadingViewStore.load(sourceID: parent.articleId), to: webView)
            guard readingViewObserver == nil else { return }
            let articleID = parent.articleId
            readingViewObserver = NotificationCenter.default.addObserver(
                forName: .articleReadingViewChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard note.userInfo?["sourceID"] as? String == articleID,
                      let webView = self?.readingViewWebView else { return }
                ReaderReadingView.push(ArticleReadingViewStore.load(sourceID: articleID), to: webView)
            }
        }

        deinit {
            if let readingViewObserver { NotificationCenter.default.removeObserver(readingViewObserver) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            cancelInitialLoadStallFallback()
            ReaderDarkMode.push(parent.darkensPage, to: webView)
            applyReadingView(to: webView)
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            updateReaderLocation(for: webView)
            // The exemption covers one navigation; a page that finished loading
            // has no further claim on it.
            explicitlyOpenedURLs.removeAll()
            startAttachmentDownloadIfDisplayingPDF(in: webView)
            // Before `restoreInitialScrollIfNeeded` claims `initialPageURL`,
            // while this is still known to be the source's own page.
            if initialPageURL == nil {
                fallBackIfLivePageIsUnreadable(in: webView)
            }
            notePageDeclaredIdentity(in: webView, includingRequestedPage: initialPageURL == nil)
            saveRenderedPageIfSourceLacksContent(in: webView)
            restoreInitialScrollIfNeeded(in: webView)
            restoreScrollAfterReturnIfNeeded(in: webView)
            publishArticleReturn(for: webView)
            autofillZoomPasscode(in: webView)
            // A fresh document holds none of the previous page's marks, so the
            // next update has to repaint even if the note set is unchanged.
            appliedHighlightFingerprint = []
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                self.applyHighlightsIfNeeded(
                    self.parent.vm.highlights(for: self.parent.articleId),
                    to: webView
                )
                self.applyPassageTargetIfNeeded(to: webView)
            }
            Task { @MainActor in
                self.parent.chromeState?.setLoading(false, from: webView)
            }
        }

        /// What the page currently has painted, so an unrelated SwiftUI update
        /// does not re-run the anchoring pass over the whole document.
        private var appliedHighlightFingerprint: [String] = []

        /// Which citation passage this reader has already flashed.
        let passageTracker = ReaderPassageTargetTracker()

        /// A chat citation asked for a passage of this article: once its page
        /// has settled, scroll to the passage and flash it.
        @MainActor
        func applyPassageTargetIfNeeded(to webView: WKWebView) {
            guard hasSettledPage, !webView.isLoading else { return }
            // The live page did not carry the passage, so the saved copy was
            // put up in its place; it is that copy's turn to show it.
            if let passage = passageAwaitingSavedCopy, webView.url?.isFileURL == true {
                passageAwaitingSavedCopy = nil
                flashPassage(passage, in: webView)
                return
            }
            guard let target = passageTracker.pending(for: parent.articleId, in: parent.vm) else { return }
            passageTracker.finish(target, in: parent.vm)
            // A page names nothing on a web page; only the words can be found.
            guard let passage = target.passage else { return }
            flashPassage(passage, in: webView)
        }

        /// The passage a live page could not show, held until the saved copy
        /// has loaded.
        private var passageAwaitingSavedCopy: String?

        /// Marks `passage` once the page has settled. A live page that does
        /// not carry it — a paywall or a metered cut-off hides the paragraphs
        /// a card or citation stands on, though the saved copy has them — is
        /// swapped for the saved copy, which then shows it.
        private func flashPassage(_ passage: String, in webView: WKWebView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + ReaderPassageFlash.webSettleDelay) { [weak self, weak webView] in
                guard let webView else { return }
                ReaderPassageFlash.flash(passage, in: webView, world: WebViewReader.scriptWorld) { found in
                    Task { @MainActor [weak webView] in
                        guard !found, let self, let webView, webView.url?.isFileURL != true,
                              self.attemptCachedFallback(in: webView) else { return }
                        self.passageAwaitingSavedCopy = passage
                        self.parent.vm.showToast("The live page doesn’t show that passage — showing the saved copy")
                    }
                }
            }
        }

        @MainActor
        func applyHighlightsIfNeeded(_ highlights: [SourceHighlight], to webView: WKWebView) {
            let fingerprint = highlights.map { "\($0.id)|\($0.color.rawValue)|\($0.updatedAt.timeIntervalSince1970)" }
            guard fingerprint != appliedHighlightFingerprint else { return }
            appliedHighlightFingerprint = fingerprint
            ReaderWebHighlightSupport.apply(highlights, to: webView, world: WebViewReader.scriptWorld)
        }

        /// The first page this reader finished loading — the article itself
        /// (live, after redirects settle, or the cached-HTML fallback). Scroll
        /// persistence and restore are scoped to this page.
        private var initialPageURL: URL?

        /// Where the learner last was on the article's own page, in pixels,
        /// from the page's scroll reports (the last of which is sent as the page
        /// unloads). A pixel offset, not the saved fraction: the fraction is
        /// measured against a document height that changes as a page fills in,
        /// and only the offset puts the same line back under the eye.
        private var lastArticleScrollOffset: Double?

        /// Set when a navigation replaces the article's page; consumed by the
        /// navigation that brings the article back.
        private var hasLeftArticlePage = false

        /// Where the learner last was on every page shown in this reader, the
        /// article and the pages its links led to, keyed by `historyKey`. Back
        /// puts each one back where it was left, not only the article.
        private var pageScrollOffsets: [String: Double] = [:]

        /// Set when the navigation under way returns to a history entry — Back,
        /// Forward — rather than following a link; consumed when it finishes.
        private var isReturningThroughHistory = false
        /// Held, not merely identified, so a freed item's address cannot be
        /// mistaken for a new page's.
        private var visitedHistoryItems: [WKBackForwardListItem] = []

        /// A page's identity for its remembered scroll offset: the document,
        /// without the fragment an in-page jump adds.
        static func historyKey(_ url: URL?) -> String? {
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.url?.absoluteString
        }

        /// Same document modulo fragment, so in-page anchor jumps still count
        /// as the article page.
        /// Whether this URL is the source's own page rather than somewhere the
        /// learner browsed to.
        ///
        /// The page the reader first finished is compared exactly. The source's
        /// own URL is also matched when the only difference is query the
        /// publisher added, because a sign-in round trip returns to the article
        /// carrying one; that is only safe when the source's URL has no query
        /// of its own, since a query is what identifies the document on sites
        /// that address papers as `?id=…`.
        private func isSourceOwnPage(_ url: URL?) -> Bool {
            if initialPageURL == nil { return true }
            if Self.isSamePage(url, initialPageURL) { return true }
            return ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
                url,
                sourceURL: URL(string: parent.urlString)
            )
        }

        private static func isSamePage(_ lhs: URL?, _ rhs: URL?) -> Bool {
            guard let lhs, let rhs else { return false }
            if lhs == rhs { return true }
            var lhsParts = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
            var rhsParts = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
            lhsParts?.fragment = nil
            rhsParts?.fragment = nil
            return lhsParts?.url == rhsParts?.url
        }

        /// Scroll to the saved reading position once the article's own page has
        /// loaded. Runs only for the first finished navigation: later ones are
        /// link clicks or back/forward moves that manage their own scroll.
        private func restoreInitialScrollIfNeeded(in webView: WKWebView) {
            guard initialPageURL == nil else { return }
            initialPageURL = webView.url
            guard let fraction = parent.initialScrollFraction, fraction > 0 else { return }
            let clamped = min(max(fraction, 0), 1)
            let js = """
            setTimeout(function() {
                var doc = document.documentElement;
                var body = document.body;
                var height = Math.max(
                    doc ? doc.scrollHeight : 0,
                    body ? body.scrollHeight : 0
                );
                var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
                var maxScroll = Math.max(0, height - viewport);
                window.scrollTo(0, maxScroll * \(clamped));
            }, 80);
            """
            webView.evaluateJavaScript(js)
        }

        /// Put a page back where the learner left it when a navigation returns
        /// to it — Back after following a link, most of all. The article's own
        /// offset is kept apart from the rest, because it survives a return that
        /// is not a history move (a publisher's sign-in round trip).
        ///
        /// WebKit restores a history entry's scroll position itself, but only
        /// when it can: a page that was not kept in the back/forward cache is
        /// reloaded, the restored offset is clamped to however much of the
        /// document exists at load completion, and WebKit does not try again
        /// when the rest arrives — which for a page that renders its body late
        /// leaves the reader at the top. The page's last reported offset is
        /// known regardless, so the page is scrolled there as soon as it is tall
        /// enough to reach it, watching the document grow for a few seconds. A
        /// wheel, touch, click or key from the learner ends the wait: someone
        /// who has started reading again is never yanked away.
        private func restoreScrollAfterReturnIfNeeded(in webView: WKWebView) {
            let isReturning = isReturningThroughHistory
            isReturningThroughHistory = false
            if hasLeftArticlePage, Self.isSamePage(webView.url, initialPageURL) {
                hasLeftArticlePage = false
                if let offset = lastArticleScrollOffset {
                    scrollBack(to: offset, in: webView)
                }
                return
            }
            guard isReturning, let key = Self.historyKey(webView.url),
                  let offset = pageScrollOffsets[key] else { return }
            scrollBack(to: offset, in: webView)
        }

        private func scrollBack(to offset: Double, in webView: WKWebView) {
            guard offset.isFinite, offset > 0 else { return }
            let js = """
            (function() {
                var offset = \(offset);
                var deadline = Date.now() + 6000;
                var finished = false;
                var observer = null;
                var timer = null;
                var userEvents = ['wheel', 'touchstart', 'mousedown', 'keydown'];
                function maxScroll() {
                    var doc = document.documentElement;
                    var body = document.body;
                    var height = Math.max(
                        doc ? doc.scrollHeight : 0,
                        body ? body.scrollHeight : 0
                    );
                    var viewport = window.innerHeight || (doc ? doc.clientHeight : 0) || 0;
                    return Math.max(0, height - viewport);
                }
                function stop() {
                    finished = true;
                    if (observer) { observer.disconnect(); observer = null; }
                    if (timer) { clearInterval(timer); timer = null; }
                    userEvents.forEach(function(name) {
                        window.removeEventListener(name, stop, { capture: true });
                    });
                }
                function attempt() {
                    if (finished) { return; }
                    var reachable = maxScroll();
                    if (reachable + 2 < offset && Date.now() < deadline) { return; }
                    var target = Math.min(offset, reachable);
                    var y = window.scrollY || window.pageYOffset || 0;
                    if (Math.abs(y - target) > 2) { window.scrollTo(0, target); }
                    stop();
                }
                userEvents.forEach(function(name) {
                    window.addEventListener(name, stop, { capture: true, passive: true });
                });
                attempt();
                if (finished) { return; }
                if (window.ResizeObserver && document.documentElement) {
                    observer = new ResizeObserver(attempt);
                    observer.observe(document.documentElement);
                }
                timer = setInterval(attempt, 250);
            })();
            """
            webView.evaluateJavaScript(js)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            cancelInitialLoadStallFallback()
            // When a navigation is converted to a download (.download policy), WebKit cancels
            // the original navigation. Ignore these cancellation errors — the download is
            // proceeding via WKDownloadDelegate. A publisher's Download PDF link reports the
            // cancellation as WebKitErrorDomain 102, "Frame load interrupted"; taking that for
            // a failure replaced the paper's page with the load-failure screen while the PDF
            // was downloading behind it.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
            if attemptCachedFallback(in: webView) { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                self.parent.loadError = error.localizedDescription
            }
            Task { @MainActor in
                self.parent.chromeState?.updateNavigationState(from: webView)
                self.parent.chromeState?.setLoading(false, from: webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            cancelInitialLoadStallFallback()
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
            if attemptCachedFallback(in: webView) { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = error.localizedDescription
            }
            Task { @MainActor in
                self.parent.chromeState?.updateNavigationState(from: webView)
                self.parent.chromeState?.setLoading(false, from: webView)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let isLinkActivated = navigationAction.navigationType == .linkActivated

            // Command-click opens the link in a new tab, as in a browser.
            if isLinkActivated,
               navigationAction.modifierFlags.contains(.command),
               let url = navigationAction.request.url,
               Self.canOpenExternally(url) {
                decisionHandler(.cancel, preferences)
                Task { @MainActor in self.openLinkInNewTab(url) }
                return
            }

            // Returning through history: put that page back where it was left.
            if isMainFrame {
                isReturningThroughHistory = navigationAction.navigationType == .backForward
            }

            // The page the learner was reading when they clicked, so a PDF the
            // click ends on — past whatever pages the site shows first — can
            // hand the reader back to it. Only the learner's own click counts: a
            // challenge page's reload is not where anyone was reading.
            if isMainFrame,
               isLinkActivated || navigationAction.navigationType == .formSubmitted {
                clickOriginItem = webView.backForwardList.currentItem
            }

            switch WebPagePolicy.action(
                for: navigationAction.request.url,
                isLinkActivated: isLinkActivated,
                isMainFrame: isMainFrame,
                shouldPerformDownload: navigationAction.shouldPerformDownload
            ) {
            case .openInOtherApp:
                // Safari hands mailto:, tel:, App Store, and other registered
                // URL schemes to macOS.
                if let url = navigationAction.request.url { _ = NSWorkspace.shared.open(url) }
                decisionHandler(.cancel, preferences)
            case .cancel:
                decisionHandler(.cancel, preferences)
            case .download:
                // A link with the HTML `download` attribute. Navigating to it
                // would fail with "Page Load Failed".
                decisionHandler(.download, preferences)
            case .openYouTubeVideo(let watchURL):
                decisionHandler(.cancel, preferences)
                Task { @MainActor in WebPagePolicy.openYouTubeVideo(watchURL) }
            case .refuseYouTubePage:
                decisionHandler(.cancel, preferences)
                Task { @MainActor in WebPagePolicy.refuseYouTubePage() }
            case .allow:
                if isMainFrame,
                   let url = navigationAction.request.url,
                   Self.canOpenExternally(url) {
                    updateReaderLocation(for: webView, currentURL: url)
                }
                decisionHandler(.allow, preferences)
            }
        }

        /// The response decides, as in the Browser (`WebPagePolicy`): a page is
        /// shown, a PDF is the paper's and attaches when the source is a paper
        /// (from any other source it is shown like a page), and any other file
        /// goes to Downloads.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // A publisher's Cloudflare check never clears under the Safari
            // user agent; the page is asked for again under WebKit's own.
            if SharedWebKit.retryCloudflareChallengeWithWebKitUserAgent(navigationResponse, in: webView) {
                decisionHandler(.cancel)
                return
            }
            let response = navigationResponse.response
            if navigationResponse.isForMainFrame {
                mainFrameMIMEType = response.mimeType?.lowercased()
            }
            // An explicitly opened link renders in place when WebKit can show it
            // — PDFs included — instead of becoming a silent attachment.
            if let url = response.url,
               explicitlyOpenedURLs.remove(url.absoluteString) != nil,
               navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
                return
            }

            // A page that already came back as a download once is shown as
            // that page; only a PDF from it downloads.
            if let url = response.url,
               pageDownloads.wasShownInsteadOfDownloaded(url),
               navigationResponse.canShowMIMEType,
               !WebPagePolicy.isPDF(url: url, mimeType: response.mimeType?.lowercased() ?? "", contentDisposition: "") {
                decisionHandler(.allow)
                return
            }

            switch WebPagePolicy.response(
                url: response.url,
                mimeType: response.mimeType,
                contentDisposition: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
                canShowMIMEType: navigationResponse.canShowMIMEType,
                capturesPDFs: paperReceivingPDFs != nil
            ) {
            case .show:
                decisionHandler(.allow)
            case .download:
                pageDownloads.expectResponseDownload(.file)
                decisionHandler(.download)
            case .capturePDF:
                pageDownloads.expectResponseDownload(.paperPDF)
                decisionHandler(.download)
            }
        }

        /// Called when a navigation action becomes a download (e.g. blob: URL, or .download policy from action).
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            pageDownloads.track(actionDownload: download, returnItem: clickOriginItem)
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            Task { @MainActor in
                self.parent.chromeState?.updateNavigationState(from: webView)
                self.parent.chromeState?.setLoading(false, from: webView)
            }
        }

        /// Called when a navigation response becomes a download.
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            pageDownloads.track(responseDownload: download, returnItem: clickOriginItem)
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            Task { @MainActor in
                self.parent.chromeState?.updateNavigationState(from: webView)
                self.parent.chromeState?.setLoading(false, from: webView)
            }
        }

        // MARK: Downloads

        /// The source, while it is a paper or an article waiting for its
        /// document: the one that PDFs this page leads to attach to. Read at
        /// each use, since a source can become a paper, or readable, while its
        /// reader is open.
        private var paperReceivingPDFs: String? {
            let source = parent.vm.articles.first { $0.id == parent.articleId }
            return WebPagePolicy.readerPaperID(
                sourceID: parent.articleId,
                sourceType: source?.sourceType,
                isUnreadable: source.map { $0.hasPaywallMarker || $0.state == .error } ?? false
            )
        }

        /// Downloads run through the Browser's engine (`WebPageDownloads`),
        /// with every PDF this page leads to taken as the source's when the
        /// source is a paper, and kept in Downloads otherwise.
        private lazy var pageDownloads = WebPageDownloads(
            paperID: { [weak self] _ in self?.paperReceivingPDFs },
            library: { [weak self] in self?.parent.vm },
            notify: { [weak self] message in self?.parent.vm.showToast(message) }
        )
        private var clickOriginItem: WKBackForwardListItem?
        private var attachmentDownloadURLs = Set<String>()
        /// The MIME type of the document the main frame shows.
        private var mainFrameMIMEType: String?

        /// Starts a download in this page's session: the Download PDF button.
        func startDownload(_ request: URLRequest, in webView: WKWebView) {
            pageDownloads.start(request, in: webView)
        }

        /// A PDF a paper's reader is showing (an Open Link to one) is still the
        /// paper's: fetch it as a download so it attaches. Any other source
        /// just shows it.
        private func startAttachmentDownloadIfDisplayingPDF(in webView: WKWebView) {
            guard paperReceivingPDFs != nil,
                  let url = webView.url,
                  Self.canOpenExternally(url),
                  mainFrameMIMEType == "application/pdf" else {
                return
            }
            let key = url.absoluteString
            guard !attachmentDownloadURLs.contains(key) else { return }
            attachmentDownloadURLs.insert(key)
            pageDownloads.start(URLRequest(url: url), in: webView)
        }

        @MainActor
        func performFindIfNeeded(in webView: WKWebView, revision: Int, state: ReaderFindState) {
            guard revision > 0, revision != lastFindRevision else { return }
            lastFindRevision = revision
            // Called from updateNSView, inside the SwiftUI render pass — writing
            // selectedText/statusText here is "Modifying state during view update".
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                parent.selectedText = ""
                ReaderFindPerformer.performWebFind(
                    in: webView,
                    state: state,
                    query: state.query,
                    backwards: state.searchesBackward
                )
            }
        }

        private var lastFindRevision = 0
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
