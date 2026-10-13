#if os(macOS)
import Foundation
import UniformTypeIdentifiers
import WebKit

/// How the Reader's web view reads an EPUB book kept as one file
/// (`EPUBBookFiles`): from the book's file, never from files on disk.
///
/// A book's entries keep the addresses they had when the book was unpacked
/// (`…/Books/<folder>/Chapters/<entry>`), and the web view asks for them under
/// this scheme at the same paths: `foreverlm-book://book/…/Chapters/<entry>`.
/// So a chapter's relative links, pictures, stylesheets and fonts resolve as
/// they did, and the page assembled for a book (`EPUBBookDocument`) is served
/// from memory at the path it was once written to. Only entries of a book's
/// file and pages registered here are served; any other path is refused.
enum EPUBBookScheme {
    static let name = "foreverlm-book"
    private static let host = "book"

    /// The address `path` (absolute) has under the scheme.
    static func url(forPath path: String, isDirectory: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = name
        components.host = host
        components.path = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        return components.url
    }

    /// The path a URL under the scheme names, nil for any other URL.
    static func path(of url: URL) -> String? {
        guard url.scheme?.lowercased() == name, url.host == host else { return nil }
        return url.path
    }

    /// A document the Reader shows from its own disk or from a book's file:
    /// what reading position and notes belong to, as opposed to a web page a
    /// link took the view to.
    static func isLocalDocument(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.isFileURL || url.scheme?.lowercased() == name
    }

    // MARK: Pages

    private static let pagesLock = NSLock()
    private nonisolated(unsafe) static var pages: [String: Data] = [:]
    private nonisolated(unsafe) static var pageOrder: [String] = []
    /// A few books open at once, each a page of every chapter.
    private static let pagesKept = 4

    /// Serves `html` at `path`: a book's assembled page, which a book still
    /// unpacked had written to its `Chapters` folder.
    static func register(page html: String, atPath path: String) {
        pagesLock.lock()
        defer { pagesLock.unlock() }
        pages[path] = Data(html.utf8)
        pageOrder.removeAll { $0 == path }
        pageOrder.append(path)
        while pageOrder.count > pagesKept {
            pages[pageOrder.removeFirst()] = nil
        }
    }

    private static func page(atPath path: String) -> Data? {
        pagesLock.lock()
        defer { pagesLock.unlock() }
        return pages[path]
    }

    /// What the scheme answers for `path`: a registered page, else an entry of
    /// a book kept as one file. Nil for anything else.
    static func response(forPath path: String) -> (data: Data, mimeType: String)? {
        if let page = page(atPath: path) { return (page, "text/html") }
        guard EPUBBookFiles.location(ofPath: path) != nil,
              let data = EPUBBookFiles.contents(atPath: path) else { return nil }
        return (data, mimeType(forPath: path))
    }

    static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "xhtml", "xht": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    // MARK: The handler

    static let handler = Handler()

    /// Reads off the main thread and answers on it; a task WebKit stopped
    /// meanwhile is left unanswered, as WebKit requires.
    final class Handler: NSObject, WKURLSchemeHandler {
        private var stopped = Set<ObjectIdentifier>()

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            let task = urlSchemeTask
            let id = ObjectIdentifier(task)
            stopped.remove(id)
            guard let url = task.request.url, let path = EPUBBookScheme.path(of: url) else {
                task.didFailWithError(URLError(.unsupportedURL))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = EPUBBookScheme.response(forPath: path)
                // The handler lives as long as the app (`handler`).
                DispatchQueue.main.async {
                    guard self.stopped.remove(id) == nil else { return }
                    guard let answer else {
                        task.didFailWithError(URLError(.fileDoesNotExist))
                        return
                    }
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": answer.mimeType,
                            "Content-Length": "\(answer.data.count)",
                        ]
                    ) ?? URLResponse(url: url, mimeType: answer.mimeType, expectedContentLength: answer.data.count, textEncodingName: nil)
                    task.didReceive(response)
                    task.didReceive(answer.data)
                    task.didFinish()
                }
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            stopped.insert(ObjectIdentifier(urlSchemeTask))
        }
    }
}
#endif
