import PDFKit
import UIKit
import WebKit
import XCTest
@testable import ForeverLM

/// Find inside a source: the PDF performer walks PDFKit's matches with wrap and
/// says where it is, the web performer does the same over WebKit's text search
/// and leaves no match on screen when the bar closes, and both fall silent on
/// an empty query.
@MainActor
final class MobileReaderFindInteractionTests: XCTestCase {
    func testPDFFindStepsThroughMatchesAndWraps() async throws {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let document = try XCTUnwrap(PDFDocument(data: Self.pdf(pages: [
            "Mitochondria are organelles. Mitochondria divide by fission.",
            "The mitochondria of a myocyte take up calcium.",
        ])))
        pdfView.document = document
        let performer = MobilePDFFindPerformer(pdfView: pdfView)

        var status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 3")
        XCTAssertEqual(pdfView.currentSelection?.pages.first.map(document.index(for:)), 0)

        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "2 of 3")
        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "3 of 3")
        XCTAssertEqual(pdfView.currentSelection?.pages.first.map(document.index(for:)), 1)

        // Wraps in both directions.
        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 3")
        status = await performer.find("mitochondria", backwards: true)
        XCTAssertEqual(status, "3 of 3")

        // A new query starts over; a missing one says so and clears the match.
        status = await performer.find("Calcium", backwards: false)
        XCTAssertEqual(status, "1 of 1")
        status = await performer.find("ribosome", backwards: false)
        XCTAssertEqual(status, "No matches")
        XCTAssertNil(pdfView.currentSelection)

        // No query, no status, no selection.
        _ = await performer.find("calcium", backwards: false)
        status = await performer.find("  ", backwards: false)
        XCTAssertEqual(status, "")
        XCTAssertNil(pdfView.currentSelection)
    }

    func testPDFFindWithoutDocumentReportsNoMatches() async {
        let pdfView = PDFView(frame: .zero)
        let performer = MobilePDFFindPerformer(pdfView: pdfView)
        let status = await performer.find("anything", backwards: false)
        XCTAssertEqual(status, "No matches")
    }

    func testWebFindStepsThroughTheLoadedDocumentsMatchesAndWraps() async throws {
        let (webView, window) = try await loadedReader()
        defer { window.isHidden = true }
        let performer = MobileWebFindPerformer(webView: webView)

        var status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 2")
        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "2 of 2")

        // Wraps in both directions.
        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 2")
        status = await performer.find("mitochondria", backwards: true)
        XCTAssertEqual(status, "2 of 2")

        status = await performer.find("Warburg", backwards: false)
        XCTAssertEqual(status, "1 of 1")
        status = await performer.find("ribosome", backwards: false)
        XCTAssertEqual(status, "No matches")
        status = await performer.find("", backwards: false)
        XCTAssertEqual(status, "")
    }

    /// WebKit shows the match as the page's selection. Closing the bar takes it
    /// off the screen, and the same word found again shows again. The content
    /// view's selected range is the selection UIKit draws; after
    /// `WKWebView.find` it kept the match whatever script cleared the page's.
    func testWebFindClearsTheShownMatchAndShowsItAgain() async throws {
        let (webView, window) = try await loadedReader()
        defer { window.isHidden = true }
        let performer = MobileWebFindPerformer(webView: webView)
        let shown = try XCTUnwrap(webView.scrollView.subviews.first { $0 is UITextInput } as? UITextInput)

        var status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 2")
        await Self.waitUntil { shown.selectedTextRange != nil }
        XCTAssertNotNil(shown.selectedTextRange, "the match is shown")

        performer.clearFind()
        await Self.waitUntil { shown.selectedTextRange == nil }
        XCTAssertNil(shown.selectedTextRange, "closing the bar takes the match off the screen")

        status = await performer.find("mitochondria", backwards: false)
        XCTAssertEqual(status, "1 of 2")
        await Self.waitUntil { shown.selectedTextRange != nil }
        XCTAssertNotNil(shown.selectedTextRange, "the same word shows again")
    }

    func testFindStateClosesCleanly() async {
        let state = MobileReaderFindState()
        let performer = RecordingPerformer()
        state.performer = performer

        state.show()
        XCTAssertTrue(state.isPresented)
        state.query = "mito"
        state.search()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(performer.queries, ["mito"])
        XCTAssertEqual(state.statusText, "1 of 1")

        state.close()
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.statusText, "")
        XCTAssertEqual(performer.clearCount, 1)
    }

    // MARK: - Fixtures

    /// The text reader on a short article, in a window so WebKit lays it out
    /// and reports its selection.
    private func loadedReader() async throws -> (MobileReaderWKWebView, UIWindow) {
        let webView = MobileReaderWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: WKWebViewConfiguration()
        )
        let window = UIWindow(frame: webView.frame)
        window.addSubview(webView)
        window.isHidden = false

        let html = MobileReaderText.html(
            body: "The Warburg effect describes aerobic glycolysis.\n\nMitochondria stay involved; mitochondria always are.",
            sourceType: "article",
            sourceTitle: "Warburg",
            fontScale: 1,
            truncated: false
        )
        let loaded = expectation(description: "document loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        webView.navigationDelegate = nil
        return (webView, window)
    }

    /// The selection reaches UIKit a moment after the page changes it.
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func pdf(pages: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14)]
                NSAttributedString(string: text, attributes: attributes)
                    .draw(in: bounds.insetBy(dx: 72, dy: 72))
            }
        }
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    private final class RecordingPerformer: MobileReaderFindPerformer {
        var queries: [String] = []
        var clearCount = 0
        func find(_ query: String, backwards: Bool) async -> String {
            queries.append(query)
            return "1 of 1"
        }
        func clearFind() { clearCount += 1 }
    }
}
