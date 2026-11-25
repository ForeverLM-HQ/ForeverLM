import Foundation
import SwiftUI
import Testing
import WebKit
@testable import ForeverLM

@Suite("Article reader chrome state")
@MainActor
struct ArticleReaderChromeStateTests {
    @Test("A departing reader cannot detach its replacement")
    func departingReaderCannotDetachReplacement() {
        let state = ArticleReaderChromeState()
        let outgoing = WKWebView()
        let incoming = WKWebView()

        state.bindNavigation(to: outgoing)
        state.bindNavigation(to: incoming)
        state.unbindNavigation(from: outgoing)

        #expect(state.hasNavigationTarget)

        state.unbindNavigation(from: incoming)

        #expect(!state.hasNavigationTarget)
    }

    @Test("Back acts on the same target that supplied its enabled state")
    func backUsesBoundTarget() {
        let state = ArticleReaderChromeState()
        let target = ReaderNavigationTargetStub(canGoBack: true)

        state.bindNavigation(to: target)
        #expect(state.canGoBack)

        state.goBack()

        #expect(target.backCallCount == 1)
        #expect(!state.canGoBack)
        #expect(state.canGoForward)
    }

    @Test("Stale enabled state cannot navigate the wrong target")
    func staleEnabledStateDoesNotNavigateWrongTarget() {
        let state = ArticleReaderChromeState()
        let outgoing = ReaderNavigationTargetStub(canGoBack: true)
        let incoming = ReaderNavigationTargetStub(canGoBack: false)

        state.bindNavigation(to: outgoing)
        state.bindNavigation(to: incoming)
        state.unbindNavigation(from: outgoing)
        state.goBack()

        #expect(outgoing.backCallCount == 0)
        #expect(incoming.backCallCount == 0)
        #expect(!state.canGoBack)
    }
}

@MainActor
private final class ReaderNavigationTargetStub: ArticleReaderNavigationTarget {
    var readerCanGoBack: Bool
    var readerCanGoForward = false
    var readerCurrentURL: URL?
    private(set) var backCallCount = 0

    init(canGoBack: Bool) {
        readerCanGoBack = canGoBack
    }

    func navigateReaderBack() -> Bool {
        backCallCount += 1
        guard readerCanGoBack else { return false }
        readerCanGoBack = false
        readerCanGoForward = true
        return true
    }

    func navigateReaderForward() -> Bool {
        guard readerCanGoForward else { return false }
        readerCanGoForward = false
        readerCanGoBack = true
        return true
    }
}

@Suite("Back to article")
@MainActor
struct ArticleReaderReturnStateTests {
    @Test("Back to article goes to the article's latest visit, past every page after it")
    func returnsToLatestArticleVisit() {
        let back = ["article#1", "linked-a", "article#2", "linked-b", "linked-c"]
        let entry = ArticleReaderReturnState.articleEntry(back: back, forward: []) {
            $0.hasPrefix("article")
        }
        #expect(entry == "article#2")
    }

    @Test("An article ahead in history is found when none is behind")
    func findsArticleAhead() {
        let entry = ArticleReaderReturnState.articleEntry(
            back: ["sign-in"],
            forward: ["linked", "article", "article-later"]
        ) { $0.hasPrefix("article") }
        #expect(entry == "article")
    }

    @Test("With no article in history there is nothing to go to")
    func noArticleInHistory() {
        let entry = ArticleReaderReturnState.articleEntry(back: ["a", "b"], forward: ["c"]) {
            $0 == "article"
        }
        #expect(entry == nil)
    }

    @Test("The button follows the page and runs the latest way back")
    func offerFollowsPage() {
        let state = ArticleReaderReturnState()
        var calls: [String] = []

        state.update(isAwayFromArticle: true) { calls.append("first") }
        #expect(state.isAwayFromArticle)
        state.update(isAwayFromArticle: true) { calls.append("second") }
        state.returnToArticle()
        #expect(calls == ["second"])

        state.update(isAwayFromArticle: false) { calls.append("third") }
        #expect(!state.isAwayFromArticle)
    }

    @Test("A paper says paper; every other page says article")
    func titleNamesTheSource() {
        #expect(ArticleReaderReturnState.title(for: .paper) == "Back to paper")
        #expect(ArticleReaderReturnState.title(for: .article) == "Back to article")
    }
}

@Suite("Reader and Browser boundary")
struct ReaderWebLinkRoutingTests {
    @Test("Reader keeps source locations and sends other web documents to Browser")
    func routesByDocumentIdentity() {
        let source = URL(string: "https://example.org/papers/one")!

        #expect(!ReaderWebLinkRouting.opensInBrowser(
            URL(string: "https://example.org/papers/one#methods"),
            sourceDocument: source
        ))
        #expect(!ReaderWebLinkRouting.opensInBrowser(
            URL(string: "https://example.org/papers/one?session=return"),
            sourceDocument: source
        ))
        #expect(ReaderWebLinkRouting.opensInBrowser(
            URL(string: "https://example.org/papers/two"),
            sourceDocument: source
        ))
        #expect(ReaderWebLinkRouting.opensInBrowser(
            URL(string: "https://publisher.example.net/reference"),
            sourceDocument: source
        ))
        #expect(!ReaderWebLinkRouting.opensInBrowser(
            URL(fileURLWithPath: "/tmp/chapter.xhtml"),
            sourceDocument: source
        ))
    }
}

@Suite("Article reader initial-load stall fallback")
@MainActor
struct ArticleReaderStallFallbackTests {
    @Test("A stalled first load swaps in the saved copy")
    func stalledLoadSwapsInSavedCopy() async throws {
        let cached = try makeCachedArticleFile()
        let (coordinator, webView) = makeReaderCoordinator(
            cachedHTMLPath: cached.path,
            stallSeconds: 0.05
        )

        coordinator.webView(webView, didStartProvisionalNavigation: nil)

        try await waitUntil { webView.url?.isFileURL == true }
        #expect(webView.url?.isFileURL == true)
        #expect(webView.url?.lastPathComponent == cached.lastPathComponent)
        withExtendedLifetime(coordinator) {}
    }

    @Test("A committed live page is never replaced by the saved copy")
    func committedPageIsNotReplaced() async throws {
        let cached = try makeCachedArticleFile()
        let (coordinator, webView) = makeReaderCoordinator(
            cachedHTMLPath: cached.path,
            stallSeconds: 0.05
        )

        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(webView, didCommit: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(webView.url == nil)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Without a saved copy a stalled load keeps waiting")
    func missingSavedCopyLeavesLoadAlone() async throws {
        let (coordinator, webView) = makeReaderCoordinator(
            cachedHTMLPath: nil,
            stallSeconds: 0.05
        )

        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(webView.url == nil)
        withExtendedLifetime(coordinator) {}
    }

    private func makeCachedArticleFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderStallTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("article.html")
        try "<html><body>saved copy</body></html>".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func makeReaderCoordinator(
        cachedHTMLPath: String?,
        stallSeconds: TimeInterval
    ) -> (WebViewReader.Coordinator, WKWebView) {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderStallTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let reader = WebViewReader(
            urlString: "https://example.com/article",
            articleId: "article-1",
            vm: StudioViewModel(storageService: StorageService(storeRoot: storeRoot)),
            cachedHTMLPath: cachedHTMLPath,
            initialScrollFraction: nil,
            scrollFractionChanged: { _ in },
            readingCompletionReached: {},
            selectedText: .constant(""),
            isLoading: .constant(true),
            canGoBack: .constant(false),
            canGoForward: .constant(false),
            currentDomain: .constant(""),
            currentURL: .constant(nil),
            webViewRef: .constant(nil),
            loadError: .constant(nil),
            zoomScale: ArticleReaderZoom.defaultScale,
            findState: ReaderFindState(),
            findRevision: 0,
            zoomPasscodeRevision: 0,
            chromeState: nil,
            zoomInAction: nil,
            zoomOutAction: nil,
            resetZoomAction: nil,
            textToSpeechAction: nil,
            explainSelectionAction: nil,
            openInSafariAction: nil,
            markPaywalledAction: nil
        )
        let coordinator = WebViewReader.Coordinator(parent: reader)
        coordinator.initialLoadStallFallbackSeconds = stallSeconds
        let webView = WKWebView()
        webView.navigationDelegate = coordinator
        return (coordinator, webView)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: () -> Bool
    ) async throws {
        let step: UInt64 = 20_000_000
        var waited: UInt64 = 0
        while !condition() && waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
}

/// WebKit's link commands are re-pointed at the app's own closures through
/// `MenuActionTarget`, which the menu item only holds weakly. AppKit calls
/// `didCloseMenu` *before* it sends the chosen item's action, so these replay
/// that order and check the item still reaches its closure.
@Suite("Web view context menu targets")
@MainActor
struct WebViewContextMenuTargetTests {
    private static let rightClick = NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!

    private static func webKitItem(_ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    /// Runs every item the way AppKit does once tracking ends: the view hears
    /// the menu close, then each item's action is sent.
    private static func closeThenFire(_ menu: NSMenu, on view: NSView) {
        view.didCloseMenu(menu, with: nil)
        for index in menu.items.indices {
            menu.performActionForItem(at: index)
        }
    }

    @Test("A Site source card's adopted items still fire after the menu has closed")
    func linkedDocItemsFireAfterMenuClosed() {
        let view = ForeverLMWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var opened: [String] = []
        view.sourceLinkActions = .init(
            openBeside: { opened.append("reader:\($0.sourceID)") },
            openInNewWindow: { opened.append("new-window:\($0.sourceID)") },
            windowTargets: {
                [LinkedDocWebView.SourceWindowTarget(label: "Window 1") { opened.append("window-1:\($0.sourceID)") }]
            }
        )
        view.noteContextLink(url: URL(string: "foreverlm://source/abcdef123456")!)
        let menu = NSMenu()
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierOpenLink"))
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierOpenLinkInNewWindow"))

        view.willOpenMenu(menu, with: Self.rightClick)
        #expect(menu.items.map(\.title) == ["Open in Reader", "Open in New Window", "Open in Window 1"])
        Self.closeThenFire(menu, on: view)

        #expect(opened == ["reader:abcdef123456", "new-window:abcdef123456", "window-1:abcdef123456"])
    }

    @Test("The reader's adopted link items still fire after the menu has closed")
    func readerLinkItemsFireAfterMenuClosed() {
        let view = ForeverLMWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var opened: [String] = []
        view.openLinkAction = { opened.append("open:\($0.absoluteString)") }
        view.openLinkExternallyAction = { opened.append("browser:\($0.absoluteString)") }
        view.downloadLinkAction = { opened.append("download:\($0.absoluteString)") }
        view.noteContextLink(url: URL(string: "https://example.com/paper.pdf")!, hasSelection: false)
        let menu = NSMenu()
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierOpenLink"))
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierOpenLinkInNewWindow"))
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierDownloadLinkedFile"))

        view.willOpenMenu(menu, with: Self.rightClick)
        Self.closeThenFire(menu, on: view)

        #expect(opened == [
            "open:https://example.com/paper.pdf",
            "browser:https://example.com/paper.pdf",
            "download:https://example.com/paper.pdf",
        ])
    }

    @Test("A reader link offers Open Link in New Tab right after Open Link")
    func readerOffersOpenLinkInNewTab() {
        let view = ForeverLMWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var opened: [String] = []
        view.openLinkAction = { opened.append("open:\($0.absoluteString)") }
        view.openLinkInNewTabAction = { opened.append("tab:\($0.absoluteString)") }
        view.noteContextLink(url: URL(string: "https://example.com/next")!, hasSelection: false)
        let menu = NSMenu()
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierOpenLink"))
        menu.addItem(Self.webKitItem("WKMenuItemIdentifierCopyLink"))

        view.willOpenMenu(menu, with: Self.rightClick)
        let titles = menu.items.map(\.title)
        let openIndex = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }
        #expect(openIndex.map { titles[$0 + 1] } == "Open Link in New Tab")
        Self.closeThenFire(menu, on: view)

        #expect(opened == ["open:https://example.com/next", "tab:https://example.com/next"])
    }

    @Test("A reader's web view configuration takes system Writing Tools off")
    func readerConfigurationDisablesWritingTools() {
        guard #available(macOS 15.0, *) else { return }
        let configuration = WKWebViewConfiguration()
        #expect((configuration.value(forKey: "writingToolsBehavior") as? Int) != NSWritingToolsBehavior.none.rawValue)

        SharedWebKit.disableSystemWritingTools(on: configuration)

        #expect((configuration.value(forKey: "writingToolsBehavior") as? Int) == NSWritingToolsBehavior.none.rawValue)
    }

    @Test("A reader's web view refuses the Apple Intelligence badge; a Browser tab's answers as WebKit does")
    func readerWebViewRefusesWritingToolsAffordance() {
        let selector = #selector(getter: ForeverLMWebView.allowsWritingToolsAffordance)
        guard #available(macOS 15.0, *), WKWebView.instancesRespond(to: selector) else { return }
        let readerConfiguration = WKWebViewConfiguration()
        SharedWebKit.disableSystemWritingTools(on: readerConfiguration)
        let reader = ForeverLMWebView(frame: .zero, configuration: readerConfiguration)

        #expect((reader.value(forKey: "allowsWritingToolsAffordance") as? Bool) == false)

        let tab = ForeverLMWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect((tab.value(forKey: "allowsWritingToolsAffordance") as? Bool)
            == (plain.value(forKey: "allowsWritingToolsAffordance") as? Bool))
    }
}
