#if os(macOS)
import AppKit
import PDFKit
import WebKit

/// Prints the publisher's article page the reader has on screen to a paginated
/// PDF.
///
/// A paper in ForeverLM is a PDF. When a publisher serves the learner the
/// article's page but not the file — the download endpoint behind a bot check,
/// or a subscription that covers reading online only — the learner can ask the
/// reader to take the page as the paper (**Save Paper from Page**), and this
/// turns that page into the file the paper pipeline, the reader, CloudKit and
/// the phone expect. It only ever prints the reader's own web view: the
/// learner sees the page it prints, signed in as they are there.
///
/// The print path is used rather than `WKWebView.createPDF`: measured on
/// 2026-09-06, `createPDF` renders a Nature article as three 14,400-point
/// pages that PDFKit cannot page through, while the print operation paginates
/// to Letter and honours the publisher's print stylesheet (47 pages and the
/// full 13,700 words of a Nature Metabolism article, title and authors first).
@MainActor
enum PublisherPagePDFRenderer {
    enum Failure: LocalizedError {
        case viewHasNoWindow
        case printFailed
        case notAPDF

        var errorDescription: String? {
            switch self {
            case .viewHasNoWindow: return "The page is not on screen, so it cannot be printed."
            case .printFailed: return "Printing the publisher's page did not produce a file."
            case .notAPDF: return "Printing the publisher's page did not produce a PDF."
            }
        }
    }

    /// Hides site chrome while printing: navigation, footers, the cookie
    /// consent banner, share and metrics bars, and the publisher's own access
    /// panel. `position: static` keeps fixed banners from repeating on every
    /// page. The article's own header (title, authors) is kept. Scoped to
    /// print media so a live reader page looks the same after the print.
    static let printStyleSheet = """
    @media print {
      html { font-size: 13px !important; }
      body > header, header:not(article header):not(main header), [role=banner],
      nav, [role=navigation], footer, [role=contentinfo], aside, [role=complementary],
      [class*=cookie], [id*=cookie], [class*=consent], [id*=consent],
      [class*=banner], [class*=Banner], [class*=metrics], [class*=share],
      [class*=recommend], [class*=advert], [class*=Advert],
      .c-article-access, .c-reading-companion, .c-article-recommendations,
      .u-hide-print { display: none !important; }
      * { position: static !important; }
    }
    """

    /// US Letter in points; the reader's PDF view is sized for paper pages.
    static let paperSize = NSSize(width: 612, height: 792)
    static let pageMargin: CGFloat = 36

    // MARK: - Public

    /// Print a page the reader has already rendered, as the learner sees it.
    /// The print operation lays the page out through the view's window, so a
    /// view that is not on screen cannot be printed.
    static func printPDF(from webView: WKWebView) async throws -> Data {
        guard let window = webView.window else { throw Failure.viewHasNoWindow }
        try await installPrintStyleSheet(in: webView)
        return try await print(webView, in: window)
    }

    nonisolated static func pdfPageCount(of data: Data) -> Int {
        guard SourceService.looksLikePDFData(data), let document = PDFDocument(data: data) else { return 0 }
        return document.pageCount
    }

    // MARK: - Printing

    private static let styleElementID = "foreverlm-publisher-page-print-style"

    private static func installPrintStyleSheet(in webView: WKWebView) async throws {
        let encoded = try JSONEncoder().encode([printStyleSheet])
        let cssArrayLiteral = String(decoding: encoded, as: UTF8.self)
        let js = """
        (function() {
            var id = '\(styleElementID)';
            if (document.getElementById(id)) { return true; }
            var style = document.createElement('style');
            style.id = id;
            style.textContent = \(cssArrayLiteral)[0];
            (document.head || document.documentElement).appendChild(style);
            return true;
        })()
        """
        _ = try await webView.evaluateJavaScript(js)
        // Let the style attach before the operation snapshots the document.
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func print(_ webView: WKWebView, in window: NSWindow) async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-publisher-page-\(UUID().uuidString).pdf")
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { throw Failure.printFailed }
        info.paperSize = paperSize
        info.topMargin = pageMargin
        info.bottomMargin = pageMargin
        info.leftMargin = pageMargin
        info.rightMargin = pageMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(
            x: 0,
            y: 0,
            width: paperSize.width - 2 * pageMargin,
            height: paperSize.height - 2 * pageMargin
        )

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let completion = PrintCompletion(continuation)
            // `runModal(for:)` returns at once with no panel to show and reports
            // through the delegate later; the completion object is kept alive by
            // the retained context pointer until that call releases it.
            let context = Unmanaged.passRetained(completion).toOpaque()
            operation.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: context
            )
        }
        guard success else {
            try? FileManager.default.removeItem(at: outputURL)
            throw Failure.printFailed
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let data = try Data(contentsOf: outputURL)
        guard SourceService.looksLikePDFData(data) else { throw Failure.notAPDF }
        return data
    }

    private final class PrintCompletion: NSObject {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        @objc func printOperationDidRun(
            _ operation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            continuation?.resume(returning: success)
            continuation = nil
            if let contextInfo {
                Unmanaged<PrintCompletion>.fromOpaque(contextInfo).release()
            }
        }
    }
}
#endif
