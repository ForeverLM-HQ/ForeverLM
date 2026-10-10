import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// Find selects its match so the learner can see it. Closing the bar has to
/// take that selection back, or the word stays boxed in gray over the text and
/// over any saved highlight beneath it — while a selection the learner made in
/// the meantime is theirs and stays.
@Suite("Reader find match clearing")
@MainActor
struct ReaderFindMatchClearingTests {
    private let passage = "modulators of oxidative phosphorylation"
    private let matchRange = NSRange(location: 14, length: 9)

    @Test("Closing find collapses the match it selected in a text reader")
    func closeCollapsesTextMatch() {
        let textView = makeTextView()
        let state = ReaderFindState()
        state.show()

        ReaderFindPerformer.performTextFind(in: textView, state: state, query: "oxidative", backwards: false)
        #expect(textView.selectedRange() == matchRange)
        #expect(state.statusText == "1 of 1")

        state.close()
        #expect(textView.selectedRange().length == 0)
        #expect(!state.isVisible)
    }

    @Test("A selection the learner made after the find survives closing it")
    func closeKeepsLearnerSelection() {
        let textView = makeTextView()
        let state = ReaderFindState()
        state.show()
        ReaderFindPerformer.performTextFind(in: textView, state: state, query: "oxidative", backwards: false)

        let learnerSelection = NSRange(location: 0, length: 10)
        textView.setSelectedRange(learnerSelection)
        state.close()
        #expect(textView.selectedRange() == learnerSelection)
    }

    @Test("Closing find runs the registered clearing once")
    func closeRunsClearingOnce() {
        let state = ReaderFindState()
        var runs = 0
        state.registerMatchClearing { runs += 1 }

        state.close()
        state.close()
        #expect(runs == 1)
    }

    @Test("A transcript's own find bar holds the find while it is mounted, closed or open, so the Reader's bar stands down")
    func transcriptBarHoldsTheFind() {
        let state = ReaderFindState()
        #expect(!state.hasInlineBar)
        let video = UUID()
        let podcast = UUID()
        state.registerInlineBar(video)
        state.registerInlineBar(video)
        state.registerInlineBar(podcast)

        // Opening and closing the find, or the document changing under a
        // player that stays mounted, is no reason to give the claim up.
        state.show()
        state.close()
        state.resetForDocumentChange()
        #expect(state.hasInlineBar)

        state.unregisterInlineBar(video)
        #expect(state.hasInlineBar)
        state.unregisterInlineBar(podcast)
        #expect(!state.hasInlineBar)
    }

    @Test("A document change forgets the departing document's match")
    func documentChangeDropsPendingClearing() {
        let state = ReaderFindState()
        var cleared = false
        state.registerMatchClearing { cleared = true }

        state.resetForDocumentChange()
        state.close()
        #expect(!cleared)
    }

    @Test("Closing find drops the selection WebKit left on its match")
    func closeClearsWebMatch() async throws {
        let webView = ForeverLMWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        webView.loadHTMLString("<html><body><p>\(passage)</p></body></html>", baseURL: nil)
        try await waitUntil { webView.url != nil && !webView.isLoading }

        let state = ReaderFindState()
        state.show()
        ReaderFindPerformer.performWebFind(in: webView, state: state, query: "oxidative", backwards: false)
        try await waitUntil { try await selectedText(in: webView) == "oxidative" }
        #expect(try await selectedText(in: webView) == "oxidative")

        state.close()
        try await waitUntil { try await selectedText(in: webView).isEmpty }
        #expect(try await selectedText(in: webView).isEmpty)
    }

    @Test("A doc's rendered page finds like a reader")
    func pageViewFindsInRenderedDoc() async throws {
        let state = ReaderFindState()
        let page = ArtifactPageWebView(html: "", onAddToLibrary: { _ in }, findState: state, findRevision: 0)
        let coordinator = page.makeCoordinator()
        let webView = DocPageWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        webView.navigationDelegate = coordinator
        coordinator.load("<html><body><p>\(passage)</p></body></html>", into: webView)
        try await waitUntil { webView.url != nil && !webView.isLoading }

        state.show()
        state.query = "oxidative"
        // Nothing has been searched yet, so nothing is selected.
        coordinator.performFindIfNeeded(in: webView, revision: 0, state: state)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try await selectedText(in: webView).isEmpty)

        state.search()
        coordinator.performFindIfNeeded(in: webView, revision: state.searchRevision, state: state)
        try await waitUntil { try await selectedText(in: webView) == "oxidative" }
        #expect(try await selectedText(in: webView) == "oxidative")
        #expect(state.statusText.isEmpty)

        state.close()
        try await waitUntil { try await selectedText(in: webView).isEmpty }
        #expect(try await selectedText(in: webView).isEmpty)
    }

    @Test("Cmd+F reaching a doc's web view opens its find bar")
    func commandFindInDocWebViewsShowsBar() {
        let commandF = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3
        )!

        let pageState = ReaderFindState()
        let pageView = DocPageWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pageView.findState = pageState
        pageView.keyDown(with: commandF)
        #expect(pageState.isVisible)
        #expect(pageState.focusRevision == 1)

        let editorState = ReaderFindState()
        let editorView = ArtifactEditorWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editorView.findState = editorState
        editorView.keyDown(with: commandF)
        #expect(editorState.isVisible)
    }

    @Test("The clearing script carries the needle as a string literal")
    func clearingScriptQuotesNeedle() {
        let script = ReaderFindPerformer.clearMatchSelectionScript(matching: "it's \"quoted\"")
        #expect(script.contains(#"["it's \"quoted\""][0]"#))
        #expect(script.contains("removeAllRanges"))
    }

    private func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = passage
        return textView
    }

    private func selectedText(in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("window.getSelection().toString()") { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as? String ?? "")
                }
            }
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ condition: () async throws -> Bool
    ) async throws {
        let step: UInt64 = 20_000_000
        var waited: UInt64 = 0
        while try await !condition() && waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
    }
}
