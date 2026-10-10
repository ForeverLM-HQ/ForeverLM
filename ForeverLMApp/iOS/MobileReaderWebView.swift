import os
import SwiftUI
import UIKit
import WebKit

// The reader surface itself. The document is assembled locally by
// MobileReaderText — either escaped source text or a synced book chapter whose
// images are already inlined as `data:` URIs — so there is no remote content and
// no script in it but the reader's own, and this wrapper only has to do three
// things well: render, keep the reading position, and hand a selection to the chat.
//
// A whole book (`book`) is the one page that changes after it loads: chapters go
// in and out at either end as the reader scrolls (MobileBookReading.swift), and
// the page, not the scroll view, says where the reader is.

/// WKWebView subclass that extends the system edit menu. Adding the action to
/// the native callout is deliberate: a floating "ask about this" pill fights
/// WebKit's own selection UI and its handles.
final class MobileReaderWKWebView: WKWebView {
    /// Receives the raw `window.getSelection()` text, and on a book page the
    /// chapter it is in; the coordinator cleans the text.
    var onSelectionRequested: ((String, String?) -> Void)?
    var onHighlightSelectionRequested: (([String: Any]) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }

        let chatAction = UIAction(
            title: "Chat",
            image: UIImage(systemName: "text.bubble")
        ) { [weak self] _ in
            self?.requestSelection()
        }
        let highlightAction = UIAction(
            title: "Highlight",
            image: UIImage(systemName: "highlighter")
        ) { [weak self] _ in
            self?.requestHighlightSelection()
        }
        builder.insertChild(
            UIMenu(title: "", options: .displayInline, children: [highlightAction, chatAction]),
            atStartOfMenu: .root
        )
    }

    /// Read on demand rather than mirroring every selection change across the
    /// JS bridge: dragging a selection handle fires constantly, and the menu
    /// action is the only moment the text actually matters.
    private func requestSelection() {
        evaluateJavaScript(MobileReaderPageScript.selection) { [weak self] value, _ in
            guard let self, let value = value as? [String: Any], let raw = value["text"] as? String else { return }
            self.onSelectionRequested?(raw, value["chapter"] as? String)
        }
    }

    private func requestHighlightSelection() {
        evaluateJavaScript(MobileReaderPageScript.selectionAnchor) { [weak self] value, _ in
            guard let self, let value = value as? [String: Any] else { return }
            self.onHighlightSelectionRequested?(value)
        }
    }
}

struct MobileReaderHighlightSelection: Sendable {
    let quote: String
    let anchor: ReaderTextAnchor
    let pdfAnchor: ReaderPDFAnchor?
    /// On a book page, the chapter the selection is in: the highlight is that
    /// chapter's, and `anchor` is relative to its text.
    var chapterID: String? = nil
}

struct MobileReaderWebView: UIViewRepresentable {
    let html: String
    let initialScrollFraction: Double
    /// The reader's find bar, when it has one; this view is its performer
    /// while on screen. See `MobileReaderFind.swift`.
    var find: MobileReaderFindState? = nil
    let onScrollFractionChange: (Double) -> Void
    /// The selection, and on a book page the chapter it is in.
    let onAskAboutSelection: (MobileReaderSelection, String?) -> Void
    let highlights: [SourceHighlight]
    let onCreateHighlight: (MobileReaderHighlightSelection) -> Void
    let onOpenHighlight: (String) -> Void
    /// The whole book as one scroll; `html` is then its empty page
    /// (`MobileReaderText.bookDocumentHTML`) and the chapters go in from here.
    /// nil for a single source, which renders exactly as it always has.
    var book: MobileBookPage? = nil
    /// Where the reader is in the book, and a pressed Try Again.
    var onBookEvent: (MobileBookPageEvent) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialScrollFraction: initialScrollFraction,
            onScrollFractionChange: onScrollFractionChange,
            onAskAboutSelection: onAskAboutSelection,
            onCreateHighlight: onCreateHighlight,
            onOpenHighlight: onOpenHighlight,
            onBookEvent: onBookEvent
        )
    }

    func makeUIView(context: Context) -> MobileReaderWKWebView {
        let configuration = WKWebViewConfiguration()
        // Plain prose: phone numbers and addresses must not become tappable
        // links that hijack a long press meant to select text.
        configuration.dataDetectorTypes = []
        configuration.userContentController.add(context.coordinator, name: "foreverlmHighlight")
        // A publisher's delta or arrow drawn as a tiny picture stays in its
        // sentence instead of becoming a centered figure. Same script as the Mac.
        configuration.userContentController.addUserScript(WKUserScript(
            source: ReaderInlineGlyphScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        if book != nil {
            context.coordinator.isBook = true
            configuration.userContentController.add(context.coordinator, name: MobileBookPageScript.messageHandlerName)
            configuration.userContentController.addUserScript(WKUserScript(
                source: MobileBookPageScript.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        let webView = MobileReaderWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false

        let scrollView = webView.scrollView
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        // The reader stylesheet owns its margins through env(safe-area-inset-*);
        // letting UIKit adjust the content inset as well double-pads the text.
        scrollView.contentInsetAdjustmentBehavior = .never

        let coordinator = context.coordinator
        webView.onSelectionRequested = { [weak coordinator] raw, chapterID in
            coordinator?.handleSelection(raw, chapterID: chapterID)
        }
        webView.onHighlightSelectionRequested = { [weak coordinator] value in
            coordinator?.handleHighlightSelection(value)
        }
        coordinator.observeScrolling(of: webView)
        coordinator.findPerformer = MobileWebFindPerformer(webView: webView)

        return webView
    }

    func updateUIView(_ webView: MobileReaderWKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScrollFractionChange = onScrollFractionChange
        coordinator.onAskAboutSelection = onAskAboutSelection
        coordinator.onCreateHighlight = onCreateHighlight
        coordinator.onOpenHighlight = onOpenHighlight
        coordinator.onBookEvent = onBookEvent
        coordinator.apply(highlights: highlights, in: webView)

        // Not a published property, so installing it here invalidates nothing.
        if let find, let performer = coordinator.findPerformer, find.performer !== performer {
            find.performer = performer
        }

        if let book, coordinator.isBook {
            coordinator.book = book
            // The book page is built once per generation and then changed in
            // place; a text-size change is one of those changes, not a rebuild.
            guard coordinator.loadedHTML != html || coordinator.bookGeneration != book.generation else {
                coordinator.syncBook(in: webView)
                return
            }
            coordinator.loadedHTML = html
            coordinator.prepareBookLoad(generation: book.generation, restore: book.restore)
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        // A font-size change rebuilds the whole document, so hold the position
        // the reader is at rather than the one it opened with.
        coordinator.prepareForLoad()
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: MobileReaderWKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.onSelectionRequested = nil
        webView.onHighlightSelectionRequested = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "foreverlmHighlight")
        if coordinator.isBook {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: MobileBookPageScript.messageHandlerName
            )
        }
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onScrollFractionChange: (Double) -> Void
        var onAskAboutSelection: (MobileReaderSelection, String?) -> Void
        var onCreateHighlight: (MobileReaderHighlightSelection) -> Void
        var onOpenHighlight: (String) -> Void
        var onBookEvent: (MobileBookPageEvent) -> Void
        var loadedHTML: String?
        var findPerformer: MobileWebFindPerformer?
        private var highlightSignature = ""
        private var highlights: [SourceHighlight] = []

        private let initialScrollFraction: Double
        private var pendingScrollFraction: Double?
        private var hasRestoredPosition = false
        private var latestFraction: Double = 0
        private var isRestoringPosition = false
        private var lastReportedAt = Date.distantPast
        private var scrollObservation: NSKeyValueObservation?

        // The whole book, when this web view reads one.
        var isBook = false
        var book: MobileBookPage?
        private(set) var bookGeneration: Int?
        /// What the page holds, as of the last batch it finished.
        private var bookDOM = MobileBookDOMState.freshShell
        /// Counts page loads, so a batch finishing after a reload is ignored.
        private var bookLoadCount = 0
        private var isBookPageReady = false
        private var isBookBatchRunning = false
        private var needsBookSync = false
        private var isBookIdleCheckScheduled = false
        /// Where a freshly loaded page puts the reader once its chapter is in.
        private var pendingBookRestore: MobileBookReadingPoint?
        private var lastBookPoint: MobileBookReadingPoint?
        private weak var bookWebView: WKWebView?

        /// contentOffset changes every frame while scrolling; the view model
        /// debounces the write, but there is no reason to wake it 60 times a
        /// second to do it.
        private static let reportInterval: TimeInterval = 0.1
        private static let restoreRetryLimit = 8
        private static let restoreRetryDelay: TimeInterval = 0.08
        /// How soon a held-back book change looks again for the scroll to rest.
        private static let bookIdleRecheckDelay: TimeInterval = 0.15

        init(
            initialScrollFraction: Double,
            onScrollFractionChange: @escaping (Double) -> Void,
            onAskAboutSelection: @escaping (MobileReaderSelection, String?) -> Void,
            onCreateHighlight: @escaping (MobileReaderHighlightSelection) -> Void,
            onOpenHighlight: @escaping (String) -> Void,
            onBookEvent: @escaping (MobileBookPageEvent) -> Void
        ) {
            self.initialScrollFraction = initialScrollFraction
            self.onScrollFractionChange = onScrollFractionChange
            self.onAskAboutSelection = onAskAboutSelection
            self.onCreateHighlight = onCreateHighlight
            self.onOpenHighlight = onOpenHighlight
            self.onBookEvent = onBookEvent
        }

        func invalidate() {
            scrollObservation?.invalidate()
            scrollObservation = nil
        }

        // MARK: - Selection

        func handleSelection(_ raw: String, chapterID: String?) {
            let cleaned = MobileReaderText.cleanedSelection(raw)
            guard !cleaned.isEmpty else { return }
            onAskAboutSelection(MobileReaderSelection(id: UUID(), text: cleaned), chapterID)
        }

        func handleHighlightSelection(_ value: [String: Any]) {
            guard let quote = value["quote"] as? String,
                  let prefix = value["prefix"] as? String,
                  let suffix = value["suffix"] as? String,
                  let offset = value["offset"] as? Int else { return }
            let cleaned = MobileReaderText.cleanedSelection(quote)
            guard !cleaned.isEmpty else { return }
            onCreateHighlight(MobileReaderHighlightSelection(
                quote: cleaned,
                anchor: ReaderTextAnchor(exact: cleaned, prefix: prefix, suffix: suffix, offset: offset),
                pdfAnchor: nil,
                chapterID: value["chapter"] as? String
            ))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == MobileBookPageScript.messageHandlerName {
                guard isBook, let event = MobileBookPageEvent(message: message.body) else { return }
                if case .reading(let report) = event {
                    lastBookPoint = report.point
                }
                onBookEvent(event)
                return
            }
            guard message.name == "foreverlmHighlight", let id = message.body as? String else { return }
            onOpenHighlight(id)
        }

        func apply(highlights: [SourceHighlight], in webView: WKWebView) {
            self.highlights = highlights
            guard loadedHTML != nil else { return }
            let signature = highlights.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            guard signature != highlightSignature else { return }
            highlightSignature = signature
            guard let data = try? JSONEncoder().encode(highlights),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.foreverlmApplyHighlights?.(\(json));")
        }

        // MARK: - Scrolling

        /// KVO rather than becoming the scroll view's delegate — WKWebView owns
        /// that delegate and replacing it breaks its internal gesture handling.
        func observeScrolling(of webView: WKWebView) {
            guard scrollObservation == nil else { return }
            scrollObservation = webView.scrollView.observe(
                \.contentOffset,
                options: [.new]
            ) { [weak self] scrollView, _ in
                self?.handleScroll(scrollView)
            }
        }

        func prepareForLoad() {
            pendingScrollFraction = hasRestoredPosition ? latestFraction : initialScrollFraction
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            findPerformer?.documentChanged()
            if isBook {
                // The painter goes in first: the chapters arrive after it and are
                // painted as each batch that brings them finishes.
                highlightSignature = ""
                installHighlighting(in: webView)
                apply(highlights: highlights, in: webView)
                isBookPageReady = true
                syncBook(in: webView)
                return
            }
            restorePosition(in: webView)
            highlightSignature = ""
            installHighlighting(in: webView)
            apply(highlights: highlights, in: webView)
        }

        private func installHighlighting(in webView: WKWebView) {
            webView.evaluateJavaScript(MobileReaderPageScript.highlightPainter)
        }

        /// A book's pictures can outgrow what iOS lets one page's process keep, and
        /// the system then ends it and leaves the view blank. Load the page again,
        /// and put the reader back where they were.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isBook, let html = loadedHTML, let book else { return }
            prepareBookLoad(generation: book.generation, restore: lastBookPoint ?? book.restore)
            webView.loadHTMLString(html, baseURL: nil)
        }

        // MARK: - Whole book

        func prepareBookLoad(generation: Int, restore: MobileBookReadingPoint) {
            bookGeneration = generation
            bookLoadCount += 1
            bookDOM = .freshShell
            isBookPageReady = false
            isBookBatchRunning = false
            needsBookSync = false
            pendingBookRestore = restore
            lastBookPoint = nil
        }

        /// Brings the page up to `book`, one batch at a time. A change that would
        /// move the text above the reader waits while the page is being scrolled:
        /// a web view cannot move its scroll under a finger or a running fling,
        /// so it is made once the scroll rests, and the page holds the words still
        /// across it.
        func syncBook(in webView: WKWebView) {
            bookWebView = webView
            guard let book, isBookPageReady else { return }
            guard !isBookBatchRunning else {
                needsBookSync = true
                return
            }
            let scrollView = webView.scrollView
            let isScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            let plan = MobileBookPageSync.plan(
                from: bookDOM,
                to: book,
                restore: pendingBookRestore,
                allowsStartChanges: !isScrolling
            )
            if plan.needsReload, let html = loadedHTML {
                prepareBookLoad(generation: book.generation, restore: lastBookPoint ?? book.restore)
                webView.loadHTMLString(html, baseURL: nil)
                return
            }
            if plan.deferredStartChanges {
                scheduleBookIdleCheck()
            }
            guard !plan.operations.isEmpty else { return }

            let changesChapters = plan.resultingState.chapterIDs != bookDOM.chapterIDs
            if plan.performsRestore {
                pendingBookRestore = nil
            }
            isBookBatchRunning = true
            let load = bookLoadCount
            let steps = plan.operations.map { $0.payload(fontSize: MobileReaderText.bodyFontSize(for:)) }
            webView.callAsyncJavaScript(
                "return await window.foreverlmBook.apply(steps);",
                arguments: ["steps": steps],
                in: nil,
                in: .page
            ) { [weak self, weak webView] result in
                // A batch that outlived its page (a reload since) says nothing
                // about the page there is now.
                guard let self, self.bookLoadCount == load else { return }
                self.isBookBatchRunning = false
                var state = plan.resultingState
                switch result {
                case .success(let value):
                    // The page says what it holds; it never lets go of the chapter
                    // under the reading line, whatever it was asked.
                    if let held = value as? [String] { state.chapterIDs = held }
                    self.bookDOM = state
                case .failure(let error):
                    Self.logger.error("Book page batch failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if changesChapters {
                    self.findPerformer?.documentChanged()
                }
                guard self.needsBookSync, let webView else { return }
                self.needsBookSync = false
                self.syncBook(in: webView)
            }
        }

        private func scheduleBookIdleCheck() {
            guard !isBookIdleCheckScheduled else { return }
            isBookIdleCheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bookIdleRecheckDelay) { [weak self] in
                guard let self else { return }
                self.isBookIdleCheckScheduled = false
                guard let webView = self.bookWebView else { return }
                self.syncBook(in: webView)
            }
        }

        private static let logger = Logger(subsystem: "com.foreverlm.mobile", category: "SourceReader")

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The only legitimate navigation inside the reader is our own
            // loadHTMLString. A synced book chapter carries the publisher's own
            // markup, so links do exist now: an internal cross-reference points at
            // a file this device does not have and is simply cancelled, while a
            // real web link is handed to Safari rather than silently doing nothing.
            guard navigationAction.navigationType != .other else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return
            }
            UIApplication.shared.open(url)
        }

        private func handleScroll(_ scrollView: UIScrollView) {
            // A book page says where the reader is itself, by chapter.
            guard !isBook, !isRestoringPosition else { return }
            let fraction = Self.scrollFraction(of: scrollView)
            latestFraction = fraction

            let now = Date()
            guard now.timeIntervalSince(lastReportedAt) >= Self.reportInterval else { return }
            lastReportedAt = now
            onScrollFractionChange(fraction)
        }

        private func restorePosition(in webView: WKWebView, attempt: Int = 0) {
            guard let fraction = pendingScrollFraction else { return }
            guard fraction > 0.0001 else {
                finishRestoring()
                return
            }

            let scrollView = webView.scrollView
            let scrollable = Self.scrollableHeight(of: scrollView)
            guard scrollable > 1 else {
                // WebKit settles on the final content height a beat after
                // didFinish, so give it a bounded number of chances.
                guard attempt < Self.restoreRetryLimit else {
                    finishRestoring()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreRetryDelay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.restorePosition(in: webView, attempt: attempt + 1)
                }
                return
            }

            finishRestoring()
            isRestoringPosition = true
            let offsetY = fraction * scrollable - scrollView.adjustedContentInset.top
            scrollView.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
            latestFraction = fraction
            DispatchQueue.main.async { [weak self] in
                self?.isRestoringPosition = false
            }
        }

        private func finishRestoring() {
            pendingScrollFraction = nil
            hasRestoredPosition = true
        }

        private static func scrollableHeight(of scrollView: UIScrollView) -> CGFloat {
            let inset = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
            return scrollView.contentSize.height - visibleHeight
        }

        private static func scrollFraction(of scrollView: UIScrollView) -> Double {
            let scrollable = scrollableHeight(of: scrollView)
            guard scrollable > 1 else { return 0 }
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            return min(max(Double(offset / scrollable), 0), 1)
        }
    }
}
