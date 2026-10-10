import Foundation
import Testing
@testable import ForeverLM

@Suite("Convert to Google Doc")
struct GoogleDocConversionTests {
    // MARK: - Markdown to HTML

    @Test("Headings, paragraphs, emphasis, lists, links, code, quotes, rules and tables render as HTML")
    func markdownGrammarRenders() {
        let markdown = """
        # Title

        Some *emphasis* and **strong** text with `code` and a [link](https://example.com).

        - one
        - two

        1. first
        2. second

        > quoted

        ```swift
        let x = "<b>"
        ```

        ---

        | A | B |
        |---|---|
        | 1 | 2 |
        """

        let html = MarkdownHTML.body(markdown)

        #expect(html == """
        <h1>Title</h1>
        <p>Some <em>emphasis</em> and <strong>strong</strong> text with <code>code</code> and a <a href="https://example.com">link</a>.</p>
        <ul>
        <li>one</li>
        <li>two</li>
        </ul>
        <ol>
        <li>first</li>
        <li>second</li>
        </ol>
        <blockquote>
        <p>quoted</p>
        </blockquote>
        <pre><code class="language-swift">let x = &quot;&lt;b&gt;&quot;</code></pre>
        <hr>
        <table>
        <thead>
        <tr><th>A</th><th>B</th></tr>
        </thead>
        <tbody>
        <tr><td>1</td><td>2</td></tr>
        </tbody>
        </table>

        """)
    }

    @Test("Nested lists, task items, numbered starts and multi-line paragraphs keep their structure")
    func listsAndParagraphs() {
        let html = MarkdownHTML.body("""
        - two
          - nested
        - [ ] todo
        - [x] done

        3. third
        4. fourth

        line one
        line two
        line three\\
        line four
        """)

        #expect(html.contains("<li>\n<p>two</p>\n<ul>\n<li>nested</li>\n</ul>\n</li>"))
        #expect(html.contains("<li>☐ todo</li>"))
        #expect(html.contains("<li>☑ done</li>"))
        #expect(html.contains("<ol start=\"3\">\n<li>third</li>\n<li>fourth</li>\n</ol>"))
        #expect(html.contains("<p>line one\nline two\nline three<br>\nline four</p>"))
        // Two trailing spaces are the other hard break; a literal keeps them
        // only when written as an escape.
        #expect(MarkdownHTML.body("a  \nb") == "<p>a<br>\nb</p>\n")
    }

    @Test("A <br> written into the Markdown is a line break, not the text \"<br />\"")
    func inlineLineBreakTagsAreBreaks() {
        // The editor and the chat both write this form; a converted doc
        // showed it as a literal line of text.
        #expect(MarkdownHTML.body("one<br />\ntwo") == "<p>one<br>\ntwo</p>\n")
        #expect(MarkdownHTML.body("one<br>two") == "<p>one<br>two</p>\n")
        #expect(MarkdownHTML.body("one<BR/>two") == "<p>one<br>two</p>\n")
        // Anything else that starts with < is still text.
        #expect(MarkdownHTML.body("a <b>bold</b> <brief> tag") == "<p>a &lt;b&gt;bold&lt;/b&gt; &lt;brief&gt; tag</p>\n")
    }

    @Test("ForeverLM's own links and attachment images unwrap to their text; web ones travel")
    func internalAddressesUnwrap() {
        let html = MarkdownHTML.body("""
        A claim [with grounding](foreverlm://grounding/abc,book:def) and a [Paper](foreverlm://source/123) chip.

        ![Figure 1](foreverlm://attachment/xyz)

        ![](foreverlm://attachment/empty)

        ![Cover](https://example.com/cover.png)
        """)

        #expect(html.contains("<p>A claim with grounding and a Paper chip.</p>"))
        #expect(html.contains("<p><em>Figure 1</em></p>"))
        #expect(!html.contains("foreverlm://"))
        #expect(!html.contains("<p></p>"))
        #expect(html.contains("<img src=\"https://example.com/cover.png\" alt=\"Cover\">"))
    }

    @Test("Text is escaped, so a doc that talks about HTML does not become HTML")
    func escaping() {
        let html = MarkdownHTML.body("Use <script>alert(1)</script> & \"quotes\" in `a <b>` and [x](https://e.com/?a=1&b=2 \"T \\\"q\\\"\")")
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;"))
        #expect(html.contains("<code>a &lt;b&gt;</code>"))
        #expect(html.contains("href=\"https://e.com/?a=1&amp;b=2\""))
        #expect(!html.contains("<script>"))

        let document = MarkdownHTML.document(title: "Q3 <plan> & more", markdown: "Body")
        #expect(document.hasPrefix("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>Q3 &lt;plan&gt; &amp; more</title>\n</head>\n<body>\n<p>Body</p>\n</body>"))
    }

    @Test("Unclosed markers stay literal, closing hashes drop, and CRLF reads as LF")
    func edges() {
        #expect(MarkdownHTML.body("a * b and **c and `d") == "<p>a * b and **c and `d</p>\n")
        #expect(MarkdownHTML.body("## Heading ##") == "<h2>Heading</h2>\n")
        #expect(MarkdownHTML.body("#hashtag is prose") == "<p>#hashtag is prose</p>\n")
        #expect(MarkdownHTML.body("one\r\n\r\ntwo") == "<p>one</p>\n<p>two</p>\n")
        #expect(MarkdownHTML.body("") == "")
        #expect(MarkdownHTML.body("~~gone~~ \\*kept\\*") == "<p><s>gone</s> *kept*</p>\n")
    }

    @Test("The same Markdown always renders the same HTML")
    func deterministic() {
        let markdown = "# A\n\nb **c** [d](https://e.f)\n\n- g\n- h\n"
        let first = MarkdownHTML.document(title: "T", markdown: markdown)
        for _ in 0..<5 {
            #expect(MarkdownHTML.document(title: "T", markdown: markdown) == first)
        }
    }

    // MARK: - Drive request

    @Test("The create request is one multipart upload: JSON metadata naming a Google Doc, then the HTML")
    func multipartCreateRequest() throws {
        let request = try GoogleDocConversion.createRequest(
            title: "Plan",
            html: "<p>x</p>",
            accessToken: "token-under-test",
            boundary: "b"
        )

        #expect(request.httpMethod == "POST")
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "www.googleapis.com")
        #expect(url.path == "/upload/drive/v3/files")
        let query = url.query ?? ""
        #expect(query.contains("uploadType=multipart"))
        #expect(query.contains("fields=id,name,webViewLink"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-under-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/related; boundary=b")

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == "--b\r\n"
            + "Content-Type: application/json; charset=UTF-8\r\n\r\n"
            + "{\"mimeType\":\"application/vnd.google-apps.document\",\"name\":\"Plan\"}"
            + "\r\n--b\r\n"
            + "Content-Type: text/html; charset=UTF-8\r\n\r\n"
            + "<p>x</p>"
            + "\r\n--b--\r\n")
    }

    @Test("The metadata part trims the title and never sends an empty name")
    func metadataTitle() throws {
        let trimmed = try GoogleDocConversion.metadataJSON(title: "  Plan \n")
        #expect(String(decoding: trimmed, as: UTF8.self) == "{\"mimeType\":\"application/vnd.google-apps.document\",\"name\":\"Plan\"}")
        let blank = try GoogleDocConversion.metadataJSON(title: "   ")
        #expect(String(decoding: blank, as: UTF8.self).contains("\"name\":\"\(LinkedGoogleDoc.placeholderTitle)\""))
        let unicode = try GoogleDocConversion.metadataJSON(title: "Résumé / “Q3”")
        let decoded = try #require(JSONSerialization.jsonObject(with: unicode) as? [String: String])
        #expect(decoded["name"] == "Résumé / “Q3”")
    }

    @Test("Each request gets a boundary of its own that cannot collide with the parts")
    func boundaries() {
        let one = GoogleDocConversion.defaultBoundary()
        let two = GoogleDocConversion.defaultBoundary()
        #expect(one != two)
        #expect(one.hasPrefix("foreverlm_doc_"))
        #expect(one.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    // MARK: - Drive response

    @Test("The new document's id comes out of Drive's answer and becomes the canonical edit URL")
    func responseID() throws {
        let data = Data("""
        {"id": "1AbC-dEf_9", "name": "Plan", "webViewLink": "https://docs.google.com/document/d/1AbC-dEf_9/edit?usp=drivesdk"}
        """.utf8)
        let id = try GoogleDocConversion.documentID(fromCreateResponse: data)
        #expect(id == "1AbC-dEf_9")
        #expect(LinkedGoogleDoc.editURL(documentID: id).absoluteString == "https://docs.google.com/document/d/1AbC-dEf_9/edit")
    }

    @Test("An answer without an id, or that is not JSON, is refused rather than linked to nothing")
    func responseWithoutID() {
        for body in ["{\"name\": \"Plan\"}", "{\"id\": \"   \"}", "not json", ""] {
            #expect(throws: GoogleDocConversionError.invalidResponse) {
                _ = try GoogleDocConversion.documentID(fromCreateResponse: Data(body.utf8))
            }
        }
    }

    @Test("Google's own error message is read out of a failed answer when there is one")
    func errorMessages() {
        let refused = Data("""
        {"error": {"code": 403, "message": "The user does not have sufficient permissions for this file.", "errors": []}}
        """.utf8)
        #expect(GoogleDocConversion.errorMessage(fromResponse: refused) == "The user does not have sufficient permissions for this file.")
        #expect(GoogleDocConversion.errorMessage(fromResponse: Data("<html>gateway</html>".utf8)) == nil)

        #expect(GoogleDocConversionError.refused(status: 403, detail: "Denied").errorDescription
            == "Google Drive refused to create the document (HTTP 403): Denied")
        #expect(GoogleDocConversionError.refused(status: 502, detail: nil).errorDescription
            == "Google Drive refused to create the document (HTTP 502).")
        #expect(GoogleDocConversionError.network("The Internet connection appears to be offline.").errorDescription
            == "Could not reach Google Drive. The Internet connection appears to be offline.")
        #expect(GoogleDocConversionError.signInIncomplete("Google answered: access_denied.").errorDescription?.hasPrefix("Google sign-in did not finish") == true)
    }
}
