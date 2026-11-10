import Foundation
import PDFKit
import SQLite3
import Testing
import WebKit
@testable import ForeverLM

/// U+00AD SOFT HYPHEN in the text a source keeps (docs/source-content-integrity.md,
/// "Soft hyphens are not text"). On 2026-10-06 the production library held 6,505 of
/// them in the canonical text of 88 papers, 24 books and 5 articles, and three
/// articles held the literal `&shy;` the decoder did not know: invisible on the
/// page, but each one split its word for keyword search, embeddings, a chat's
/// quote and Listen.
@Suite("Soft hyphens are dropped where source text is derived")
struct SoftHyphenRemovalTests {
    @Test("&shy; decodes to the soft hyphen it names, as &#173; always did")
    func decoderKnowsShy() {
        #expect("life&shy;span".decodingHTMLCharacterReferences() == "life\u{00AD}span")
        #expect("life&#173;span".decodingHTMLCharacterReferences() == "life\u{00AD}span")
        #expect("life&#xAD;span".decodingHTMLCharacterReferences() == "life\u{00AD}span")
        // One level, as for every reference: text that means the entity keeps it.
        #expect("write &amp;shy; to hint".decodingHTMLCharacterReferences() == "write &shy; to hint")
        #expect("&SHY; is no reference".decodingHTMLCharacterReferences() == "&SHY; is no reference")
    }

    @Test("removingSoftHyphens drops every U+00AD and joins no words")
    func removingSoftHyphensKeepsWordsApart() {
        // The contexts the production library holds them in: after a hyphen,
        // inside a word, at a line's start, after a space and before one.
        #expect("regeneration-\u{00AD}associated".removingSoftHyphens() == "regeneration-associated")
        #expect("life\u{00AD}span".removingSoftHyphens() == "lifespan")
        #expect("the end of a line\n\u{00AD}the next".removingSoftHyphens() == "the end of a line\nthe next")
        #expect("species \u{00AD}specific".removingSoftHyphens() == "species specific")
        #expect("calcu\u{00AD} lation".removingSoftHyphens() == "calcu lation")
        #expect("\u{00AD}\u{00AD}".removingSoftHyphens() == "")
        // An accent stays on its letter, and every other hyphen and dash stays.
        #expect("cafe\u{0301}\u{00AD}s".removingSoftHyphens() == "cafe\u{0301}s")
        let plain = "A hyphen-minus, a non\u{2011}breaking one, a \u{2010} hyphen and \u{2014} a dash."
        #expect(plain.removingSoftHyphens() == plain)
    }

    @Test("A title keeps no soft hyphen")
    func titles() {
        // The one production title that held one (a paper, 2026-10-06).
        #expect(
            "Plasma GDF15 affects long-\u{00AD} term dementia risk".decodingTitleMarkup()
                == "Plasma GDF15 affects long- term dementia risk"
        )
        #expect("Mito&shy;chondria".decodingTitleMarkup() == "Mitochondria")
        var article = StudioArticle(url: "https://example.org/neuro", title: "Neuro\u{00AD}degeneration", sourceType: .article)
        #expect(article.title == "Neurodegeneration")
        article.title = "Re&shy;generation"
        #expect(article.title == "Regeneration")
    }

    @Test("An article's text keeps no soft hyphen, written raw or as a reference")
    func articleText() {
        let html = """
        <body><article>
          <p>Mito&shy;chondrial regeneration-\u{00AD}associated genes set life&#173;span.</p>
          <p>A page that writes about the entity: &amp;shy; stays as written.</p>
        </article></body>
        """
        let text = SourceService.readableTextFromHTML(html)

        #expect(text.contains("Mitochondrial regeneration-associated genes set lifespan."))
        #expect(text.contains("&shy; stays as written."))
        #expect(!text.unicodeScalars.contains("\u{00AD}"))
    }

    @Test("A book's text and its chapter titles keep no soft hyphen")
    func bookText() {
        let html = "<html><body><p>The calcu&shy;lation of mito\u{00AD}chondrial life&#173;span.</p></body></html>"
        #expect(EPUBParser.stripHTML(html) == "The calculation of mitochondrial lifespan.")
        #expect(EPUBParser.normalizeChapterTitle("Chapter 3: Bio&shy;energetics") == "Chapter 3: Bioenergetics")
    }

    @Test("A podcast transcript from TTML keeps no soft hyphen, and a word of nothing else leaves no gap")
    func podcastTranscript() throws {
        let ttml = """
        <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="0.0" end="2.0" ttm:agent="SPEAKER_1">
              <span podcasts:unit="word">Mito\u{00AD}chondria</span>
              <span podcasts:unit="word">&#173;</span>
              <span podcasts:unit="word">divide.</span>
            </p>
            <p begin="2.0" end="3.0" ttm:agent="SPEAKER_2">Life&#173;span follows.</p>
          </div></body>
        </tt>
        """
        let transcript = try SourceService.extractTextFromTTMLContent(ttml)

        #expect(transcript.contains("[SPEAKER_1]\nMitochondria divide."))
        #expect(transcript.contains("[SPEAKER_2]\nLifespan follows."))
        #expect(!transcript.unicodeScalars.contains("\u{00AD}"))
    }

    @Test("A YouTube transcript keeps no soft hyphen from its captions")
    func youTubeCaptions() throws {
        let xml = """
        <transcript>
          <text start="0.0" dur="3.0">mito&amp;shy;chondrial life&amp;#173;span is long</text>
        </transcript>
        """
        let transcript = try YouTubeTranscriptService.transcript(fromCaptionXML: xml)

        #expect(transcript.contains("mitochondrial lifespan is long"))
        #expect(!transcript.unicodeScalars.contains("\u{00AD}"))
    }

    @Test("A PDF page's soft hyphens stay on the page and out of the text")
    func pdfPageText() throws {
        let document = try #require(PDFDocument(data: Self.softHyphenPDF()))
        let page = try #require(document.page(at: 0)?.string)
        #expect(page.unicodeScalars.filter { $0 == "\u{00AD}" }.count == 2, "the fixture's page carries two")

        #expect(PDFTextExtractor.embeddedText(from: document, pages: 0..<1) == "regeneration-associated genes and lifespan studies")
        #expect(PDFTextExtractor.canonicalPageText("t=\u{0000}43\u{00AD}.49") == "t=\u{FFFD}43.49")
    }

    /// A one-page PDF whose text layer holds soft hyphens the way a publisher's
    /// does: its font's ToUnicode map gives code 0xAD to U+00AD, printed after a
    /// hyphen and inside a word. PDFKit's `page.string` returns them.
    static func softHyphenPDF() -> Data {
        var content = Data("BT /F1 12 Tf 72 720 Td (regeneration-".utf8)
        content.append(0xAD)
        content.append(contentsOf: Data("associated genes and life".utf8))
        content.append(0xAD)
        content.append(contentsOf: Data("span studies) Tj ET".utf8))
        let cmap = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <00> <FF>
            endcodespacerange
            2 beginbfrange
            <20> <7E> <0020>
            <AD> <AD> <00AD>
            endbfrange
            endcmap
            CMapName currentdict /CMap defineresource pop
            end
            end
            """
        var contentObject = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        contentObject.append(content)
        contentObject.append(contentsOf: Data("\nendstream".utf8))
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".utf8),
            contentObject,
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [173 /hyphen] >> /ToUnicode 6 0 R >>".utf8),
            Data("<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream".utf8),
        ]
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(contentsOf: Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(contentsOf: Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(contentsOf: Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(contentsOf: Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(contentsOf: Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return pdf
    }
}

/// The readers keep a page's soft hyphens — a PDF page and an archived web page print
/// what their layout chose — while the stored text has none, and a mark made on either
/// side is resolved on the other: an assistant's mark over MCP is anchored in the stored
/// text and painted on the page, a mark made on the page is found in the stored text.
@Suite("Reader anchors look past soft hyphens")
struct ReaderAnchorSoftHyphenTests {
    private static let page = "Mito\u{00AD}chondrial genes for regeneration-\u{00AD}associated life\u{00AD}span studies."
    private static let stored = "Mitochondrial genes for regeneration-associated lifespan studies."

    @Test("The anchor projection leaves soft hyphens out, wherever they sit")
    func projectionSkipsSoftHyphens() {
        #expect(ReaderTextAnchor.normalize(Self.page).text == Self.stored)
        #expect(ReaderTextAnchor.normalize("\u{00AD}a \u{00AD} b\u{00AD}\n").text == "a b")
        #expect(ReaderTextAnchor(exact: "\u{00AD}").isEmpty)
    }

    @Test("A mark made in the stored text resolves on the page, and one made on the page resolves in the stored text")
    func resolvesBothWays() throws {
        let fromStored = ReaderTextAnchor(
            text: Self.stored,
            range: try #require(Self.stored.range(of: "associated lifespan"))
        )
        let onPage = try #require(fromStored.resolve(in: Self.page))
        #expect(String(Self.page[onPage]) == "associated life\u{00AD}span")

        let fromPage = ReaderTextAnchor(
            text: Self.page,
            range: try #require(Self.page.range(of: "regeneration-\u{00AD}associated"))
        )
        let inStored = try #require(fromPage.resolve(in: Self.stored))
        #expect(String(Self.stored[inStored]) == "regeneration-associated")
        // The offset counts the same characters on either side.
        let measuredInStored = ReaderTextAnchor(
            text: Self.stored,
            range: try #require(Self.stored.range(of: "regeneration-associated"))
        )
        #expect(fromPage.offset == measuredInStored.offset)
    }

    @Test("The PDF reader paints a mark from the stored text on a page that prints a soft hyphen in its words")
    func pdfReaderPaintsAcrossSoftHyphens() throws {
        let document = try #require(PDFDocument(data: SoftHyphenRemovalTests.softHyphenPDF()))
        // PDFKit's own search reads the page as printed and does not find it.
        #expect(document.findString("lifespan studies", withOptions: [.caseInsensitive]).isEmpty)

        let now = Date()
        let mark = SourceHighlight(
            id: "hl_stored", sourceID: "paper", quote: "lifespan studies", note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: "lifespan studies"), createdAt: now, updatedAt: now
        )
        let installed = ReaderPDFHighlightSupport.paint([mark], into: document)

        #expect(!installed.isEmpty)
        #expect(installed.allSatisfy { $0.page === document.page(at: 0) })
        ReaderPDFHighlightSupport.remove(installed)
    }
}

/// The Mac's web readers, in a real WebKit page whose text keeps the soft hyphens the
/// page was written with (`&shy;`).
@Suite("Mac web reader looks past soft hyphens", .serialized)
struct MacWebReaderSoftHyphenTests {
    @MainActor
    private final class PageRecorder: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            messages.append(body)
        }

        func messages(ofType type: String) -> [[String: Any]] {
            messages.filter { $0["type"] as? String == type }
        }
    }

    private static let pageHTML = """
    <!doctype html><html><body style="margin:0;padding:40px">
    <p id="lead">Mito&shy;chondrial genes for regeneration-&shy;associated life&shy;span studies.</p>
    </body></html>
    """

    @MainActor
    private func loadedPage() async throws -> (WKWebView, PageRecorder) {
        let recorder = PageRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "foreverlm")
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewReader.selectionDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(Self.pageHTML, baseURL: URL(string: "https://reader.example/soft-hyphens"))
        var ready = false
        for _ in 0..<150 where !ready {
            ready = try await webView.evaluateJavaScript(
                "window.foreverLMReaderUserSelectionInstalled === true && typeof window.foreverLMApplyHighlights === 'function'"
            ) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(ready, "the reader scripts never installed")
        return (webView, recorder)
    }

    @MainActor
    private func waitForMessages(_ recorder: PageRecorder, ofType type: String, count: Int) async throws {
        for _ in 0..<60 where recorder.messages(ofType: type).count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A mark from the stored text is painted over the page's soft hyphens")
    @MainActor
    func paintsStoredTextMark() async throws {
        let (webView, _) = try await loadedPage()
        let now = Date()
        let quote = "regeneration-associated lifespan studies"
        let mark = SourceHighlight(
            id: "hl_stored", sourceID: "src", quote: quote, note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: quote, offset: 24), createdAt: now, updatedAt: now
        )
        ReaderWebHighlightSupport.apply([mark], to: webView)

        var painted: [String] = []
        for _ in 0..<40 where painted.isEmpty {
            painted = try await webView.evaluateJavaScript("""
            (() => {
              const group = window.CSS && CSS.highlights ? CSS.highlights.get('foreverlm-note-yellow') : null;
              return group ? Array.from(group).map(range => range.toString()) : [];
            })()
            """) as? [String] ?? []
            if painted.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(painted == ["regeneration-\u{00AD}associated life\u{00AD}span studies"])
    }

    @Test("A selection's offset counts the page's text without its soft hyphens, as the anchor's does")
    @MainActor
    func selectionOffsetSkipsSoftHyphens() async throws {
        let (webView, recorder) = try await loadedPage()
        let selected = try await webView.evaluateJavaScript("""
        (() => {
          const node = document.getElementById('lead').firstChild;
          const at = node.nodeValue.indexOf('studies');
          const range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + 'studies'.length);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
          return selection.toString();
        })()
        """) as? String
        #expect(selected == "studies")
        try await waitForMessages(recorder, ofType: "selection", count: 1)
        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-foreverlm-selection-callout]').shadowRoot"
                + ".querySelector('.pill[data-action=\"highlight\"]').click(); true"
        )
        try await waitForMessages(recorder, ofType: "highlightRequest", count: 1)

        let request = try #require(recorder.messages(ofType: "highlightRequest").last)
        let anchor = try #require(ReaderWebSelectionAnchor(payload: request))
        #expect(anchor.text == "studies")
        // The offset an anchor over the stored text gets for the same word.
        let stored = "Mitochondrial genes for regeneration-associated lifespan studies."
        let measuredInStored = ReaderTextAnchor(text: stored, range: try #require(stored.range(of: "studies")))
        #expect(anchor.offset == measuredInStored.offset)
    }
}

// MARK: - Schema 166: the soft hyphens older builds stored

/// Rows the way builds before 166 stored them, written straight into the tables so a test
/// controls every hash: a source and its text, a paper's preparation, the Listen text,
/// review guide, walkthrough, ideas and reading levels made from it.
private enum StoredText {
    /// A paper's canonical text with a PDF's soft hyphens: after a hyphen at a line end,
    /// inside words.
    static let content = "Mitochondrial regeneration-\u{00AD}associated genes set life\u{00AD}span.\n\nMethods were stand\u{00AD}ard.\n"
    static let repairedContent = "Mitochondrial regeneration-associated genes set lifespan.\n\nMethods were standard.\n"
    static let raw = "Running head\u{000C}" + content + "\nReferences\n1. On cal\u{00AD}cium."
    static let repairedRaw = "Running head\u{000C}" + repairedContent + "\nReferences\n1. On calcium."

    static func sha(_ text: String) -> String { PaperContentPreparationService.sha256(text) }
    static func listenSHA(_ text: String) -> String { sha(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    static func addSource(
        _ store: KnowledgeStore, _ id: String, type: String = "paper", title: String = "A paper",
        content: String?, status: String = "active", teamID: String? = nil
    ) throws {
        try store.execute(
            "INSERT INTO sources (id, date_added, state, source_type, status, team_id) VALUES (?, 1, 'ready', ?, ?, ?)",
            [.text(id), .text(type), .text(status), .text(teamID)]
        )
        try store.execute(
            "INSERT INTO \(SourceLocalTables.subtypeTable(forLocalType: type)) (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, ?, 'example.org')",
            [.text(id), .text("https://example.org/\(id)"), .text("https://example.org/\(id)"), .text(title)]
        )
        if let content {
            try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text(content)])
        }
    }

    static func addPreparation(
        _ store: KnowledgeStore, _ id: String, table: String = "paper_content_preparations",
        raw: String, rawSHA: String, cleanSHA: String?
    ) throws {
        try store.execute("""
            INSERT INTO \(table) (source_id, raw_content, raw_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES (?, ?, ?, ?, ?, 1)
        """, [.text(id), .text(raw), .text(rawSHA), .text(cleanSHA), .integer(Int64(PaperContentPreparationMetadata.currentVersion))])
    }

    /// The Listen text, review guide, walkthrough, one idea and the reading levels, each
    /// stamped as made from `listenHash` / `hash`.
    static func addDerivatives(_ store: KnowledgeStore, _ id: String, hash: String, listenHash: String) throws {
        try store.execute("""
            INSERT INTO source_listenable_content (source_id, source_sha256, content, generator_version, preparation_signature, prepared_at)
            VALUES (?, ?, ?, ?, ?, 1)
        """, [
            .text(id), .text(listenHash), .text("Mitochondrial regeneration-\u{00AD}associated genes set life\u{00AD}span."),
            .integer(Int64(SourceListenableContentMetadata.currentVersion)), .text("\(PaperNarrationFilter.preparationContractPrefix)test"),
        ])
        try store.execute("""
            INSERT INTO source_review_guides (source_id, source_sha256, guide, generator_version, generated_at)
            VALUES (?, ?, ?, 1, 1)
        """, [.text(id), .text(hash), .text("## Guide\nAsk about life\u{00AD}span.")])
        try store.execute("""
            INSERT INTO source_walkthroughs (source_id, source_sha256, walkthrough_json, walkthrough_version, generated_at)
            VALUES (?, ?, ?, 1, 1)
        """, [.text(id), .text(hash), .text("{\"source_sha256\":\"\(hash)\",\"steps\":[]}")])
        try store.execute("""
            INSERT INTO source_ideas (id, source_id, statement, recall_note, anchors_json, wanted, origin_session_id,
                                      content_hash, status, sort_index, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, NULL, ?, 'active', 0, 1, 1)
        """, [
            .text(SourceIdea.id(sourceID: id, contentHash: hash, index: 0)), .text(id),
            .text("Regeneration-\u{00AD}associated genes set life\u{00AD}span."), .text("Names the genes and life\u{00AD}span."),
            .text("[{\"quote\":\"genes set life\u{00AD}span\"}]"), .text(hash),
        ])
        try store.execute(
            "INSERT INTO source_levels (source_id, content_sha256, payload_json, model, created_at) VALUES (?, ?, '{}', NULL, 1)",
            [.text(id), .text(hash)]
        )
    }

    static func text(_ store: KnowledgeStore, _ sql: String, _ id: String) throws -> String? {
        try store.scalarText(sql, [.text(id)])
    }

    static func count(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        Int(try store.scalarInteger(sql, parameters) ?? -1)
    }

    /// The paid queues a repair must never add work to.
    static func paidWork(_ store: KnowledgeStore) throws -> Int {
        try count(store, """
            SELECT (SELECT COUNT(*) FROM canonical_content_cleanup_queue)
                 + (SELECT COUNT(*) FROM podcast_transcript_cleanup_queue)
                 + (SELECT COUNT(*) FROM source_listenable_content_queue)
                 + (SELECT COUNT(*) FROM source_review_guide_queue)
        """)
    }
}

@Suite("Stored soft hyphens: what the repair drops")
struct StoredSoftHyphensTests {
    @Test("Every U+00AD goes, and a literal &shy; goes where it touches a letter or digit")
    func repairedByContext() {
        // The contexts the three production articles held the entity in.
        #expect(StoredSoftHyphens.repaired("Mito&shy;chondria") == "Mitochondria")
        #expect(StoredSoftHyphens.repaired("regeneration-&shy;associated") == "regeneration-associated")
        #expect(StoredSoftHyphens.repaired("a word&shy;. Next") == "a word. Next")
        #expect(StoredSoftHyphens.repaired("species &shy;specific") == "species specific")
        #expect(StoredSoftHyphens.repaired("&shy;1950s") == "1950s")
        // A page writing about the entity keeps it.
        #expect(StoredSoftHyphens.repaired("write &shy; where a word may break") == "write &shy; where a word may break")
        #expect(StoredSoftHyphens.repaired("the `&shy;` entity") == "the `&shy;` entity")
        #expect(StoredSoftHyphens.repaired("&amp;shy; stays") == "&amp;shy; stays")
        // Runs of them, mixed with the character.
        #expect(StoredSoftHyphens.repaired("cal&shy;&shy;cium") == "calcium")
        #expect(StoredSoftHyphens.repaired("life\u{00AD}&shy;span") == "lifespan")
        #expect(StoredSoftHyphens.repaired("\u{00AD}") == "")
        #expect(StoredSoftHyphens.repaired(StoredText.content) == StoredText.repairedContent)
        let plain = "A text with no soft hyphen, & an ampersand; and &nbsp; written out."
        #expect(StoredSoftHyphens.repaired(plain) == plain)
        #expect(!StoredSoftHyphens.holdsSoftHyphen(plain))
        #expect(StoredSoftHyphens.holdsSoftHyphen("x&shy;y") && StoredSoftHyphens.holdsSoftHyphen("x\u{00AD}y"))
    }

    @Test("An idea's anchor quotes lose their soft hyphens and keep their highlight")
    func anchorQuotes() throws {
        let json = "[{\"quote\":\"genes set life\u{00AD}span\",\"highlightID\":\"hl_1\"}]"
        let repaired = KnowledgeStore.anchorsJSONWithoutSoftHyphens(json)
        let anchors = try JSONDecoder().decode([SourceIdeaAnchor].self, from: Data(repaired.utf8))
        #expect(anchors == [SourceIdeaAnchor(quote: "genes set lifespan", highlightID: "hl_1")])
        #expect(KnowledgeStore.anchorsJSONWithoutSoftHyphens("[{\"quote\":\"plain\"}]") == "[{\"quote\":\"plain\"}]")
        #expect(KnowledgeStore.anchorsJSONWithoutSoftHyphens("not json \u{00AD}") == "not json \u{00AD}")
    }
}

/// The schema-166 step: the queue, and every source of the learner's own library staged by
/// id, from both released shapes — 165 (build 188) and 164 (builds 180 to 187).
@Suite("Schema 166 migration", .serialized)
struct StoredSoftHyphenRepairMigrationTests {
    /// A library in a released shape: today's store without the 166 queue, stamped `version`;
    /// at 164 also without 165's three sensemaking tables. Five sources of the learner's own
    /// (two holding soft hyphens, one the literal entity, one archived, one with no text yet)
    /// and a team's copy, plus `extraSources` papers of a few kilobytes each.
    private func makeReleasedLibrary(at root: URL, version: Int32, extraSources: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        try StoredText.addSource(store, "paper-shy", content: StoredText.content)
        try StoredText.addSource(store, "article-entity", type: "article", title: "An article", content: "The mito&shy;chondrion, and &shy; itself.")
        try StoredText.addSource(store, "article-clean", type: "article", title: "Clean", content: "Nothing to repair here.")
        try StoredText.addSource(store, "book-archived", type: "book", title: "A chapter", content: "calcu\u{00AD} lation", status: "archived")
        try StoredText.addSource(store, "paper-queued", title: "Not fetched yet", content: nil)
        try StoredText.addSource(store, "team-copy", title: "A team's copy", content: StoredText.content, teamID: "team-1")
        if extraSources > 0 {
            try store.execForTesting("""
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraSources))
                INSERT INTO sources (id, date_added, state, source_type, status) SELECT printf('paper-%05d', i), i, 'ready', 'paper', 'active' FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraSources))
                INSERT INTO papers (source_id, url, title) SELECT printf('paper-%05d', i), printf('https://example.org/%d', i), printf('Paper %d', i) FROM n;
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(extraSources))
                INSERT INTO source_content (source_id, content)
                SELECT printf('paper-%05d', i), printf('%s life%sspan', hex(randomblob(2000)), CASE WHEN i % 40 = 0 THEN char(173) ELSE '' END) FROM n;
            """)
        }
        try store.execForTesting("""
            DROP TABLE source_text_soft_hyphen_repair_queue;
            \(version < 165 ? "DROP INDEX IF EXISTS idx_atlases_updated; DROP TABLE atlases; DROP TABLE source_levels; DROP TABLE source_faces;" : "")
            PRAGMA user_version = \(version);
        """)
    }

    private func reopen(_ root: URL) throws -> KnowledgeStore {
        Schema154Fixture.newLaunch(root)
        return try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
    }

    @Test("Stages every source of the learner's own library by id, reads no text, and publishes nothing", arguments: [Int32(164), Int32(165)])
    func stagesTheLibrary(from released: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("soft-hyphens-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeReleasedLibrary(at: root, version: released)

        let migrated = try reopen(root)

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(try migrated.storedSoftHyphenRepairQueueCount() == 5)
        #expect(try StoredText.count(migrated, "SELECT COUNT(*) FROM source_text_soft_hyphen_repair_queue WHERE source_id = 'team-copy'") == 0,
                "a team's copy is left to the library it is shared from")
        // The library is whole and on screen while the repair waits; the text is untouched.
        #expect(Set(try migrated.loadActiveSources().map(\.id)) == ["paper-shy", "article-entity", "article-clean", "paper-queued"])
        #expect(try migrated.loadSourceContent("paper-shy") == StoredText.content)
        #expect(try migrated.loadSourceContent("article-entity") == "The mito&shy;chondrion, and &shy; itself.")
        #expect(try StoredText.paidWork(migrated) == 0)
        // 164 gains 165's tables on the way.
        #expect(try StoredText.count(migrated, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('atlases', 'source_levels', 'source_faces')") == 3)
    }

    @Test("Stages ids alone at production scale, well under a second")
    func scaleRegression() throws {
        let root = try Schema154Fixture.temporaryRoot("soft-hyphens-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeReleasedLibrary(at: root, version: 165, extraSources: 5_000)

        let started = ContinuousClock.now
        let migrated = try reopen(root)
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(1))
        #expect(try migrated.storedSoftHyphenRepairQueueCount() == 5_005)
        #expect(try migrated.loadSourceContent("paper-00040")?.unicodeScalars.contains("\u{00AD}") == true, "the migration reads no text")
    }

    @Test("A failed step rolls back and leaves the released library as it was")
    func rollsBack() throws {
        let root = try Schema154Fixture.temporaryRoot("soft-hyphens-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeReleasedLibrary(at: root, version: 165)
        // A same-named queue of another shape, which `CREATE TABLE IF NOT EXISTS` keeps: the
        // probe fails inside the migration.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE source_text_soft_hyphen_repair_queue (unexpected TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) { _ = try reopen(root) }

        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 165)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == 6)
        #expect(Schema154Fixture.scalar(at: root, "SELECT content FROM source_content WHERE source_id = 'paper-shy'") == StoredText.content)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('source_text_soft_hyphen_repair_queue') WHERE name = 'unexpected'") == 1)
    }
}

/// The post-launch half of schema 166.
@Suite("Stored soft hyphen repair")
struct StoredSoftHyphenRepairDrainTests {
    private func makeStore() throws -> KnowledgeStore {
        try KnowledgeStore(inMemory: true)
    }

    @Test("Repairs a paper's text and keeps what was made from it, with the repaired text's hashes")
    func repairsAndRestamps() throws {
        let store = try makeStore()
        let id = "paper-1"
        let oldHash = StoredText.sha(StoredText.content)
        let newHash = StoredText.sha(StoredText.repairedContent)
        try StoredText.addSource(store, id, content: StoredText.content)
        try StoredText.addPreparation(store, id, raw: StoredText.raw, rawSHA: StoredText.sha(StoredText.raw), cleanSHA: oldHash)
        try StoredText.addDerivatives(store, id, hash: oldHash, listenHash: StoredText.listenSHA(StoredText.content))
        try store.replaceSourceFTS(sourceID: id, title: "A paper", author: "", body: StoredText.content)
        try store.recordSourceIndexed(sourceID: id)
        try store.execute("INSERT INTO source_review_guide_queue (source_id, source_sha256, enqueued_at) VALUES (?, ?, 1)", [.text(id), .text(oldHash)])
        #expect(try store.enqueueStoredSoftHyphenRepair() == 1)
        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

        let batch = try store.drainStoredSoftHyphenRepairBatch(limit: 50, now: now)

        #expect(batch == StoredSoftHyphenRepairBatch(processedCount: 1, repairedSourceIDs: [id]))
        #expect(try store.loadSourceContent(id) == StoredText.repairedContent)
        // The extraction and its proof.
        #expect(try StoredText.text(store, "SELECT raw_content FROM paper_content_preparations WHERE source_id = ?", id) == StoredText.repairedRaw)
        #expect(try StoredText.text(store, "SELECT raw_sha256 FROM paper_content_preparations WHERE source_id = ?", id) == StoredText.sha(StoredText.repairedRaw))
        #expect(try StoredText.text(store, "SELECT clean_sha256 FROM paper_content_preparations WHERE source_id = ?", id) == newHash)
        // What was made from the text, kept with its new hash.
        #expect(try StoredText.text(store, "SELECT content FROM source_listenable_content WHERE source_id = ?", id) == "Mitochondrial regeneration-associated genes set lifespan.")
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_listenable_content WHERE source_id = ?", id) == StoredText.listenSHA(StoredText.repairedContent))
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_review_guides WHERE source_id = ?", id) == newHash)
        #expect(try StoredText.text(store, "SELECT guide FROM source_review_guides WHERE source_id = ?", id) == "## Guide\nAsk about lifespan.")
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_walkthroughs WHERE source_id = ?", id) == newHash)
        #expect(try StoredText.text(store, "SELECT walkthrough_json FROM source_walkthroughs WHERE source_id = ?", id) == "{\"source_sha256\":\"\(newHash)\",\"steps\":[]}")
        #expect(try StoredText.text(store, "SELECT content_sha256 FROM source_levels WHERE source_id = ?", id) == newHash)
        let idea = try #require(try store.loadSourceIdeas(sourceIDs: [id])[id]?.first)
        #expect(idea.contentHash == newHash)
        #expect(idea.statement == "Regeneration-associated genes set lifespan.")
        #expect(idea.recallNote == "Names the genes and lifespan.")
        #expect(idea.anchors == [SourceIdeaAnchor(quote: "genes set lifespan")])
        #expect(idea.updatedAt == now)
        #expect(try store.sourceIdeaContentHash(sourceID: id) == StoredText.sha(try #require(try store.loadSourceContent(id))),
                "the extraction finds its ideas current and bills nothing")
        // The indexes are rebuilt from the new text; the pending guide preparation is retired.
        #expect(try StoredText.count(store, "SELECT COUNT(*) FROM source_fts WHERE source_id = ?", [.text(id)]) == 0)
        #expect(try StoredText.count(store, "SELECT COUNT(*) FROM source_index_state WHERE source_id = ?", [.text(id)]) == 0)
        #expect(try StoredText.paidWork(store) == 0)
        #expect(try store.storedSoftHyphenRepairQueueCount() == 0)
        // The source and its idea go to the other devices.
    }

    @Test("Leaves what was made from older text, and a raw extraction its hash no longer attests, as they were")
    func leavesStaleDerivatives() throws {
        let store = try makeStore()
        let id = "paper-stale"
        let older = StoredText.sha("an older text")
        try StoredText.addSource(store, id, content: StoredText.content)
        try StoredText.addPreparation(store, id, raw: StoredText.raw, rawSHA: "a hash the raw does not match", cleanSHA: StoredText.sha(StoredText.content))
        try StoredText.addDerivatives(store, id, hash: older, listenHash: older)
        try store.enqueueStoredSoftHyphenRepair()

        let batch = try store.drainStoredSoftHyphenRepairBatch(limit: 50)

        #expect(batch.repairedSourceIDs == [id])
        #expect(try store.loadSourceContent(id) == StoredText.repairedContent)
        // The integrity audit owns a raw its hash does not attest.
        #expect(try StoredText.text(store, "SELECT raw_content FROM paper_content_preparations WHERE source_id = ?", id) == StoredText.raw)
        #expect(try StoredText.text(store, "SELECT raw_sha256 FROM paper_content_preparations WHERE source_id = ?", id) == "a hash the raw does not match")
        #expect(try StoredText.text(store, "SELECT clean_sha256 FROM paper_content_preparations WHERE source_id = ?", id) == StoredText.sha(StoredText.repairedContent))
        // Stale before, stale after, untouched.
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_listenable_content WHERE source_id = ?", id) == older)
        #expect(try StoredText.text(store, "SELECT content FROM source_listenable_content WHERE source_id = ?", id) == "Mitochondrial regeneration-\u{00AD}associated genes set life\u{00AD}span.")
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_review_guides WHERE source_id = ?", id) == older)
        #expect(try StoredText.text(store, "SELECT source_sha256 FROM source_walkthroughs WHERE source_id = ?", id) == older)
        #expect(try StoredText.text(store, "SELECT content_sha256 FROM source_levels WHERE source_id = ?", id) == older)
        let idea = try #require(try store.loadSourceIdeas(sourceIDs: [id])[id]?.first)
        #expect(idea.contentHash == older)
        #expect(idea.statement == "Regeneration-\u{00AD}associated genes set life\u{00AD}span.")
    }

    @Test("A source a paid pass is working on waits for it", arguments: [
        "canonical_content_cleanup_queue", "podcast_transcript_cleanup_queue", "source_listenable_content_queue",
    ])
    func busySourcesWait(queue: String) throws {
        let store = try makeStore()
        try StoredText.addSource(store, "busy", type: "article", title: "Busy", content: StoredText.content)
        try StoredText.addSource(store, "clean", type: "article", title: "Clean", content: "Nothing to repair.")
        try store.execute("INSERT INTO \(queue) (source_id, target_version, enqueued_at) VALUES ('busy', 1, 1)")
        try store.enqueueStoredSoftHyphenRepair()

        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == StoredSoftHyphenRepairBatch(processedCount: 1, repairedSourceIDs: []))
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == .empty, "only the busy source is left, and it is not read")
        #expect(try store.loadSourceContent("busy") == StoredText.content)
        #expect(try store.storedSoftHyphenRepairQueueCount() == 1)

        try store.execute("DELETE FROM \(queue)")
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50).repairedSourceIDs == ["busy"])
        #expect(try store.loadSourceContent("busy") == StoredText.repairedContent)
    }

    @Test("A second pass changes nothing and queues no paid work, and a batch of clean sources is still progress")
    func idempotent() throws {
        let store = try makeStore()
        try StoredText.addSource(store, "paper-1", content: StoredText.content)
        try StoredText.addPreparation(store, "paper-1", raw: StoredText.raw, rawSHA: StoredText.sha(StoredText.raw), cleanSHA: StoredText.sha(StoredText.content))
        for index in 0..<120 {
            try StoredText.addSource(store, String(format: "clean-%03d", index), type: "article", title: "Clean \(index)", content: "Plain text \(index).")
        }
        try store.enqueueStoredSoftHyphenRepair()

        var batches: [StoredSoftHyphenRepairBatch] = []
        while true {
            let batch = try store.drainStoredSoftHyphenRepairBatch(limit: 50)
            guard batch.processedCount > 0 else { break }
            batches.append(batch)
        }
        #expect(batches.map(\.processedCount) == [50, 50, 21])
        #expect(batches.flatMap(\.repairedSourceIDs) == ["paper-1"])
        let repaired = try store.loadSourceContent("paper-1")
        let repairedRawHash = try StoredText.text(store, "SELECT raw_sha256 FROM paper_content_preparations WHERE source_id = ?", "paper-1")

        try store.enqueueStoredSoftHyphenRepair()
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 200) == StoredSoftHyphenRepairBatch(processedCount: 121, repairedSourceIDs: []))
        #expect(try store.loadSourceContent("paper-1") == repaired)
        #expect(try StoredText.text(store, "SELECT raw_sha256 FROM paper_content_preparations WHERE source_id = ?", "paper-1") == repairedRawHash)
        #expect(try StoredText.paidWork(store) == 0)
    }

    @Test("A batch repairs one source and leaves the rest of its window to the next, so the storage lane is never held long")
    func oneRepairPerBatch() throws {
        let store = try makeStore()
        for id in ["paper-a", "paper-b", "paper-c"] {
            try StoredText.addSource(store, id, content: StoredText.content)
        }
        try StoredText.addSource(store, "paper-clean", content: "Clean.")
        try store.enqueueStoredSoftHyphenRepair()

        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == StoredSoftHyphenRepairBatch(processedCount: 2, repairedSourceIDs: ["paper-a"]))
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == StoredSoftHyphenRepairBatch(processedCount: 1, repairedSourceIDs: ["paper-b"]))
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50, repairs: 5) == StoredSoftHyphenRepairBatch(processedCount: 1, repairedSourceIDs: ["paper-c"]))
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == .empty)
    }

    @Test("An article's literal &shy; goes where it splits a word; a mention of it stays")
    func articleEntity() throws {
        let store = try makeStore()
        let content = "The mito&shy;chondrion's regeneration-&shy;associated genes. Pages write &shy; to hint."
        let repaired = "The mitochondrion's regeneration-associated genes. Pages write &shy; to hint."
        try StoredText.addSource(store, "article-1", type: "article", title: "An article", content: content)
        try StoredText.addPreparation(store, "article-1", table: "article_content_preparations", raw: content, rawSHA: StoredText.sha(content), cleanSHA: StoredText.sha(content))
        try store.enqueueStoredSoftHyphenRepair()

        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50).repairedSourceIDs == ["article-1"])
        #expect(try store.loadSourceContent("article-1") == repaired)
        #expect(try StoredText.text(store, "SELECT raw_content FROM article_content_preparations WHERE source_id = ?", "article-1") == repaired)
        #expect(try StoredText.text(store, "SELECT clean_sha256 FROM article_content_preparations WHERE source_id = ?", "article-1") == StoredText.sha(repaired))
    }

    @Test("A title alone is repaired with its full-text row; the text and its embeddings stay")
    func titleAlone() throws {
        let store = try makeStore()
        // The one production title that held one, stored before titles dropped them.
        let title = "Plasma GDF15 affects long-\u{00AD} term dementia risk"
        try StoredText.addSource(store, "paper-title", title: title, content: "A clean text.")
        try store.replaceSourceFTS(sourceID: "paper-title", title: title, author: "", body: "A clean text.")
        try store.recordSourceIndexed(sourceID: "paper-title")
        try store.enqueueStoredSoftHyphenRepair()

        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50).repairedSourceIDs == ["paper-title"])
        #expect(try StoredText.text(store, "SELECT title FROM papers WHERE source_id = ?", "paper-title") == "Plasma GDF15 affects long- term dementia risk")
        #expect(try StoredText.count(store, "SELECT COUNT(*) FROM source_fts_state WHERE source_id = 'paper-title'") == 0, "the full-text row is written again")
        #expect(try StoredText.count(store, "SELECT COUNT(*) FROM source_index_state WHERE source_id = 'paper-title'") == 1, "the embeddings stay")
        #expect(try store.loadSourceContent("paper-title") == "A clean text.")
    }

    @Test("A podcast transcript's input is repaired under its own hash")
    func podcastInput() throws {
        let store = try makeStore()
        let input = "[SPEAKER_1]\nWe talked about life\u{00AD}span."
        let clean = "[SPEAKER_1]\nWe talked about lifespan."
        try StoredText.addSource(store, "podcast-1", type: "podcast", title: "An episode", content: nil)
        try store.execute("""
            INSERT INTO podcast_transcript_preparations (source_id, input_content, input_sha256, clean_sha256, cleaner_version, prepared_at)
            VALUES ('podcast-1', ?, ?, ?, 1, 1)
        """, [.text(input), .text(StoredText.sha(input)), .text(StoredText.sha(clean))])
        try store.enqueueStoredSoftHyphenRepair()

        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50).repairedSourceIDs == ["podcast-1"])
        #expect(try StoredText.text(store, "SELECT input_content FROM podcast_transcript_preparations WHERE source_id = ?", "podcast-1") == clean)
        #expect(try StoredText.text(store, "SELECT input_sha256 FROM podcast_transcript_preparations WHERE source_id = ?", "podcast-1") == StoredText.sha(clean))
        #expect(try StoredText.text(store, "SELECT clean_sha256 FROM podcast_transcript_preparations WHERE source_id = ?", "podcast-1") == StoredText.sha(clean))
        #expect(try StoredText.paidWork(store) == 0)
    }

    @Test("A store without the queue has nothing to drain")
    func missingQueue() throws {
        let store = try makeStore()
        try store.execForTesting("DROP TABLE source_text_soft_hyphen_repair_queue")
        #expect(try store.drainStoredSoftHyphenRepairBatch(limit: 50) == .empty)
        #expect(try store.storedSoftHyphenRepairQueueCount() == 0)
    }
}

/// The repair on a generation-2 store, where the outbox's triggers record what changes and
/// a source's text reaches the other devices as its `text` satellite.
@Suite("Stored soft hyphen repair under generation 2", .serialized)
struct StoredSoftHyphenRepairGeneration2Tests {
    typealias F = SourceSyncFixture

    private static let text = "Mitochondrial regeneration-\u{00AD}associated genes set life\u{00AD}span. " + String(repeating: "More text. ", count: 20)
    private static let repaired = "Mitochondrial regeneration-associated genes set lifespan. " + String(repeating: "More text. ", count: 20)

    /// An article another Mac published as its older build stored it.
    private static func record(_ id: String) throws -> ReplicaRecord {
        let body = Data(text.utf8)
        let file = FileRef(
            owner: id, role: "text", hash: SyncIdentity.sha256Hex(body), size: Int64(body.count),
            mime: "text/plain", encoding: "gzip", storedParts: [body]
        )
        return try F.record(.source, id, [
            "primaryKey": .string("native:\(id)"),
            "workKeys": .object(["native:\(id)": true]),
            "type": "article",
            "title": "Regeneration and life\u{00AD}span",
            "authors": .array(["Ada Researcher"]),
            "url": .string("https://example.org/\(id)"),
            "publishedAt": SyncJSON(Int64(1_767_225_600_000)),
            "status": "active",
            "ingest": .object(["ord": .array([1, 4]), "state": "ready", "at": SyncJSON(Int64(1_759_000_000_000)), "device": "macaaaaa"]),
            "meta": .object([:]),
            "addedAt": SyncJSON(Int64(1_759_100_000_000)),
            "madeBy": .object(["route": "app", "device": "macaaaaa", "at": SyncJSON(Int64(1_759_100_000_000))]),
            "files": .object(["text": file.value]),
            "contentHash": .string(SyncIdentity.sha256Hex(body)),
        ])
    }

    @Test("Text an older build on another Mac published is installed as sent, staged, and repaired by the next drain")
    func receivedTextIsStagedAndRepaired() async throws {
        let (root, store) = try F.makeStore("soft-hyphen-received")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let id = "src_5f0c1d2e3f405162738495a6b7c8d9e0"
        try F.apply(store, [try Self.record(id)])
        let body = Data(Self.text.utf8)
        let taken = await SatelliteReader(store: .direct(store)) { _ in body }.drain()
        #expect(taken == 1)
        #expect(try store.loadSourceContent(id) == Self.text, "the bytes the pointer names are what is installed")
        #expect(try store.storedSoftHyphenRepairQueueCount() == 1)
        try F.sendAll(store)

        let batch = try store.drainStoredSoftHyphenRepairBatch(limit: 50)

        #expect(batch.repairedSourceIDs == [id])
        #expect(try store.loadSourceContent(id) == Self.repaired)
        #expect(try F.text(store, "SELECT raw_content FROM article_content_preparations WHERE source_id = ?", [.text(id)]) == Self.repaired)
        #expect(try F.text(store, "SELECT clean_sha256 FROM article_content_preparations WHERE source_id = ?", [.text(id)]) == StoredText.sha(Self.repaired))
        // The repaired text goes up as the source's text satellite; the title, a field
        // of the record, through the outbox.
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND target = ?",
                            [.text(KnowledgeStore.sourcePublishKind), .text(id)]) == 1)
        #expect(F.savedFields(try F.pending(store)["Source:\(id)"])?["title"] == .string("Regeneration and lifespan"))
        #expect(try StoredText.paidWork(store) == 0)
    }
}

/// The launch's run of the repair, as the view model makes it before sync starts.
@Suite("Stored soft hyphen repair at launch", .serialized)
struct StoredSoftHyphenRepairLaunchTests {
    @Test("The loaded library drops the old text and takes the paper's new extraction hash")
    @MainActor
    func refreshesLoadedSources() async throws {
        let root = try Schema154Fixture.temporaryRoot("soft-hyphen-launch")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let store = try await storage.cohortKnowledgeStore()
        try StoredText.addSource(store, "paper-1", content: StoredText.content)
        try StoredText.addPreparation(store, "paper-1", raw: StoredText.raw, rawSHA: StoredText.sha(StoredText.raw), cleanSHA: StoredText.sha(StoredText.content))
        try store.enqueueStoredSoftHyphenRepair()
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        var loaded = try #require(try store.loadSources().first { $0.id == "paper-1" })
        #expect(loaded.paperContentSHA256 == StoredText.sha(StoredText.raw))
        loaded.content = StoredText.content
        vm.articles = [loaded]

        // Not before the library has loaded: the launch runs it then.
        await vm.runDeferredStoredSoftHyphenRepair()
        #expect(try store.storedSoftHyphenRepairQueueCount() == 1)

        vm.hasCompletedInitialQueueLoad = true
        await vm.runDeferredStoredSoftHyphenRepair()

        #expect(try store.storedSoftHyphenRepairQueueCount() == 0)
        #expect(try store.loadSourceContent("paper-1") == StoredText.repairedContent)
        let article = try #require(vm.articles.first)
        #expect(article.content == nil, "the old text is read again from storage")
        #expect(article.paperContentSHA256 == StoredText.sha(StoredText.repairedRaw))
    }
}
