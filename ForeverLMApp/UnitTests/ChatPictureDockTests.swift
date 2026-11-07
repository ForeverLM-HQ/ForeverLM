import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// A chat's picture popped out beside the conversation: the picture and the
/// figure's Open beside button.
@Suite("Chat picture beside the chat")
struct ChatPictureDockTests {
    private static let token = "foreverlm://image/ch3/page/9"
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    // MARK: - The picture

    @Test("Two openings of one picture are two pictures; the bytes are never compared")
    func openingsAreIdentified() {
        let data = Data(base64Encoded: Self.pngBase64)!
        let first = DockedChatPicture(data: data, mediaType: "image/png", title: "Figure 1")
        let second = DockedChatPicture(data: data, mediaType: "image/png", title: "Figure 1")
        #expect(first == first)
        #expect(first != second)
    }

    // MARK: - The button

    /// Records what the page posts on `openSourceImageBeside`.
    @MainActor
    private final class BesideRecorder: NSObject, WKScriptMessageHandler {
        var opens: [(token: String, alt: String)] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
            opens.append((token, body["alt"] as? String ?? ""))
        }
    }

    @Test("A resolved figure offers Open beside next to Copy, and its click posts the token and caption")
    @MainActor
    func figureOffersOpenBeside() async throws {
        let recorder = BesideRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "openSourceImageBeside")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        ChatMarkdownView.loadTemplate(into: webView)
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript("typeof window.setSourceImages === 'function'") as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready)
        let markdown = String(data: try JSONEncoder().encode("![Figure 2a](\(Self.token))"), encoding: .utf8)!
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(markdown)); true")

        let beside = "document.querySelector('figure.source-image-figure .source-image-beside')"
        // Nothing to pop out until the bytes are here.
        #expect(try await webView.evaluateJavaScript("\(beside) === null") as? Bool == true)

        let json = try #require(await ChatMarkdownView.sourceImageLookupJSON(
            tokens: [Self.token],
            sourceImageForToken: { _ in
                ChatSourceImage(data: Data(base64Encoded: Self.pngBase64)!, mediaType: "image/png")
            }
        ))
        _ = try await webView.evaluateJavaScript("window.setSourceImages(\(json)); true")
        #expect(try await webView.evaluateJavaScript("\(beside).textContent") as? String == "Open beside")
        #expect(try await webView.evaluateJavaScript(
            "document.querySelectorAll('.source-image-actions .source-image-beside').length"
        ) as? Int == 1)

        _ = try await webView.evaluateJavaScript("\(beside).click(); true")
        for _ in 0..<50 where recorder.opens.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.opens.count == 1)
        #expect(recorder.opens.first?.token == Self.token)
        #expect(recorder.opens.first?.alt == "Figure 2a")

        // Drawing the same picture again adds no second button.
        _ = try await webView.evaluateJavaScript("window.setSourceImages(\(json)); true")
        #expect(try await webView.evaluateJavaScript(
            "document.querySelectorAll('.source-image-actions .source-image-beside').length"
        ) as? Int == 1)
    }
}
