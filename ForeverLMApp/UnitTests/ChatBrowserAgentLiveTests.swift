import Foundation
import Network
import Testing
@testable import ForeverLM

/// The chat's Browser agent against a real WebKit view in the hidden host
/// window, served a page by a listener in this process: open, outline with
/// handles, click a handle, click a point on a canvas, type and submit,
/// press a key, scroll, screenshot.
@Suite("Chat browser agent, live")
struct ChatBrowserAgentLiveTests {
    /// A one-port HTTP server that answers every request from a fixed table.
    final class PageServer: @unchecked Sendable {
        private let listener: NWListener
        private(set) var port: UInt16 = 0
        private let pages: [String: String]
        private let queue = DispatchQueue(label: "chat-browser-page-server")

        init(pages: [String: String]) throws {
            self.pages = pages
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            let ready = DispatchSemaphore(value: 0)
            let box = PortBox()
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    box.port = listener.port?.rawValue ?? 0
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            port = box.port
        }

        private final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let path = target.split(separator: "?").first.map(String.init) ?? "/"
                let body = self.pages[path].map { $0.replacingOccurrences(of: "{{query}}", with: target) }
                let response: String
                if let body {
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                } else {
                    response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                }
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    static let home = """
    <html><head><title>Agent test home</title></head>
    <body style="margin:0;font:16px sans-serif">
    <h1>Example heading</h1>
    <p>A paragraph of ordinary text on the page.</p>
    <a id="next" href="/next">Go to the next page</a>
    <form action="/search" method="get"><input name="q" placeholder="Search here" aria-label="Search box"></form>
    <button id="toggle" onclick="document.getElementById('status').textContent='button was clicked'">Toggle status</button>
    <div id="status">status: untouched</div>
    <canvas id="c" width="300" height="200" style="display:block;background:#eee"></canvas>
    <div id="keys">keys:</div>
    <div style="height:3000px">tall spacer</div>
    <p id="bottom">The very bottom of the page.</p>
    <script>
      document.getElementById('c').addEventListener('mousedown', e => { document.getElementById('status').textContent = 'canvas clicked at ' + Math.round(e.offsetX) + ',' + Math.round(e.offsetY); });
      document.addEventListener('keydown', e => { document.getElementById('keys').textContent += ' ' + e.key; });
    </script>
    </body></html>
    """

    static let next = """
    <html><head><title>Next page</title></head><body><h1>You made it to the next page</h1><a href="/">Back home</a></body></html>
    """

    static let search = """
    <html><head><title>Search results</title></head><body><h1>Results</h1><p id="q">{{query}}</p></body></html>
    """

    @Test("The agent opens, reads, clicks, types, presses, scrolls and pictures a real page")
    @MainActor
    func drivesARealPage() async throws {
        let server = try PageServer(pages: ["/": Self.home, "/next": Self.next, "/search": Self.search])
        defer { server.stop() }
        try #require(server.port != 0)
        let base = "http://127.0.0.1:\(server.port)"
        // The pages here run one synchronous handler each and are served
        // in-process, so the production 0.6 s settle after every step (on
        // top of the 150 ms it always waits before checking for a
        // navigation) was pure idle time: nine steps of it made this a
        // seven-second test.
        let agent = StudioChatBrowserAgent(settleDelay: 0.15)
        var previews = 0

        // Nothing is open yet.
        let early = await agent.run(tool: "browser_read_page", arguments: [:]) { _ in }
        #expect(early.isError)
        #expect(early.text.contains("browser_open"))
        #expect(!agent.hasTab)

        // Open: title, URL, outline with handles, a preview for the row.
        let opened = await agent.run(tool: "browser_open", arguments: ["url": "\(base)/"]) { _ in previews += 1 }
        #expect(!opened.isError, Comment(rawValue: opened.text))
        #expect(opened.text.contains("Agent test home"))
        #expect(opened.text.contains("# Example heading"))
        #expect(opened.text.contains("A paragraph of ordinary text"))
        #expect(opened.text.contains("link \"Go to the next page\" → \(base)/next"))
        #expect(opened.text.contains("text field \"Search box\""))
        #expect(opened.text.contains("[canvas 300×200"))
        #expect(opened.preview != nil)
        #expect(previews == 1)
        #expect(agent.hasTab)

        // An unknown profile is refused by name, with the list.
        let badProfile = await agent.run(tool: "browser_open", arguments: ["url": "\(base)/", "profile": "Nobody"]) { _ in }
        #expect(badProfile.isError)
        #expect(badProfile.text.contains("Library"))

        // Read with a query narrows to the matching lines.
        let read = await agent.run(tool: "browser_read_page", arguments: ["query": "next page"]) { _ in }
        #expect(!read.isError)
        #expect(read.text.contains("Go to the next page"))
        #expect(!read.text.contains("Example heading"))
        let linkRef = try #require(Self.ref(inLineContaining: "Go to the next page", of: read.text))

        // A click on a handle: the button changes the page without navigating.
        let full = await agent.run(tool: "browser_read_page", arguments: [:]) { _ in }
        let buttonRef = try #require(Self.ref(inLineContaining: "Toggle status", of: full.text))
        let toggled = await agent.run(tool: "browser_click", arguments: ["ref": buttonRef]) { _ in }
        #expect(!toggled.isError, Comment(rawValue: toggled.text))
        #expect(toggled.text.contains("Still on"))
        #expect(toggled.text.contains("button was clicked"))

        // A click at a point lands on the canvas, which has no handle.
        let canvasLine = try #require(full.text.split(separator: "\n").first { $0.contains("[canvas") })
        let origin = try #require(Self.point(in: String(canvasLine)))
        let onCanvas = await agent.run(tool: "browser_click", arguments: ["x": origin.x + 50, "y": origin.y + 40]) { _ in }
        #expect(!onCanvas.isError, Comment(rawValue: onCanvas.text))
        #expect(onCanvas.text.contains("canvas clicked at 50,40"), Comment(rawValue: onCanvas.text))

        // A key press reaches the page's handler.
        let pressed = await agent.run(tool: "browser_press_key", arguments: ["key": "ArrowRight", "times": 2]) { _ in }
        #expect(!pressed.isError, Comment(rawValue: pressed.text))
        #expect(pressed.text.contains("keys: ArrowRight ArrowRight"), Comment(rawValue: pressed.text))

        // Scrolling to the bottom brings the last paragraph into view.
        let scrolled = await agent.run(tool: "browser_scroll", arguments: ["direction": "bottom"]) { _ in }
        #expect(!scrolled.isError)
        #expect(scrolled.text.contains("The very bottom of the page"))
        #expect(!scrolled.text.contains("Example heading"))

        // A screenshot is a PNG for the model and a stored picture for the learner.
        let shot = await agent.run(tool: "browser_screenshot", arguments: ["caption": "Home page"]) { _ in }
        #expect(!shot.isError, Comment(rawValue: shot.text))
        #expect(shot.text.contains("![Home page](foreverlm://image/generated/"))
        let png = try #require(shot.screenshot)
        #expect(png.mediaType == "image/png")
        #expect(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(png.data.count > 2_000)

        // Typing into the field and submitting navigates to the results page.
        let fresh = await agent.run(tool: "browser_read_page", arguments: ["query": "Search box"]) { _ in }
        let fieldRef = try #require(Self.ref(inLineContaining: "Search box", of: fresh.text))
        let typed = await agent.run(tool: "browser_type", arguments: ["ref": fieldRef, "text": "hello", "submit": true]) { _ in }
        #expect(!typed.isError, Comment(rawValue: typed.text))
        #expect(typed.text.contains("navigated to"), Comment(rawValue: typed.text))
        #expect(typed.text.contains("/search?q=hello"), Comment(rawValue: typed.text))

        // Back home, and a handle click navigates.
        _ = await agent.run(tool: "browser_open", arguments: ["url": "\(base)/"]) { _ in }
        let again = await agent.run(tool: "browser_read_page", arguments: ["query": "next page"]) { _ in }
        let ref = try #require(Self.ref(inLineContaining: "Go to the next page", of: again.text))
        #expect(ref == linkRef)
        let navigated = await agent.run(tool: "browser_click", arguments: ["ref": ref]) { _ in }
        #expect(!navigated.isError, Comment(rawValue: navigated.text))
        #expect(navigated.text.contains("navigated to"), Comment(rawValue: navigated.text))
        #expect(navigated.text.contains("You made it to the next page"))

        // A stale handle is refused, not clicked blind.
        let stale = await agent.run(tool: "browser_click", arguments: ["ref": "ref_999"]) { _ in }
        #expect(stale.isError)
    }

    private static func ref(inLineContaining needle: String, of text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("[ref_") && $0.contains(needle) }),
              let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close else { return nil }
        let candidate = String(line[line.index(after: open)..<close])
        return candidate.hasPrefix("ref_") ? candidate : nil
    }

    /// The `(x, y)` the outline prints for a canvas or frame.
    private static func point(in line: String) -> (x: Double, y: Double)? {
        guard let open = line.range(of: "at ("), let close = line[open.upperBound...].firstIndex(of: ")") else { return nil }
        let parts = line[open.upperBound..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return (x, y)
    }
}
