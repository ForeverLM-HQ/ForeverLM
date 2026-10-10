import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// Selecting words in a reply offers a bar of three actions: Add to chat,
/// More details, Ask in side chat. The page side is checked in the real
/// message template: the bar appears after a selection gesture, and pressing
/// an action (or the context menu's route) posts the action's name and the
/// passage over the `selectionAction` channel. The draft side is the pure
/// `ChatQuoteDraft` shape: the composer holds the passage beside the words, and
/// folds it in as the blockquote the sent bubble reads back.
@Suite("Chat quote selection")
struct ChatQuoteSelectionTests {
    // MARK: - Draft shape

    @Test("A passage becomes a blockquote, one marker per line, blank lines kept as bare markers")
    func blockquoteFormatsEveryLine() {
        #expect(ChatQuoteDraft.blockquote("  RET lowers the NAD+/NADH ratio.  ") == "> RET lowers the NAD+/NADH ratio.")
        #expect(
            ChatQuoteDraft.blockquote("First line.\n\nSecond paragraph.")
                == "> First line.\n>\n> Second paragraph."
        )
        #expect(ChatQuoteDraft.blockquote("   \n  ") == "")
    }

    @Test("A second quote joins the first as one pending passage, in the order they were quoted")
    func addingStacksPassages() {
        #expect(ChatQuoteDraft.adding("  A passage.  ", to: "") == "A passage.")
        #expect(ChatQuoteDraft.adding("Second.", to: "First.") == "First.\n\nSecond.")
    }

    @Test("An empty passage changes nothing")
    func addingEmptyPassage() {
        #expect(ChatQuoteDraft.adding("  ", to: "Keep me") == "Keep me")
    }

    @Test("The sent message opens with the quote and carries the words after a blank line")
    func composeJoinsQuoteAndWords() {
        #expect(
            ChatQuoteDraft.compose(quote: "A passage.", body: "  Why does that follow?  ")
                == "> A passage.\n\nWhy does that follow?"
        )
        // A quote alone is a message; it asks about itself.
        #expect(ChatQuoteDraft.compose(quote: "A passage.", body: "   ") == "> A passage.\n\n")
        // Without a quote the words go exactly as typed.
        #expect(ChatQuoteDraft.compose(quote: "", body: "Explain RET.") == "Explain RET.")
    }

    @Test("A composed message reads back as the passage and the words it was made from")
    func composeRoundTripsThroughSplit() {
        let composed = ChatQuoteDraft.compose(
            quote: "First line.\n\nSecond paragraph.",
            body: "Why does that follow?"
        )
        let split = ChatQuoteDraft.split(userMessage: composed)
        #expect(split?.quote == "First line.\n\nSecond paragraph.")
        #expect(split?.body == "Why does that follow?")
    }

    @Test("A sent message splits into its opening quote and the typed question")
    func splitReadsOpeningQuote() {
        let split = ChatQuoteDraft.split(userMessage: "> First line.\n>\n> Second paragraph.\n\nWhy does that follow?")
        #expect(split?.quote == "First line.\n\nSecond paragraph.")
        #expect(split?.body == "Why does that follow?")

        let bare = ChatQuoteDraft.split(userMessage: "> Just the quote.\n\n")
        #expect(bare?.quote == "Just the quote.")
        #expect(bare?.body == "")
    }

    @Test("A message that does not open with a quote is drawn as typed")
    func splitLeavesPlainMessagesAlone() {
        #expect(ChatQuoteDraft.split(userMessage: "Explain RET.") == nil)
        #expect(ChatQuoteDraft.split(userMessage: "Explain this:\n> a quote in the middle") == nil)
        #expect(ChatQuoteDraft.split(userMessage: ">\n>") == nil)
    }

    // MARK: - The page

    /// Records what the page posts on `selectionAction`: the passage, the
    /// action it was posted under, and the box the page measured around the
    /// words, read the way the app reads it.
    @MainActor
    private final class QuoteRecorder: NSObject, WKScriptMessageHandler {
        var passages: [String] = []
        var actions: [String] = []
        var rects: [CGRect?] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
            passages.append(text)
            actions.append(body["action"] as? String ?? "")
            rects.append(ChatMarkdownView.Coordinator.selectionRect(in: body))
        }
    }

    @MainActor
    private func loadedTemplate(markdown: String) async throws -> (WKWebView, QuoteRecorder) {
        let recorder = QuoteRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "selectionAction")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        // A web view in no window is a hidden page to WebKit, and a hidden
        // page's DOM timers are throttled ever harder the longer it stays
        // hidden: the bar's 50 ms follow-up to a mouse-up landed seconds late,
        // so each gesture after the first waited out its whole polling cap.
        // The chat's transparent on-screen host keeps the page visible, the
        // way a reply in a Studio window is; the frame stays this test's own.
        ChatBrowserHostWindow.shared.host(webView)
        webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        ChatMarkdownView.loadTemplate(into: webView)
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript(
                "typeof window.setMarkdown === 'function' && typeof window.requestSelectionAction === 'function'"
            ) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the message template never exposed requestSelectionAction")
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(Self.json(markdown))); true")
        return (webView, recorder)
    }

    private static func json(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    /// Selects the first paragraph the way a drag would, and lets go.
    private static let selectFirstParagraphAndRelease = """
    (() => {
      const p = document.querySelector('#content p');
      const range = document.createRange();
      range.selectNodeContents(p);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
      return selection.toString();
    })()
    """

    private static let pillState = """
    (() => {
      const host = document.querySelector('[data-foreverlm-selection-bar]');
      if (!host) return { present: false };
      const actions = Array.from(host.shadowRoot.querySelectorAll('.action'));
      return {
        present: true,
        shown: host.style.display !== 'none',
        labels: actions.map((action) => action.textContent.trim()),
        actions: actions.map((action) => action.dataset.action),
        visible: host.shadowRoot.querySelector('.bar').classList.contains('visible'),
      };
    })()
    """

    /// Presses the bar's action named `action`, as a click on the button.
    private static func press(_ action: String) -> String {
        "document.querySelector('[data-foreverlm-selection-bar]').shadowRoot"
            + ".querySelector('.action[data-action=\"\(action)\"]').click(); true"
    }

    @MainActor
    private func waitForPassages(_ recorder: QuoteRecorder, count: Int) async throws {
        for _ in 0..<50 where recorder.passages.count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A selection gesture in a reply shows the three-action bar, and Add to chat posts the passage as a quote")
    @MainActor
    func pillAppearsAndPostsSelection() async throws {
        let (webView, recorder) = try await loadedTemplate(
            markdown: "Reverse electron transport lowers the NAD+/NADH ratio.\n\nSecond paragraph."
        )

        let selected = try await webView.evaluateJavaScript(Self.selectFirstParagraphAndRelease) as? String
        #expect(selected == "Reverse electron transport lowers the NAD+/NADH ratio.")

        // The pill follows the gesture by a beat, so it never chases a drag.
        var state: [String: Any] = [:]
        for _ in 0..<40 {
            state = try await webView.evaluateJavaScript(Self.pillState) as? [String: Any] ?? [:]
            if state["shown"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(state["present"] as? Bool == true)
        #expect(state["shown"] as? Bool == true)
        #expect(state["visible"] as? Bool == true)
        #expect(state["labels"] as? [String] == ["Add to chat", "More details", "Ask in side chat"])
        #expect(state["actions"] as? [String] == ["quote", "moreDetails", "sideChat"])

        _ = try await webView.evaluateJavaScript(Self.press("quote"))
        try await waitForPassages(recorder, count: 1)
        #expect(recorder.passages == ["Reverse electron transport lowers the NAD+/NADH ratio."])
        #expect(recorder.actions == ["quote"])

        // The quote has gone; the band and the pill go with it.
        let collapsed = try await webView.evaluateJavaScript("window.getSelection().isCollapsed") as? Bool
        #expect(collapsed == true)
        let after = try await webView.evaluateJavaScript(Self.pillState) as? [String: Any]
        #expect(after?["shown"] as? Bool == false)
    }

    @Test("More details and Ask in side chat post the same passage under their own names")
    @MainActor
    func otherActionsPostUnderTheirNames() async throws {
        let (webView, recorder) = try await loadedTemplate(markdown: "Complex I pumps four protons per NADH.")
        for action in ["moreDetails", "sideChat"] {
            _ = try await webView.evaluateJavaScript(Self.selectFirstParagraphAndRelease)
            for _ in 0..<40 {
                let state = try await webView.evaluateJavaScript(Self.pillState) as? [String: Any] ?? [:]
                if state["shown"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            _ = try await webView.evaluateJavaScript(Self.press(action))
            try await waitForPassages(recorder, count: recorder.passages.count + 1)
        }
        #expect(recorder.actions == ["moreDetails", "sideChat"])
        #expect(recorder.passages == Array(repeating: "Complex I pumps four protons per NADH.", count: 2))
        // Each post says where the words are, so the side chat's popover can
        // hang off them: a box inside the page with the line's height.
        #expect(recorder.rects.count == 2)
        for rect in recorder.rects {
            let rect = try #require(rect)
            #expect(rect.width > 0 && rect.height > 0)
            #expect(rect.minX >= 0 && rect.minY >= 0)
            #expect(rect.maxX <= 640 && rect.maxY <= 480)
        }

        // The menu's route names its action too, and an action this page
        // does not know is refused rather than posted under a default.
        _ = try await webView.evaluateJavaScript(Self.selectFirstParagraphAndRelease)
        let unknown = try await webView.evaluateJavaScript("window.requestSelectionAction('explode')") as? Bool
        #expect(unknown == false)
        let sideChat = try await webView.evaluateJavaScript("window.requestSelectionAction('sideChat')") as? Bool
        #expect(sideChat == true)
        try await waitForPassages(recorder, count: 3)
        #expect(recorder.actions.last == "sideChat")
    }

    @Test("A passage with an equation in it quotes the equation's source, on one line")
    @MainActor
    func mathQuotesAsSource() async throws {
        // KaTeX draws Δψₘ as stacked boxes, which the browser's own reading of
        // the selection split over three lines; the quote carries the TeX the
        // reply wrote instead.
        let (webView, recorder) = try await loadedTemplate(
            markdown: "A treatment causes oxygen consumption to rise while $\\Delta\\psi_\\mathrm{m}$ falls. Why?"
        )
        let selected = try await webView.evaluateJavaScript(Self.selectFirstParagraphAndRelease) as? String
        #expect(selected?.contains("\n") == true, "the fix is only meaningful while KaTeX's boxes read as lines")

        let quoted = try await webView.evaluateJavaScript("window.requestSelectionAction('quote')") as? Bool
        #expect(quoted == true)
        try await waitForPassages(recorder, count: 1)
        #expect(
            recorder.passages
                == ["A treatment causes oxygen consumption to rise while $\\Delta\\psi_\\mathrm{m}$ falls. Why?"]
        )
    }

    @Test("A selection inside one equation quotes that equation, and paragraphs around math keep their breaks")
    @MainActor
    func mathSelectionShapes() async throws {
        let (webView, recorder) = try await loadedTemplate(
            markdown: "First, $E = mc^2$ holds.\n\n$$\\Delta G = -nF\\Delta E$$\n\nSecond paragraph."
        )
        // Only the glyphs of the inline equation.
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const math = document.querySelector('.chat-math-inline .katex');
          const range = document.createRange();
          range.selectNodeContents(math);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return window.requestSelectionAction('quote');
        })()
        """)
        try await waitForPassages(recorder, count: 1)
        #expect(recorder.passages.last == "$E = mc^2$")

        // Everything: the display equation stays a paragraph of its own.
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector('#content'));
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return window.requestSelectionAction('quote');
        })()
        """)
        try await waitForPassages(recorder, count: 2)
        #expect(
            recorder.passages.last
                == "First, $E = mc^2$ holds.\n\n$$\\Delta G = -nF\\Delta E$$\n\nSecond paragraph."
        )
    }

    @Test("The context menu's route posts the same passage, and nothing without a selection")
    @MainActor
    func menuRouteQuotesCurrentSelection() async throws {
        let (webView, recorder) = try await loadedTemplate(markdown: "A short reply.")

        let idle = try await webView.evaluateJavaScript("window.requestSelectionAction('quote')") as? Bool
        #expect(idle == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.passages.isEmpty)

        _ = try await webView.evaluateJavaScript(Self.selectFirstParagraphAndRelease)
        let quoted = try await webView.evaluateJavaScript("window.requestSelectionAction('quote')") as? Bool
        #expect(quoted == true)
        try await waitForPassages(recorder, count: 1)
        #expect(recorder.passages == ["A short reply."])
        #expect(recorder.actions == ["quote"])
    }

    @Test("The menu titles and the page's action names agree, one per action")
    func menuTitlesCoverEveryAction() {
        #expect(ChatReplySelectionAction.allCases.map(\.rawValue) == ["quote", "moreDetails", "sideChat"])
        // The box arrives as the page's numbers; anything short of a box is no anchor.
        #expect(
            ChatMarkdownView.Coordinator.selectionRect(in: ["rect": ["x": 12, "y": 30.5, "width": 200, "height": 17]])
                == CGRect(x: 12, y: 30.5, width: 200, height: 17)
        )
        #expect(ChatMarkdownView.Coordinator.selectionRect(in: ["rect": NSNull()]) == nil)
        #expect(ChatMarkdownView.Coordinator.selectionRect(in: [:]) == nil)
        #expect(ChatMarkdownView.Coordinator.selectionRect(in: ["rect": ["x": 1, "y": 2, "width": 0, "height": 0]]) == nil)
        #expect(ChatMarkdownView.Coordinator.selectionRect(in: ["rect": ["x": 1, "y": 2, "width": 3]]) == nil)
        #expect(
            ChatReplySelectionAction.allCases.map(\.menuTitle) == ["Add to Chat", "More Details", "Ask in Side Chat"]
        )
    }

    @Test("A programmatic selection alone never shows the bar")
    @MainActor
    func programmaticSelectionShowsNothing() async throws {
        let (webView, _) = try await loadedTemplate(markdown: "Found by search, not selected by hand.")
        _ = try await webView.evaluateJavaScript("""
        (() => {
          const range = document.createRange();
          range.selectNodeContents(document.querySelector('#content p'));
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return true;
        })()
        """)
        try await Task.sleep(for: .milliseconds(150))
        let state = try await webView.evaluateJavaScript(Self.pillState) as? [String: Any]
        #expect(state?["present"] as? Bool != true || state?["shown"] as? Bool == false)
    }
}
