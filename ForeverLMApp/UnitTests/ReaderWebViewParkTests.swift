import Foundation
import SwiftUI
import Testing
import WebKit
@testable import ForeverLM

/// The park hands one specific page back to one specific reader, so its
/// bookkeeping is what keeps a remount from inheriting the wrong document — or
/// a blank one. Serialized because the park is a single process-wide store.
@Suite("Reader web view park", .serialized)
@MainActor
struct ReaderWebViewParkTests {
    @Test("A remounting reader gets its own loaded page back")
    func remountReclaimsItsPage() async throws {
        ReaderWebViewPark.evictAll()
        let webView = try await makeLoadedWebView()
        let state = WebViewReader.ParkedPageState(
            initialPageURL: URL(string: "https://example.com/article"),
            didFallBackToCache: true,
            hasCommittedNavigation: true,
            hasCheckedLivePageReadability: true,
            lastArticleScrollOffset: 1280,
            hasLeftArticlePage: true
        )

        ReaderWebViewPark.park(webView, key: "article-1", pageState: state)
        let claimed = ReaderWebViewPark.claim(key: "article-1")

        #expect(claimed?.webView === webView)
        #expect(claimed?.pageState.initialPageURL == state.initialPageURL)
        #expect(claimed?.pageState.didFallBackToCache == true)
        #expect(claimed?.pageState.hasCheckedLivePageReadability == true)
        #expect(claimed?.pageState.lastArticleScrollOffset == 1280)
        #expect(claimed?.pageState.hasLeftArticlePage == true)
        // Claiming takes the page out of the park; nobody else can be handed it.
        #expect(ReaderWebViewPark.parkedKeys.isEmpty)
        ReaderWebViewPark.evictAll()
    }

    @Test("A different source does not inherit a parked page")
    func otherSourceDoesNotInheritPage() async throws {
        ReaderWebViewPark.evictAll()
        let webView = try await makeLoadedWebView()

        ReaderWebViewPark.park(webView, key: "article-1", pageState: settledState)

        #expect(ReaderWebViewPark.claim(key: "article-2") == nil)
        #expect(ReaderWebViewPark.parkedKeys == ["article-1"])
        ReaderWebViewPark.evictAll()
    }

    @Test("A page WebKit never loaded is not worth handing back")
    func unloadedPageIsNotHandedBack() {
        ReaderWebViewPark.evictAll()
        let webView = ForeverLMWebView()

        ReaderWebViewPark.park(webView, key: "article-1", pageState: settledState)

        #expect(ReaderWebViewPark.claim(key: "article-1") == nil)
        #expect(ReaderWebViewPark.parkedKeys.isEmpty)
    }

    @Test("The park does not grow past its capacity")
    func parkStopsAtCapacity() async throws {
        ReaderWebViewPark.evictAll()
        for index in 0..<(ReaderWebViewPark.capacity + 1) {
            let webView = try await makeLoadedWebView()
            ReaderWebViewPark.park(webView, key: "article-\(index)", pageState: settledState)
        }

        #expect(ReaderWebViewPark.parkedKeys.count == ReaderWebViewPark.capacity)
        // The oldest page is the one nobody has come back for.
        #expect(ReaderWebViewPark.claim(key: "article-0") == nil)
        #expect(ReaderWebViewPark.claim(key: "article-\(ReaderWebViewPark.capacity)") != nil)
        ReaderWebViewPark.evictAll()
    }

    @Test("A page nobody comes back for is let go")
    func unclaimedPageExpires() async throws {
        ReaderWebViewPark.evictAll()
        let webView = try await makeLoadedWebView()

        ReaderWebViewPark.park(webView, key: "article-1", pageState: settledState, lifetime: 0.2)
        #expect(ReaderWebViewPark.parkedKeys == ["article-1"])

        try await waitUntil { ReaderWebViewPark.parkedKeys.isEmpty }

        #expect(ReaderWebViewPark.claim(key: "article-1") == nil)
    }

    @Test("Parking drops the departing reader's hooks")
    func parkingClearsReaderHooks() async throws {
        ReaderWebViewPark.evictAll()
        let webView = try await makeLoadedWebView()
        webView.findState = ReaderFindState()
        webView.textToSpeechAction = {}
        webView.openLinkAction = { _ in }
        webView.canTextToSpeech = true

        ReaderWebViewPark.park(webView, key: "article-1", pageState: settledState)

        #expect(webView.findState == nil)
        #expect(webView.textToSpeechAction == nil)
        #expect(webView.openLinkAction == nil)
        #expect(!webView.canTextToSpeech)
        ReaderWebViewPark.evictAll()
    }

    @Test("Re-selecting a source row still reloads the reader")
    func reselectionDoesNotInheritTheParkedPage() async {
        let vm = makeViewModel()
        let article = StudioArticle(url: "https://example.com/article", title: "Article")
        vm.articles = [article]

        await vm.selectArticle(article.id)
        let mounted = WebViewReader.Coordinator(parent: makeReader(articleId: article.id, vm: vm))
        // A remount that is not a re-selection — a pane move, a workspace
        // restore — leaves the revision alone, so the page comes back.
        let moved = WebViewReader.Coordinator(parent: makeReader(articleId: article.id, vm: vm))
        #expect(mounted.reuseKey == moved.reuseKey)

        // Re-selecting the source row is the gesture that asks for the source's
        // own page back, and it must still cost a load.
        await vm.selectArticle(article.id)
        let reselected = WebViewReader.Coordinator(parent: makeReader(articleId: article.id, vm: vm))
        #expect(mounted.reuseKey != reselected.reuseKey)
    }

    private func makeViewModel() -> StudioViewModel {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderParkTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: storeRoot))
    }

    private func makeReader(articleId: String, vm: StudioViewModel) -> WebViewReader {
        WebViewReader(
            urlString: "https://example.com/article",
            articleId: articleId,
            vm: vm,
            cachedHTMLPath: nil,
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
    }

    private var settledState: WebViewReader.ParkedPageState {
        WebViewReader.ParkedPageState(
            initialPageURL: URL(string: "https://example.com/article"),
            didFallBackToCache: false,
            hasCommittedNavigation: true,
            hasCheckedLivePageReadability: true
        )
    }

    /// A web view with a settled document, which is the only kind the park will
    /// hand back. Loaded from a string so the test needs no network.
    private func makeLoadedWebView() async throws -> ForeverLMWebView {
        let webView = ForeverLMWebView()
        webView.loadHTMLString("<html><body><p>parked</p></body></html>", baseURL: nil)
        try await waitUntil { webView.url != nil && !webView.isLoading }
        return webView
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
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
