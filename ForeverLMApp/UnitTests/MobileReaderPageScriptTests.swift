import Foundation
import Testing
import WebKit
@testable import ForeverLM

/// The phone reader's page scripts in a real WebKit page: a highlight paints the
/// text it was made on, and on a whole-book page a highlight or a selection
/// belongs to its own chapter, anchored in that chapter's text.
@Suite("Mobile Reader Page Scripts")
struct MobileReaderPageScriptTests {
    /// Inline markup the way an EPUB chapter has it: a word split across a span,
    /// italics inside a phrase, the same name twice.
    private static let chapterOne = """
        <h1>Proloog</h1>
        <p>Op 19 mei 2004 werd <span class="ff">Car</span>la Reed, een <i>kleuterjuf</i> van dertig uit Ipswich, wakker.</p>
        <p>Later die maand zag <b>Carla</b> haar arts weer.</p>
        """
    private static let chapterTwo = """
        <h1>Een suppuratie van het bloed</h1>
        <p>In Edinburgh zag een arts wat later leukemie zou heten; ook <em>Carla</em> kreeg die naam te horen.</p>
        """

    @MainActor
    private func loadedPage(_ html: String, book: Bool) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if book {
            configuration.userContentController.addUserScript(WKUserScript(
                source: MobileBookPageScript.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780), configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
        // The reader's own stylesheet, not the blank page WebKit starts on.
        let loaded = "document.readyState === 'complete' && document.head.innerHTML.indexOf('--flm-body-size') >= 0"
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript(
                book ? "\(loaded) && typeof window.foreverlmBook === 'object'" : loaded
            ) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the page never loaded")
        _ = try await webView.evaluateJavaScript(MobileReaderPageScript.highlightPainter + "; true")
        return webView
    }

    @MainActor
    private func run(_ webView: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        let data = try #require((value as? String)?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Paints `items` and says, for each, the text painted and the element it
    /// starts in.
    private static let paintScript = """
        window.foreverlmApplyHighlights(items);
        const painted = {};
        for (const entry of window.__foreverlmRanges) {
          const host = entry.range.startContainer.parentElement;
          const chapter = host.closest('[data-flm-chapter]');
          painted[entry.id] = { text: entry.range.toString(), tag: host.tagName, chapter: chapter ? chapter.getAttribute('data-flm-chapter') : null };
        }
        return JSON.stringify(painted);
        """

    private static func mark(_ id: String, exact: String, offset: Int, sourceID: String = "source") -> [String: Any] {
        [
            "id": id,
            "sourceID": sourceID,
            "quote": exact,
            "color": "yellow",
            "anchor": ["exact": exact, "prefix": "", "suffix": "", "offset": offset],
        ]
    }

    @Test("A highlight paints the text it was made on, across inline markup")
    @MainActor
    func highlightPaintsItsOwnText() async throws {
        let webView = try await loadedPage(
            MobileReaderText.documentHTML(bodyHTML: Self.chapterOne, fontScale: 1, truncated: false),
            book: false
        )
        // Before 2026-09-28 the phone joined text nodes with a space it never
        // counted back: "Car"+"la" was not found, and a passage followed by a
        // space in its own text node found no end.
        let painted = try await run(webView, Self.paintScript, ["items": [
            Self.mark("split", exact: "Carla Reed", offset: 28),
            Self.mark("phrase", exact: "kleuterjuf van dertig", offset: 44),
            Self.mark("second", exact: "Carla", offset: 107),
        ]])
        #expect((painted["split"] as? [String: Any])?["text"] as? String == "Carla Reed")
        #expect((painted["phrase"] as? [String: Any])?["text"] as? String == "kleuterjuf van dertig")
        let second = painted["second"] as? [String: Any]
        #expect(second?["text"] as? String == "Carla")
        #expect(second?["tag"] as? String == "B")
    }

    /// The page keeps the soft hyphens it was written with; the stored text has
    /// none (docs/source-content-integrity.md, "Soft hyphens are not text").
    @Test("A highlight from the stored text paints across the page's soft hyphens, and a selection over them anchors without them")
    @MainActor
    func softHyphensAreNoText() async throws {
        let webView = try await loadedPage(
            MobileReaderText.documentHTML(
                bodyHTML: "<p>Mito&shy;chondrial genes for regeneration-&shy;associated life&shy;span studies.</p>",
                fontScale: 1,
                truncated: false
            ),
            book: false
        )
        let painted = try await run(webView, Self.paintScript, ["items": [
            Self.mark("stored", exact: "regeneration-associated lifespan", offset: 24),
        ]])
        #expect((painted["stored"] as? [String: Any])?["text"] as? String == "regeneration-\u{00AD}associated life\u{00AD}span")

        let result = try await run(webView, """
            const node = document.querySelector('p').firstChild;
            const at = node.nodeValue.indexOf('life');
            const range = document.createRange();
            range.setStart(node, at); range.setEnd(node, node.nodeValue.indexOf('studies') + 'studies'.length);
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return JSON.stringify({ anchor: eval(anchorScript) });
            """, ["anchorScript": MobileReaderPageScript.selectionAnchor])
        let anchor = try #require(result["anchor"] as? [String: Any])
        #expect(anchor["quote"] as? String == "lifespan studies")
        // Where "lifespan" starts in "Mitochondrial genes for regeneration-associated lifespan studies."
        #expect((anchor["offset"] as? NSNumber)?.intValue == "Mitochondrial genes for regeneration-associated ".count)
    }

    @MainActor
    private func bookPage() async throws -> WKWebView {
        let webView = try await loadedPage(MobileReaderText.bookDocumentHTML(fontScale: 1), book: true)
        let steps = [
            MobileBookPageOperation.insert(
                MobileBookPage.Chapter(id: "chapter-1", bodyHTML: MobileReaderText.bookChapterBodyHTML(readerBodyHTML: Self.chapterOne, plainText: ""), isBookStart: true),
                at: .end
            ),
            .insert(
                MobileBookPage.Chapter(id: "chapter-2", bodyHTML: MobileReaderText.bookChapterBodyHTML(readerBodyHTML: nil, plainText: "Een suppuratie\n\nIn Edinburgh zag een arts wat later leukemie zou heten; ook Carla kreeg die naam te horen."), isBookStart: false),
                at: .end
            ),
        ].map { $0.payload(fontSize: MobileReaderText.bodyFontSize(for:)) }
        let held = try await webView.callAsyncJavaScript(
            "return await window.foreverlmBook.apply(steps);",
            arguments: ["steps": steps],
            in: nil,
            contentWorld: .page
        ) as? [String]
        #expect(held == ["chapter-1", "chapter-2"])
        return webView
    }

    @Test("On a book page each chapter is its own section, and a highlight resolves within its chapter")
    @MainActor
    func bookHighlightsStayInTheirChapter() async throws {
        let webView = try await bookPage()
        let sections = try await run(webView, """
            return JSON.stringify({ sections: Array.from(document.querySelectorAll('section.flm-book-chapter')).map(s => s.getAttribute('data-flm-chapter')) });
            """)
        #expect(sections["sections"] as? [String] == ["chapter-1", "chapter-2"])

        // Chapter 2's "Carla" sits at 75 in chapter 2's own text; over the whole
        // page an offset of 75 would pick chapter 1's first Carla (at 28).
        // Chapter 1's second Carla sits at 107 in chapter 1.
        let painted = try await run(webView, Self.paintScript, ["items": [
            Self.mark("two", exact: "Carla", offset: 75, sourceID: "chapter-2"),
            Self.mark("one", exact: "Carla", offset: 107, sourceID: "chapter-1"),
            Self.mark("elsewhere", exact: "Carla", offset: 0, sourceID: "chapter-9"),
        ]])
        #expect((painted["two"] as? [String: Any])?["chapter"] as? String == "chapter-2")
        #expect((painted["one"] as? [String: Any])?["chapter"] as? String == "chapter-1")
        #expect((painted["one"] as? [String: Any])?["tag"] as? String == "B")
        #expect(painted["elsewhere"] == nil)
    }

    @Test("A selection on a book page is anchored in its chapter's own text and names the chapter")
    @MainActor
    func bookSelectionAnchorsInItsChapter() async throws {
        let webView = try await bookPage()
        let result = try await run(webView, """
            const normalize = v => v.replace(/\\s+/g, ' ').trim();
            const section = document.querySelector('[data-flm-chapter="chapter-2"]');
            const walker = document.createTreeWalker(section, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) { if (node.nodeValue.includes('leukemie')) break; }
            const at = node.nodeValue.indexOf('leukemie');
            const range = document.createRange();
            range.setStart(node, at); range.setEnd(node, at + 'leukemie'.length);
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return JSON.stringify({ anchor: eval(anchorScript), chat: eval(chatScript), expected: normalize(section.innerText).indexOf('leukemie') });
            """, ["anchorScript": MobileReaderPageScript.selectionAnchor, "chatScript": MobileReaderPageScript.selection])
        let anchor = try #require(result["anchor"] as? [String: Any])
        #expect(anchor["chapter"] as? String == "chapter-2")
        #expect(anchor["quote"] as? String == "leukemie")
        #expect((anchor["offset"] as? NSNumber)?.intValue == (result["expected"] as? NSNumber)?.intValue)
        #expect((anchor["prefix"] as? String)?.contains("Proloog") == false)
        #expect((result["chat"] as? [String: Any])?["chapter"] as? String == "chapter-2")
    }
}
