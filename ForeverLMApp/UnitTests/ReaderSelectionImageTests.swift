import Foundation
import Testing
import WebKit
@testable import ForeverLM

#if os(macOS)

/// A Reader selection that covers a picture: the page reports it, Chat
/// attaches it, Highlight anchors a mark to it, and the mark is painted and
/// stored without a schema change.
@Suite("Reader selection pictures")
struct ReaderSelectionImageTests {

    /// A 1×1 transparent PNG, the smallest picture every route reads.
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    private static var pngDataURL: String { "data:image/png;base64,\(pngBase64)" }

    // MARK: - The description a page posts

    @Test("A picture entry is read with its box; a spacer without a source is not")
    func payloadDecodes() {
        let entry: [String: Any] = [
            "src": "https://cdn.example.com/figures/spatial-screening.png?w=1600",
            "alt": "  Spatial biology data\nimproves selection ",
            "width": 1600, "height": 900,
            "left": 100.5, "top": 200, "right": 700.5, "bottom": 600,
        ]
        let image = ReaderSelectionImage(payload: entry)
        #expect(image?.src == "https://cdn.example.com/figures/spatial-screening.png?w=1600")
        #expect(image?.alt == "Spatial biology data improves selection")
        #expect(image?.width == 1600)
        #expect(image?.viewportRect == CGRect(x: 100.5, y: 200, width: 600, height: 400))
        #expect(image?.anchor.fileName == "spatial-screening.png")
        #expect(image?.attachmentName == "Spatial biology data improves selection")

        #expect(ReaderSelectionImage(payload: ["alt": "no source"]) == nil)
        #expect(ReaderSelectionImage(payload: ["src": "   "]) == nil)
    }

    @Test("A list is de-duplicated by URL and capped at the chat's picture limit")
    func listCapsAndDeduplicates() {
        var entries: [[String: Any]] = []
        for index in 0..<10 {
            entries.append(["src": "https://example.com/p\(index % 6).png"])
        }
        let list = ReaderSelectionImage.list(from: entries)
        #expect(list.count == ReaderSelectionImage.maximumPerSelection)
        #expect(list.map(\.src) == (0..<4).map { "https://example.com/p\($0).png" })
        #expect(ReaderSelectionImage.list(from: nil).isEmpty)
        #expect(ReaderSelectionImage.list(from: "not a list").isEmpty)
    }

    @Test("The attachment name falls back to the file, then to Picture")
    func attachmentNames() {
        #expect(ReaderSelectionImage(src: "https://x.example/img/fig%202.webp").attachmentName == "fig 2.webp")
        #expect(ReaderSelectionImage(src: "blob:https://x.example/8b1c").attachmentName == "8b1c")
        #expect(ReaderSelectionImage(src: "https://x.example/").attachmentName == "Picture")
        #expect(ReaderSelectionImage(src: "https://x.example/a.png", alt: String(repeating: "x", count: 200)).attachmentName.count == 80)
    }

    @Test("Bytes come inline from a data: picture and are fetched for http and file, never for blob")
    func byteRoutes() {
        let inline = ReaderSelectionImage(src: Self.pngDataURL)
        #expect(inline.inlineData == Data(base64Encoded: Self.pngBase64))
        #expect(inline.fetchURL == nil)

        let blob = ReaderSelectionImage(src: "blob:https://x.example/abc", dataURL: Self.pngDataURL)
        #expect(blob.fetchURL == nil)
        #expect(blob.inlineData == Data(base64Encoded: Self.pngBase64))
        #expect(ReaderSelectionImage(src: "blob:https://x.example/abc").inlineData == nil)

        #expect(ReaderSelectionImage(src: "https://x.example/a.png").fetchURL?.host == "x.example")
        #expect(ReaderSelectionImage(src: "file:///tmp/a.png").fetchURL?.isFileURL == true)
        #expect(ReaderSelectionImage.decodeDataURL("data:image/svg+xml,%3Csvg%3E") == nil)
    }

    @Test("A data: picture becomes a chat attachment with the page's name for it")
    @MainActor
    func inlinePictureBecomesAttachment() async {
        let outcome = await ReaderSelectionImageResolver.attachments(
            for: [ReaderSelectionImage(src: Self.pngDataURL, alt: "One pixel")],
            snapshot: nil
        )
        #expect(outcome.unreadable == 0)
        #expect(outcome.attachments.count == 1)
        #expect(outcome.attachments.first?.name == "One pixel")
        #expect(outcome.attachments.first?.image.mediaType == "image/png")
        #expect(outcome.attachments.first?.pixelWidth == 1)

        // A picture nothing can read is counted, not dropped in silence.
        let unread = await ReaderSelectionImageResolver.attachments(
            for: [ReaderSelectionImage(src: "blob:https://x.example/gone")],
            snapshot: nil
        )
        #expect(unread.attachments.isEmpty)
        #expect(unread.unreadable == 1)
    }

    // MARK: - The anchor

    @Test("A selection of pictures alone still anchors; nothing at all does not")
    func webAnchorAcceptsPicturesAlone() {
        let payload: [String: Any] = [
            "type": "highlightRequest", "text": "  ", "prefix": "R2 of predicting", "suffix": "In solid tumors", "offset": 812,
            "images": [["src": "https://x.example/fig.png", "alt": "Figure"]],
        ]
        let anchor = ReaderWebSelectionAnchor(payload: payload)
        #expect(anchor?.text == "  ")
        #expect(anchor?.anchor.isEmpty == true)
        #expect(anchor?.anchor.offset == 812)
        #expect(anchor?.imageAnchors == [ReaderImageAnchor(src: "https://x.example/fig.png", alt: "Figure")])

        #expect(ReaderWebSelectionAnchor(payload: ["type": "highlightRequest", "text": "", "images": []]) == nil)

        let message = ReaderSelectionMessage(body: ["type": "chatRequest", "text": "", "images": [["src": "https://x.example/fig.png"]]])
        #expect(message?.text == "")
        #expect(message?.images.map(\.src) == ["https://x.example/fig.png"])
    }

    @Test("Pictures live in the quads column as an object; PDF quads stay an array and read as no pictures")
    func storedGeometryRoundTrips() {
        let anchors = [
            ReaderImageAnchor(src: "https://x.example/a.png", alt: "A", width: 800, height: 600),
            ReaderImageAnchor(src: "https://x.example/b.png"),
        ]
        let json = ReaderImageAnchor.storedJSON(anchors)
        #expect(json.hasPrefix("{"))
        #expect(ReaderImageAnchor.anchors(storedJSON: json) == anchors)
        // The PDF reader reads the same column and must see no quads in it.
        #expect(ReaderPDFAnchor(pageIndex: 0, quadsJSON: json) == nil)

        #expect(ReaderImageAnchor.storedJSON([]) == "[]")
        #expect(ReaderImageAnchor.anchors(storedJSON: "[]").isEmpty)
        let quads = ReaderPDFAnchor(pageIndex: 2, rects: [CGRect(x: 1, y: 2, width: 3, height: 4)]).quadsJSON
        #expect(ReaderImageAnchor.anchors(storedJSON: quads).isEmpty)
        #expect(ReaderImageAnchor.anchors(storedJSON: "not json").isEmpty)
        #expect(ReaderImageAnchor.anchors(storedJSON: #"{"images":[{"src":"","alt":"","width":0,"height":0}]}"#).isEmpty)

        let highlight = SourceHighlight(
            id: "hl_1", sourceID: "src", quote: "", note: "", color: .blue,
            anchor: ReaderTextAnchor(exact: "", prefix: "before", suffix: "after", offset: 40),
            pdfAnchor: nil, imageAnchors: anchors, createdAt: Date(), updatedAt: Date()
        )
        #expect(highlight.isPictureOnly)
        #expect(highlight.pictureLabel == "2 pictures")
        // A Webflow page sets a zero-width joiner beside its figure, and a
        // drag over the figure alone brings it along: still a picture mark.
        var shaped = highlight
        shaped.quote = "\u{200D} \u{200B}"
        #expect(shaped.isPictureOnly)
        #expect(!SourceHighlight.hasWords("\u{200D}"))
        #expect(SourceHighlight.hasWords(" a "))
        #expect(highlight.geometryJSON == json)
        var single = highlight
        single.imageAnchors = [anchors[1]]
        #expect(single.pictureLabel == "Picture")
        #expect(SourceHighlight(
            id: "hl_2", sourceID: "src", quote: "words", note: "", color: .blue,
            anchor: ReaderTextAnchor(exact: "words"), pdfAnchor: nil, createdAt: Date(), updatedAt: Date()
        ).geometryJSON == "[]")
    }

    @Test("A synced record without pictures decodes as before, and one with pictures keeps them")
    func codableKeepsOldRecords() throws {
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let old = SourceHighlight(
            id: "hl_old", sourceID: "src", quote: "words", note: "n", color: .green,
            anchor: ReaderTextAnchor(exact: "words", prefix: "p", suffix: "s", offset: 3),
            pdfAnchor: nil, createdAt: now, updatedAt: now
        )
        let oldData = try JSONEncoder().encode(old)
        let oldObject = try JSONSerialization.jsonObject(with: oldData) as? [String: Any]
        // A text-only mark's record is byte for byte what it was before pictures.
        #expect(oldObject?["imageAnchors"] == nil)
        #expect(try JSONDecoder().decode(SourceHighlight.self, from: oldData) == old)

        var withPictures = old
        withPictures.imageAnchors = [ReaderImageAnchor(src: "https://x.example/a.png", alt: "A")]
        let data = try JSONEncoder().encode(withPictures)
        #expect(try JSONDecoder().decode(SourceHighlight.self, from: data) == withPictures)
        let payload = CloudKitSourceHighlightPayload(highlight: withPictures, sourceIdentity: nil)
        let decoded = try JSONDecoder().decode(CloudKitSourceHighlightPayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.highlight.imageAnchors == withPictures.imageAnchors)
    }

    // MARK: - The chat's context block

    @Test("A picture-only selection tells the model which attachment it is; words keep their heading")
    func contextBlockNamesPictures() throws {
        let prepared = try ChatImagePreparation.prepare(Data(base64Encoded: Self.pngBase64)!)
        let attachment = ChatImageAttachment(prepared: prepared, name: "Figure 2")

        let pictureOnly = ReaderSelectionExplanationRequest(sourceID: "src-1", selectedText: "", imageAttachments: [attachment])
        #expect(pictureOnly.isPictureOnly)
        let block = pictureOnly.contextualContent(fallbackTitle: "The Missing Dimension")
        #expect(block == """
            Selected picture: attached to this message as "Figure 2".

            Context: The Missing Dimension

            Source ID: src-1
            """)
        // No words were selected, so there is no passage to draw or flash.
        #expect(ChatPassageOrigin.parse(contextContent: block) == nil)

        let mixed = ReaderSelectionExplanationRequest(
            sourceID: "src-1",
            selectedText: "Spatial biology data dramatically improves selection",
            imageAttachments: [attachment, ChatImageAttachment(prepared: prepared, name: "Figure 3")]
        )
        #expect(!mixed.isPictureOnly)
        let mixedBlock = mixed.contextualContent(fallbackTitle: "The Missing Dimension")
        #expect(mixedBlock.hasPrefix("Selected passage:\n> Spatial biology data dramatically improves selection\n\nSelected pictures: 2, attached to this message as \"Figure 2\", \"Figure 3\".\n\nContext: The Missing Dimension"))
        let passage = ChatPassageOrigin.parse(contextContent: mixedBlock)
        #expect(passage?.quote == "Spatial biology data dramatically improves selection")
        #expect(passage?.sourceID == "src-1")

        #expect(ReaderSelectionExplanationRequest(sourceID: "src-1", selectedText: "  ").contextualContent() == "")
    }

    // MARK: - The page

    /// Records what the reader page posts on its handler.
    @MainActor
    private final class PageRecorder: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            messages.append(body)
        }

        func messages(ofType type: String) -> [[String: Any]] {
            messages.filter { $0["type"] as? String == type }
        }
    }

    private static let pageHTML = """
    <!doctype html><html><body style="margin:0;padding:40px">
    <p id="lead">Spatial biology data dramatically improves selection of top solid tumor CAR T designs.</p>
    <figure id="figure"><img id="fig" src="\(pngDataURL)" alt="Spatial pooled screening" width="240" height="160"></figure>
    <img id="pixel" src="\(pngDataURL)" alt="" width="1" height="1">
    <p id="tail">In solid tumors, the question of which T cells are doing useful work depends on where they are.</p>
    </body></html>
    """

    @MainActor
    private func loadedPage() async throws -> (WKWebView, PageRecorder) {
        let recorder = PageRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "foreverlm")
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewReader.selectionDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(Self.pageHTML, baseURL: URL(string: "https://reader.example/writings/pooled-screens"))
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript(
                "window.foreverLMReaderUserSelectionInstalled === true && typeof window.foreverLMApplyHighlights === 'function'"
            ) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the reader scripts never installed")
        return (webView, recorder)
    }

    /// Selects `selector`'s node the way a drag over it does, and lets go.
    private static func selectAndRelease(_ selector: String, contents: Bool = false) -> String {
        """
        (() => {
          const node = document.querySelector('\(selector)');
          const range = document.createRange();
          \(contents ? "range.selectNodeContents(node);" : "range.selectNode(node);")
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
          return selection.toString();
        })()
        """
    }

    private static let pillState = """
    (() => {
      const host = document.querySelector('[data-foreverlm-selection-callout]');
      if (!host) return { present: false };
      return {
        present: true,
        shown: host.style.display !== 'none',
        visible: host.shadowRoot.querySelector('.bar').classList.contains('visible'),
      };
    })()
    """

    private static func press(_ action: String) -> String {
        "document.querySelector('[data-foreverlm-selection-callout]').shadowRoot"
            + ".querySelector('.pill[data-action=\"\(action)\"]').click(); true"
    }

    @MainActor
    private func waitForMessages(_ recorder: PageRecorder, ofType type: String, count: Int) async throws {
        for _ in 0..<60 where recorder.messages(ofType: type).count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A drag over a figure alone summons the bar, and Chat posts the picture with no words")
    @MainActor
    func pictureSelectionSummonsBarAndChats() async throws {
        let (webView, recorder) = try await loadedPage()

        let selected = try await webView.evaluateJavaScript(Self.selectAndRelease("#fig")) as? String
        #expect(selected == "")

        var state: [String: Any] = [:]
        for _ in 0..<40 {
            state = try await webView.evaluateJavaScript(Self.pillState) as? [String: Any] ?? [:]
            if state["shown"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(state["present"] as? Bool == true)
        #expect(state["shown"] as? Bool == true)
        #expect(state["visible"] as? Bool == true)

        try await waitForMessages(recorder, ofType: "selection", count: 1)
        let report = try #require(recorder.messages(ofType: "selection").last)
        #expect(report["text"] as? String == "")
        let reported = ReaderSelectionImage.list(from: report["images"])
        #expect(reported.count == 1)
        #expect(reported.first?.alt == "Spatial pooled screening")
        #expect(reported.first?.src == Self.pngDataURL)
        // Where it was drawn, for the snapshot route.
        #expect(reported.first?.viewportRect?.width == 240)
        #expect(reported.first?.viewportRect?.height == 160)
        // A data: picture is fetched by the app, not pushed over the bridge.
        #expect(reported.first?.dataURL == nil)

        _ = try await webView.evaluateJavaScript(Self.press("chat"))
        try await waitForMessages(recorder, ofType: "chatRequest", count: 1)
        let chat = try #require(recorder.messages(ofType: "chatRequest").last)
        #expect(chat["text"] as? String == "")
        #expect(ReaderSelectionImage.list(from: chat["images"]).map(\.alt) == ["Spatial pooled screening"])
    }

    @Test("Highlight over a figure posts an anchor with an empty passage, the words around it, and the picture; a drag over words and the figure carries both")
    @MainActor
    func highlightAnchorsThePicture() async throws {
        let (webView, recorder) = try await loadedPage()

        _ = try await webView.evaluateJavaScript(Self.selectAndRelease("#fig"))
        try await waitForMessages(recorder, ofType: "selection", count: 1)
        _ = try await webView.evaluateJavaScript(Self.press("highlight"))
        try await waitForMessages(recorder, ofType: "highlightRequest", count: 1)

        let request = try #require(recorder.messages(ofType: "highlightRequest").last)
        let anchor = try #require(ReaderWebSelectionAnchor(payload: request))
        #expect(anchor.text.trimmingCharacters(in: .whitespacesAndNewlines) == "")
        // Context is kept raw (the whitespace between the paragraph and the
        // figure included); the Swift side normalizes it when scoring.
        #expect(anchor.prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("CAR T designs."))
        #expect(anchor.suffix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("In solid tumors"))
        #expect(anchor.offset == "Spatial biology data dramatically improves selection of top solid tumor CAR T designs.".count)
        #expect(anchor.imageAnchors.map(\.alt) == ["Spatial pooled screening"])
        // Pressing Highlight let go of the selection so the mark shows.
        #expect(try await webView.evaluateJavaScript("window.getSelection().isCollapsed") as? Bool == true)

        // Words and the figure together: one anchor with both.
        _ = try await webView.evaluateJavaScript(Self.selectAndRelease("body", contents: true))
        try await waitForMessages(recorder, ofType: "selection", count: 3)
        _ = try await webView.evaluateJavaScript(Self.press("highlight"))
        try await waitForMessages(recorder, ofType: "highlightRequest", count: 2)
        let bothRequest = try #require(recorder.messages(ofType: "highlightRequest").last)
        let both = try #require(ReaderWebSelectionAnchor(payload: bothRequest))
        #expect(both.text.contains("Spatial biology data dramatically improves"))
        #expect(both.text.contains("In solid tumors"))
        // The one-pixel spacer is not a picture the learner meant.
        #expect(both.imageAnchors.map(\.alt) == ["Spatial pooled screening"])
    }

    @Test("A saved mark on a picture is outlined on the page, opens its note on a click, and is found again by file name")
    @MainActor
    func savedPictureMarkIsPaintedAndClickable() async throws {
        let (webView, recorder) = try await loadedPage()
        let now = Date()
        let mark = SourceHighlight(
            id: "hl_picture", sourceID: "src", quote: "", note: "", color: .pink,
            anchor: ReaderTextAnchor(exact: ""), pdfAnchor: nil,
            imageAnchors: [ReaderImageAnchor(src: Self.pngDataURL, alt: "Spatial pooled screening")],
            createdAt: now, updatedAt: now
        )
        ReaderWebHighlightSupport.apply([mark], to: webView)

        var painted: [String: Any] = [:]
        for _ in 0..<40 {
            painted = try await webView.evaluateJavaScript("""
            (() => {
              const img = document.getElementById('fig');
              return {
                id: img.getAttribute('data-foreverlm-note') || '',
                color: img.getAttribute('data-foreverlm-note-color') || '',
                outline: getComputedStyle(img).outlineStyle,
                pixel: document.getElementById('pixel').hasAttribute('data-foreverlm-note'),
              };
            })()
            """) as? [String: Any] ?? [:]
            if painted["id"] as? String == "hl_picture" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(painted["id"] as? String == "hl_picture")
        #expect(painted["color"] as? String == "pink")
        #expect(painted["outline"] as? String == "solid")
        // Two pictures share the bytes; a mark is one picture, and the first
        // in page order takes it.
        #expect(painted["pixel"] as? Bool == false)

        _ = try await webView.evaluateJavaScript("document.getElementById('fig').click(); true")
        try await waitForMessages(recorder, ofType: "openNote", count: 1)
        #expect(recorder.messages(ofType: "openNote").last?["highlightId"] as? String == "hl_picture")

        // Clearing takes the outline off again.
        ReaderWebHighlightSupport.apply([], to: webView)
        var cleared = false
        for _ in 0..<40 where !cleared {
            cleared = try await webView.evaluateJavaScript("!document.getElementById('fig').hasAttribute('data-foreverlm-note')") as? Bool ?? false
            if !cleared { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(cleared)

        // A page served from a moved CDN URL still paints by file name.
        _ = try await webView.evaluateJavaScript("""
        document.getElementById('fig').setAttribute('src', 'https://cdn.example/uploads/2026/fig-2.png?w=800');
        document.getElementById('pixel').setAttribute('src', 'https://cdn.example/uploads/2026/other.png'); true
        """)
        var moved = mark
        moved.imageAnchors = [ReaderImageAnchor(src: "https://images.example/fig-2.png", alt: "Spatial pooled screening")]
        ReaderWebHighlightSupport.apply([moved], to: webView)
        var found = false
        for _ in 0..<40 where !found {
            found = try await webView.evaluateJavaScript("document.getElementById('fig').getAttribute('data-foreverlm-note') === 'hl_picture'") as? Bool ?? false
            if !found { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(found)
    }

    /// Whether the bar's Side chat is showing, or nil before the bar exists.
    private static let sideChatShown = """
    (() => {
      const host = document.querySelector('[data-foreverlm-selection-callout]');
      if (!host || host.style.display === 'none') return null;
      return host.shadowRoot.querySelector('.pill[data-action="sideChat"]').style.display !== 'none';
    })()
    """

    @MainActor
    private func sideChatShown(in webView: WKWebView, becoming expected: Bool) async throws -> Bool? {
        var shown: Bool?
        for _ in 0..<40 {
            shown = try await webView.evaluateJavaScript(Self.sideChatShown) as? Bool
            if shown == expected { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return shown
    }

    @Test("Side chat is offered over words, not over a picture alone, and posts the words with their box, leaving them selected")
    @MainActor
    func sideChatPostsTheWordsAndWhereTheyAre() async throws {
        let (webView, recorder) = try await loadedPage()

        _ = try await webView.evaluateJavaScript(Self.selectAndRelease("#fig"))
        #expect(try await sideChatShown(in: webView, becoming: false) == false)

        let selected = try await webView.evaluateJavaScript(Self.selectAndRelease("#lead", contents: true)) as? String
        #expect(try await sideChatShown(in: webView, becoming: true) == true)

        _ = try await webView.evaluateJavaScript(Self.press("sideChat"))
        try await waitForMessages(recorder, ofType: "sideChatRequest", count: 1)
        let request = try #require(recorder.messages(ofType: "sideChatRequest").last)
        guard case .sideChatRequest(let text, let viewportRect)? = ReaderSelectionMessage(body: request) else {
            Issue.record("the press did not read as a side chat request: \(request)")
            return
        }
        #expect(text == selected)
        #expect(text.hasPrefix("Spatial biology data dramatically improves"))
        #expect((viewportRect?.width ?? 0) > 0)
        #expect((viewportRect?.minY ?? -1) >= 0)
        // The words stay selected, as Chat leaves them.
        #expect(try await webView.evaluateJavaScript("window.getSelection().isCollapsed") as? Bool == false)
        // No other action was taken for it.
        #expect(recorder.messages(ofType: "chatRequest").isEmpty)
        #expect(recorder.messages(ofType: "highlightRequest").isEmpty)
    }

    @Test("A side chat request with no words is not one")
    func sideChatRequestNeedsWords() {
        #expect(ReaderSelectionMessage(body: ["type": "sideChatRequest", "text": "  \n"]) == nil)
        let message = ReaderSelectionMessage(body: [
            "type": "sideChatRequest", "text": "matrix",
            "rect": ["top": 10, "left": 20, "right": 80, "bottom": 26],
        ])
        guard case .sideChatRequest(let text, let rect)? = message else {
            Issue.record("expected a side chat request")
            return
        }
        #expect(text == "matrix")
        #expect(rect == CGRect(x: 20, y: 10, width: 60, height: 16))
        #expect(message?.text == "matrix")
        #expect(message?.images.isEmpty == true)
    }

    // MARK: - The reader's own world

    /// Records what reaches the article reader's handler, and from which world.
    @MainActor
    private final class WorldRecorder: NSObject, WKScriptMessageHandler {
        var posts: [(world: String?, type: String)] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let type = (message.body as? [String: Any])?["type"] as? String ?? ""
            posts.append((message.world.name, type))
        }
    }

    @Test("The article reader's scripts post from a world of their own, which the publisher's script cannot reach")
    @MainActor
    func articleReaderHandlerIsOutOfThePagesReach() async throws {
        let recorder = WorldRecorder()
        let world = WebViewReader.scriptWorld
        let handler = WebViewReader.messageHandlerName
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, contentWorld: world, name: handler)
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewReader.selectionDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(Self.pageHTML, baseURL: URL(string: "https://reader.example/writings/pooled-screens"))
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.callAsyncJavaScript(
                "return window.foreverLMReaderUserSelectionInstalled === true && typeof window.foreverLMFlashPassage === 'function'",
                contentWorld: world
            ) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the reader scripts never installed in their world")

        // The publisher's script sees neither the handler nor the scripts,
        // so it cannot report a scroll that marks the article read.
        let pageSees = try await webView.evaluateJavaScript(
            "[typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handler)), typeof window.foreverLMFlashPassage]"
        ) as? [String]
        #expect(pageSees == ["undefined", "undefined"])
        let posted = try await webView.evaluateJavaScript(
            "(() => { try { window.webkit.messageHandlers.\(handler).postMessage({ type: 'scrollPosition', fraction: 1, reachedArticleEnd: true, userInitiated: true }); return 'posted'; } catch (e) { return 'refused'; } })()"
        ) as? String
        #expect(posted == "refused")

        // The reader's own scripts still hear the selection on the shared
        // page, and still reach the handler.
        _ = try await webView.evaluateJavaScript(Self.selectAndRelease("#lead", contents: true))
        for _ in 0..<60 where recorder.posts.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.posts.first?.type == "selection")
        #expect(recorder.posts.allSatisfy { $0.world == world.name })
        #expect(!recorder.posts.contains { $0.type == "scrollPosition" })

        // And the app's calls into them land in the same world.
        let found = await withCheckedContinuation { continuation in
            ReaderPassageFlash.flash("the question of which T cells are doing useful work", in: webView, world: world) {
                continuation.resume(returning: $0)
            }
        }
        #expect(found)
    }
}

#endif
