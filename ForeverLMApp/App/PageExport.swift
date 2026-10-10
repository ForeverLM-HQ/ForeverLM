import AppKit
import UniformTypeIdentifiers
import WebKit

/// The page menu's **Export ▸** (docs/docs-design.md, "The page"): the page's
/// Markdown as it is stored, or the page as the editor draws it, as an HTML
/// file or a PDF. The HTML is the editor's own publication of the page
/// (`publicationHTML()` in the editor's script), with its pictures inside it,
/// so the file opens anywhere; the PDF is that HTML printed to Letter pages.
enum PageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case pdf
    case html

    var id: String { rawValue }

    /// The menu item.
    var menuTitle: String {
        switch self {
        case .markdown: return "Markdown…"
        case .pdf: return "PDF…"
        case .html: return "HTML…"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: return "doc.plaintext"
        case .pdf: return "doc.richtext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .html: return "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .html: return .html
        }
    }
}

/// One press of an Export item. A fresh value each time, so the same format
/// twice is heard twice.
struct PageExportRequest: Equatable {
    /// Where the text goes: a file the writer chooses, or the pasteboard
    /// (the page menu's Copy ▸).
    enum Delivery: Equatable {
        case save
        case copy
    }

    let id = UUID()
    let format: PageExportFormat
    var delivery: Delivery = .save
}

@MainActor
enum PageExport {
    enum Failure: LocalizedError {
        case pageDidNotLoad
        case printFailed

        var errorDescription: String? {
            switch self {
            case .pageDidNotLoad: return "The page could not be drawn for the PDF."
            case .printFailed: return "The page could not be printed to a PDF."
            }
        }
    }

    /// The file's suggested name: the page's title, without the characters
    /// a file name cannot hold.
    nonisolated static func fileName(for title: String, format: PageExportFormat) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Page" : cleaned).\(format.fileExtension)"
    }

    /// Asks where the file goes; nil when the learner cancels.
    static func chooseDestination(title: String, format: PageExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: title, format: format)
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Writes off the main thread.
    static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// The editor's publication HTML with the page's title as its title, and
    /// as its heading unless the body opens with one that says it already.
    nonisolated static func titledHTML(_ editorHTML: String, title: String, bodyOpensWithTitle: Bool) -> String {
        let escaped = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        var html = editorHTML.replacingOccurrences(of: "<title>Untitled Article</title>", with: "<title>\(escaped)</title>")
        if !bodyOpensWithTitle {
            html = html.replacingOccurrences(of: "<article>", with: "<article><h1>\(escaped)</h1>")
        }
        return html
    }

    /// Paper-sized type for the print: the publication's 19-pixel screen
    /// type reads large on a Letter page, and the column's own margins add to
    /// the page's.
    private static let printStyle = """
    @media print {
      body { font-size: 11.5pt !important; line-height: 1.55 !important; background: #fff !important; }
      article { max-width: none !important; padding: 0 !important; }
      img { max-width: 100% !important; break-inside: avoid; }
      h1, h2, h3, h4 { break-after: avoid; }
    }
    """

    /// The page printed to paginated Letter pages: drawn in a web view of its
    /// own, in light mode, in the hidden on-screen window the chat's browser
    /// uses (WebKit stops drawing a window entirely off screen), then printed
    /// as the reader prints a publisher's page (`PublisherPagePDFRenderer`).
    static func pdf(fromHTML html: String) async throws -> Data {
        let printable = html.replacingOccurrences(of: "</style>", with: "\(printStyle)</style>")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056), configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        let loading = PageExportLoad()
        webView.navigationDelegate = loading
        ChatBrowserHostWindow.shared.host(webView)
        defer {
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        guard await loading.load(printable, in: webView) else { throw Failure.pageDidNotLoad }
        do {
            return try await PublisherPagePDFRenderer.printPDF(from: webView)
        } catch {
            throw Failure.printFailed
        }
    }
}

/// Waits for one HTML string to finish loading, or fail, in a web view.
@MainActor
private final class PageExportLoad: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ html: String, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
            // A page that never reports back still ends the wait.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(false)
            }
        }
    }

    private func finish(_ loaded: Bool) {
        continuation?.resume(returning: loaded)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}
