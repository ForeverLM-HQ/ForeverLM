import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// The bar is the reader's only acknowledgement of a click on a page that
/// takes seconds to answer, so what it shows for each `(isLoading, progress)`
/// pair from WebKit is the behaviour worth pinning.
@Suite("Reader load progress")
struct ReaderLoadProgressTests {
    @Test("An idle web view shows no bar")
    func idleIsHidden() {
        var model = ReaderLoadProgressModel()
        #expect(model.presentation == .hidden)
        // A parked page coming back, or a fresh view before its first load:
        // WebKit reports not loading with the estimate parked at 1.
        model.update(isLoading: false, estimatedProgress: 1)
        #expect(model.presentation == .hidden)
    }

    @Test("A load that has only just started still draws a visible sliver")
    func startShowsMinimum() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0)
        #expect(model.presentation == .loading(fraction: ReaderLoadProgressModel.minimumVisibleFraction))
    }

    @Test("The bar follows WebKit's estimate and never moves backwards mid-load")
    func progressIsMonotonic() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0.1)
        model.update(isLoading: true, estimatedProgress: 0.6)
        #expect(model.presentation == .loading(fraction: 0.6))
        // A server redirect makes WebKit start its estimate over.
        model.update(isLoading: true, estimatedProgress: 0.1)
        #expect(model.presentation == .loading(fraction: 0.6))
        model.update(isLoading: true, estimatedProgress: 0.9)
        #expect(model.presentation == .loading(fraction: 0.9))
    }

    @Test("Finishing fills the bar, and the fade then hides it")
    func finishCompletesThenHides() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0.4)
        model.update(isLoading: false, estimatedProgress: 1)
        #expect(model.presentation == .completed)
        model.hideAfterCompletion()
        #expect(model.presentation == .hidden)
    }

    @Test("A bot-check page that reloads itself starts the bar over")
    func reloadAfterCompletionRestarts() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0.7)
        model.update(isLoading: false, estimatedProgress: 1)
        // The challenge script navigates again before the fade has finished.
        // `isLoading` flips while the estimate still says 1 for the page that
        // just finished; measured in the Dev reader on 2026-09-07, taking it
        // drew a full bar for the whole second load.
        model.update(isLoading: true, estimatedProgress: 1)
        #expect(model.presentation == .loading(fraction: ReaderLoadProgressModel.minimumVisibleFraction))
        model.update(isLoading: true, estimatedProgress: 0.1)
        #expect(model.presentation == .loading(fraction: 0.1))
        model.update(isLoading: true, estimatedProgress: 0.5)
        #expect(model.presentation == .loading(fraction: 0.5))
    }

    @Test("The first estimate of a load is not trusted either")
    func firstEstimateStartsAtMinimum() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0.9)
        #expect(model.presentation == .loading(fraction: ReaderLoadProgressModel.minimumVisibleFraction))
        model.update(isLoading: true, estimatedProgress: 0.9)
        #expect(model.presentation == .loading(fraction: 0.9))
    }

    @Test("Garbage estimates are clamped rather than drawn off the edge")
    func estimatesAreClamped() {
        var model = ReaderLoadProgressModel()
        model.update(isLoading: true, estimatedProgress: 0)
        model.update(isLoading: true, estimatedProgress: 4)
        #expect(model.presentation == .loading(fraction: 1))
        var nan = ReaderLoadProgressModel()
        nan.update(isLoading: true, estimatedProgress: 0)
        nan.update(isLoading: true, estimatedProgress: .nan)
        #expect(nan.presentation == .loading(fraction: ReaderLoadProgressModel.minimumVisibleFraction))
    }

    @Test("The host's bar tracks the installed web view and lets go on release")
    @MainActor
    func hostObservesInstalledWebView() async throws {
        let host = ReaderWebViewHost(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let webView = ForeverLMWebView()
        host.install(webView)
        #expect(host.progressBar.presentationForTesting == .hidden)

        webView.loadHTMLString("<html><body>hello</body></html>", baseURL: nil)
        // KVO on `isLoading` fires as the load is queued.
        var sawLoading = false
        for _ in 0..<50 {
            if case .loading = host.progressBar.presentationForTesting {
                sawLoading = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawLoading)

        var settled = false
        for _ in 0..<200 {
            switch host.progressBar.presentationForTesting {
            case .completed, .hidden:
                settled = true
            case .loading:
                break
            }
            if settled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(settled)

        _ = host.releaseWebView()
        #expect(host.progressBar.presentationForTesting == .hidden)
        #expect(host.webView == nil)
    }
}
