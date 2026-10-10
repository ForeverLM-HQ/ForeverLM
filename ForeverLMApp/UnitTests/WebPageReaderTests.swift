import Foundation
import Testing
@testable import ForeverLM

@Suite("Web Page Reader")
struct WebPageReaderTests {
    @Test("An article page reads as its story, without chrome or scripts")
    func articleRegionWins() {
        let story = String(repeating: "The company chose primary CD34+ cells and RNA-seq as its readout. ", count: 20)
        let html = """
        <!doctype html><html><head><title>Cellarity picks its assay | TechBio Weekly</title>
        <meta property="og:title" content="Cellarity picks its assay">
        <script>window.track = function(){ return "never shown" }</script>
        <style>.a{color:red}</style></head>
        <body><nav><a href="/">Home</a><a href="/about">About</a></nav>
        <header><h1>TechBio Weekly</h1></header>
        <main><article><h2>Cellarity picks its assay</h2><p>\(story)</p><p>Second &amp; final paragraph.</p></article></main>
        <aside>Related: ten other stories you should read</aside>
        <footer>© 2026 TechBio Weekly</footer></body></html>
        """
        let page = try! WebPageReader.page(from: Data(html.utf8), contentType: "text/html; charset=utf-8", url: "https://example.org/story")

        #expect(page.kind == "html")
        #expect(page.title == "Cellarity picks its assay")
        #expect(page.text.contains("## Cellarity picks its assay"))
        #expect(page.text.contains("primary CD34+ cells"))
        #expect(page.text.contains("Second & final paragraph."))
        #expect(!page.text.contains("never shown"))
        #expect(!page.text.contains("Related: ten other stories"))
        #expect(!page.text.contains("© 2026"))
        #expect(!page.text.contains("Home"))
    }

    @Test("A short main region does not hide the rest of the page")
    func tinyMainRegionIsIgnored() {
        let body = String(repeating: "Body paragraph with real content. ", count: 40)
        let html = "<html><head><title>T</title></head><body><main><p>Sign in</p></main><div><p>\(body)</p></div></body></html>"
        let page = try! WebPageReader.page(from: Data(html.utf8), contentType: "text/html", url: "https://example.org/")
        #expect(page.text.contains("Body paragraph with real content."))
    }

    @Test("Plain text and unsupported bodies are handled explicitly")
    func nonHTMLBodies() throws {
        let text = try WebPageReader.page(from: Data("hello\nworld".utf8), contentType: "text/plain", url: "https://example.org/notes.txt")
        #expect(text.kind == "text")
        #expect(text.text == "hello\nworld")
        #expect(text.title == "notes.txt")

        #expect(throws: WebPageReader.ReadError.unsupportedContent("image/png")) {
            try WebPageReader.page(from: Data([0x89, 0x50]), contentType: "image/png", url: "https://example.org/a.png")
        }
        #expect(throws: WebPageReader.ReadError.unreadable) {
            try WebPageReader.page(from: Data("<html><body><script>x()</script></body></html>".utf8), contentType: "text/html", url: "https://example.org/")
        }
    }

    @Test("Long pages are returned one window at a time with a continuation offset")
    func windowing() {
        let text = String(repeating: "abcdefghij", count: 2_000) // 20,000 characters
        let page = WebPageReader.Page(url: "https://example.org/long", title: "Long", text: text, kind: "html")

        let first = WebPageReader.toolResult(for: page, offset: 0)
        #expect(first.hasPrefix("Title: Long\nURL: https://example.org/long\nContent: html, 20000 characters, showing 1–12000"))
        #expect(first.contains("offset 12000 for the next part"))

        let second = WebPageReader.toolResult(for: page, offset: 12_000)
        #expect(second.contains("showing 12001–20000"))
        #expect(!second.contains("Continues."))
        #expect(second.hasSuffix(String(repeating: "abcdefghij", count: 800)))

        let short = WebPageReader.toolResult(for: WebPageReader.Page(url: "u", title: "", text: "tiny", kind: "text"), offset: 0)
        #expect(short == "Title: (untitled)\nURL: u\nContent: text, 4 characters\n\ntiny")
    }
}
