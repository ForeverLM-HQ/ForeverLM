import Testing
import Foundation
import WebKit
@testable import ForeverLM

@Suite("PDF Payload Validation")
struct PDFPayloadValidationTests {
    @Test("Accepts PDF magic bytes at start of payload")
    func acceptsPDFMagicBytes() {
        let data = Data("%PDF-1.7\n".utf8)
        #expect(SourceService.looksLikePDFData(data))
    }

    @Test("Accepts PDF magic bytes after leading bytes")
    func acceptsPDFMagicBytesAfterLeadingBytes() {
        let data = Data("\u{FEFF}\n%PDF-1.7\n".utf8)
        #expect(SourceService.looksLikePDFData(data))
    }

    @Test("Rejects HTML served as a PDF response")
    func rejectsHTMLPayload() {
        let data = Data("<html><body>not a PDF</body></html>".utf8)
        #expect(!SourceService.looksLikePDFData(data))
    }

    @Test("Rejects a DOCTYPE landing page saved as a PDF")
    func rejectsDoctypeLandingPage() {
        let data = Data("<!DOCTYPE html>\n<html><head><title>scGen … | Nature Methods</title>".utf8)
        #expect(!SourceService.looksLikePDFData(data))
    }

    @Test("Rejects a landing page with leading whitespace before the markup")
    func rejectsLandingPageWithLeadingWhitespace() {
        let data = Data("\n\n\n\n<!DOCTYPE html><html><head></head></html>".utf8)
        #expect(!SourceService.looksLikePDFData(data))
    }

    @Test("Rejects the NCBI 'Preparing to download…' proof-of-work interstitial")
    func rejectsPMCProofOfWorkInterstitial() {
        // The real interstitial: leading newlines, then <html>, and it references a
        // JS bundle — none of which is a PDF. Include a stray "%PDF-" token to prove
        // the marker alone is not enough to be accepted.
        let data = Data("""
        \n\n\n\n<html><head><title>Preparing to download ...</title>
        <script>const POW_CHALLENGE = "abc";/* not a %PDF- */</script></head></html>
        """.utf8)
        #expect(!SourceService.looksLikePDFData(data))
    }

    @Test("Rejects the PMC 'Lock' bot-block page")
    func rejectsPMCLockPage() {
        let data = Data("<!DOCTYPE html><html><head><title>Lock</title></head><body></body></html>".utf8)
        #expect(!SourceService.looksLikePDFData(data))
    }

    @Test("Rejects an empty payload")
    func rejectsEmptyPayload() {
        #expect(!SourceService.looksLikePDFData(Data()))
    }
}

@Suite("Publisher PDF download control")
struct PublisherPDFDownloadControlTests {
    @MainActor
    @Test("A cited PDF cannot outrank the current article PDF")
    func citedPDFDoesNotOutrankArticlePDF() async throws {
        let webView = try await loadedPage("""
            <main>
              <section class="c-article-references">
                <a id="cited" href="https://example.org/papers/hyenadna.pdf">PDF</a>
              </section>
              <a id="article" href="/articles/s41592-026-03064-3_reference.pdf">PDF</a>
            </main>
            """)

        let result = try await clickResult(in: webView)
        #expect(result.clicked)
        #expect(result.elementID == "article")
    }

    @MainActor
    @Test("A bibliography PDF alone is not mistaken for the article download")
    func bibliographyPDFAloneIsRejected() async throws {
        let webView = try await loadedPage("""
            <ol class="references">
              <li><a id="cited" href="https://example.org/papers/hyenadna.pdf">Download PDF</a></li>
            </ol>
            """)

        let result = try await clickResult(in: webView)
        #expect(!result.clicked)
        #expect(result.elementID == nil)
    }

    @MainActor
    @Test("An explicitly named publisher control may use a separate PDF host")
    func namedCrossHostControlIsAccepted() async throws {
        let webView = try await loadedPage("""
            <main><a id="article" href="https://cdn.publisher.example/files/file.pdf">Download PDF</a></main>
            """)

        let result = try await clickResult(in: webView)
        #expect(result.clicked)
        #expect(result.elementID == "article")
    }

    @MainActor
    private func loadedPage(_ html: String) async throws -> WKWebView {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        await waiter.load(
            "<!doctype html><html><body>\(html)</body></html>",
            baseURL: URL(string: "https://www.nature.com/articles/s41592-026-03064-3")!,
            in: webView
        )
        _ = try await webView.evaluateJavaScript("""
            window.__clickedPDFControl = null;
            document.addEventListener('click', (event) => {
              event.preventDefault();
              window.__clickedPDFControl = event.target.id || null;
            }, true);
            """)
        return webView
    }

    @MainActor
    private func clickResult(in webView: WKWebView) async throws -> (clicked: Bool, elementID: String?) {
        let clicked = try await webView.evaluateJavaScript(PublisherPDFDownloadControl.clickScript) as? Bool ?? false
        let elementID = try await webView.evaluateJavaScript("window.__clickedPDFControl") as? String
        return (clicked, elementID)
    }

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func load(_ html: String, baseURL: URL, in webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                continuation?.resume()
                continuation = nil
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                continuation?.resume()
                continuation = nil
            }
        }
    }
}

@Suite("Google Docs Source Loading")
/// The reader's own fetch of a paper's PDF: what each answer means, and which
/// are worth asking again.
struct RemotePDFLoaderTests {
    @Test("Statuses map to failures: a 429 is a pause, not a refusal of the file")
    func statusesMapToFailures() {
        #expect(RemotePDFLoader.failure(forStatus: 200, host: "www.medrxiv.org") == nil)
        #expect(RemotePDFLoader.failure(forStatus: 403, host: "www.medrxiv.org") == .paywalled(host: "www.medrxiv.org"))
        #expect(RemotePDFLoader.failure(forStatus: 404, host: "www.medrxiv.org") == .notFound(host: "www.medrxiv.org"))
        #expect(RemotePDFLoader.failure(forStatus: 429, host: "www.medrxiv.org") == .rateLimited(host: "www.medrxiv.org"))
        #expect(RemotePDFLoader.failure(forStatus: 503, host: "www.medrxiv.org") == .serverError(status: 503, host: "www.medrxiv.org"))

        let limited = RemotePDFLoadFailure.rateLimited(host: "www.medrxiv.org")
        #expect(limited.isRateLimit)
        #expect(!limited.isPaywall)
        // Attaching a file by hand is not the answer to a count of requests.
        #expect(!limited.suggestsManualAttachment)
        #expect(limited.title == "medrxiv.org is asking for a pause")
        #expect(limited.message.contains("HTTP 429"))
        #expect(!RemotePDFLoadFailure.serverError(status: 503, host: nil).isRateLimit)
        // Two retries, spaced so three attempts fit in about ten seconds.
        #expect(RemotePDFLoader.rateLimitRetryDelays.count == 2)
        #expect(RemotePDFLoader.rateLimitRetryDelays.reduce(Duration.zero, +) <= .seconds(12))
    }
}

struct GoogleDocsSourceLoadingTests {
    @Test("Extracts document IDs from standard Google Docs URLs")
    func extractsDocumentIDs() throws {
        let editURL = try #require(URL(string: "https://docs.google.com/document/d/document-123/edit?tab=t.0"))
        let accountURL = try #require(URL(string: "https://docs.google.com/document/u/0/d/document-456/edit"))

        #expect(SourceService.googleDocumentID(from: editURL) == "document-123")
        #expect(SourceService.googleDocumentID(from: accountURL) == "document-456")
    }

    @Test("Does not treat published or unrelated Google URLs as Drive document IDs")
    func rejectsUnsupportedGoogleURLs() throws {
        let publishedURL = try #require(URL(string: "https://docs.google.com/document/d/e/2PACX-example/pub"))
        let sheetURL = try #require(URL(string: "https://docs.google.com/spreadsheets/d/sheet-123/edit"))

        #expect(SourceService.googleDocumentID(from: publishedURL) == nil)
        #expect(SourceService.googleDocumentID(from: sheetURL) == nil)
    }

    @Test("Detects JavaScript-disabled Google Docs interface placeholders")
    func detectsInterfacePlaceholder() {
        let placeholder = """
        Google Docs
        JavaScript isn't enabled in your browser, so this file can't be opened.
        Enable and reload.
        """
        let sheetsBanner = """
        Google Sheets
        This browser version is no longer supported. Please upgrade to a supported browser.
        """

        #expect(SourceService.isGoogleDocsInterfaceContent(placeholder))
        #expect(SourceService.isGoogleDocsInterfaceContent(sheetsBanner))
        #expect(!SourceService.isGoogleDocsInterfaceContent("Pfleger's detailed feedback on the manuscript."))
    }

    @Test("Recognizes Sheets and Slides alongside Docs")
    func recognizesDocsFamily() throws {
        let sheetURL = try #require(URL(string: "https://docs.google.com/spreadsheets/d/sheet-123/edit#gid=87654321"))
        let slidesURL = try #require(URL(string: "https://docs.google.com/presentation/d/deck-123/edit"))
        let docURL = try #require(URL(string: "https://docs.google.com/document/d/document-123/edit?tab=t.0"))

        let sheet = try #require(SourceService.googleDocsResource(from: sheetURL))
        #expect(sheet.kind == .spreadsheet)
        #expect(sheet.id == "sheet-123")
        #expect(sheet.gid == "87654321")

        let slides = try #require(SourceService.googleDocsResource(from: slidesURL))
        #expect(slides.kind == .presentation)
        #expect(slides.id == "deck-123")

        #expect(SourceService.googleDocsResource(from: docURL)?.kind == .document)
        #expect(SourceService.googleDocsResource(from: try #require(URL(string: "https://example.com/spreadsheets/d/x/edit"))) == nil)
        #expect(SourceService.googleDocsResource(from: try #require(URL(string: "https://docs.google.com/forms/d/form-1/viewform"))) == nil)
    }

    @Test("Builds Google's own export URL per file kind")
    func buildsExportURLs() throws {
        let sheetWithTab = try #require(URL(string: "https://docs.google.com/spreadsheets/d/sheet-123/edit#gid=42"))
        let sheetWithoutTab = try #require(URL(string: "https://docs.google.com/spreadsheets/d/sheet-123/edit"))
        let slides = try #require(URL(string: "https://docs.google.com/presentation/d/deck-123/edit"))
        let doc = try #require(URL(string: "https://docs.google.com/document/d/document-123/edit"))

        func exportURL(_ url: URL) throws -> String {
            SourceService.googleDocsExportURL(for: try #require(SourceService.googleDocsResource(from: url))).absoluteString
        }

        #expect(try exportURL(sheetWithTab)
            == "https://docs.google.com/spreadsheets/d/sheet-123/export?format=csv&gid=42")
        #expect(try exportURL(sheetWithoutTab)
            == "https://docs.google.com/spreadsheets/d/sheet-123/export?format=csv")
        #expect(try exportURL(slides) == "https://docs.google.com/presentation/d/deck-123/export/txt")
        #expect(try exportURL(doc) == "https://docs.google.com/document/d/document-123/export?format=txt")
    }

    @Test("Turns a spreadsheet CSV export into readable rows")
    func convertsCSVToReadableRows() {
        let csv = #"""
        Title,Category,Description\#r
        "Feynman, Richard",Physics,"Lectures\#non computation",,\#r
        Empty,,\#r
        ,,\#r
        Quoted,"He said ""hi""",Done
        """#

        #expect(SourceService.readableTextFromCSV(csv) == #"""
        Title | Category | Description
        Feynman, Richard | Physics | Lectures on computation
        Empty
        Quoted | He said "hi" | Done
        """#)
    }
}

@Suite("Figshare Source Loading")
struct FigshareSourceLoadingTests {
    @Test("Resolves Figshare collection and article URLs to public API records")
    func resolvesWebURLs() throws {
        let collection = try #require(URL(string: "https://plus.figshare.com/collections/Human_Biofluid_Image_Inventory/8260588/1"))
        let article = try #require(URL(string: "https://figshare.com/articles/dataset/Example/12345678/2"))

        #expect(SourceService.figshareResource(from: collection) == .init(kind: .collections, id: "8260588"))
        #expect(SourceService.figshareResource(from: article) == .init(kind: .articles, id: "12345678"))
    }

    @Test("Resolves Figshare DOI URLs without treating the version as the record ID")
    func resolvesDOIURLs() throws {
        let collection = try #require(URL(string: "https://doi.org/10.25452/figshare.plus.c.8260588.v2"))
        let article = try #require(URL(string: "https://doi.org/10.6084/m9.figshare.12345678.v3"))

        #expect(SourceService.figshareResource(from: collection) == .init(kind: .collections, id: "8260588"))
        #expect(SourceService.figshareResource(from: article) == .init(kind: .articles, id: "12345678"))
    }

    @Test("Rejects lookalike hosts")
    func rejectsLookalikeHosts() throws {
        let url = try #require(URL(string: "https://notfigshare.com/collections/example/8260588"))
        #expect(SourceService.figshareResource(from: url) == nil)
    }

    @Test("Decodes the canonical Figshare title, compact author line, and description")
    func decodesMetadata() throws {
        let data = try #require("""
        {
          "title": "Human Biofluid Image Inventory: Electron Microscopy Analysis of Circulating Particles from cf-mtDNA-enriched Biofluids",
          "description": "<p>Collection abstract.</p>",
          "authors": [
            {"full_name": "Alexandra Volos"},
            {"full_name": "Soah Grace Franklin"},
            {"full_name": "Martin Picard"}
          ]
        }
        """.data(using: .utf8))

        let metadata = SourceService.decodeFigshareMetadata(from: data)
        #expect(metadata?.title == "Human Biofluid Image Inventory: Electron Microscopy Analysis of Circulating Particles from cf-mtDNA-enriched Biofluids")
        #expect(metadata?.author == "Alexandra Volos et al.")
        #expect(metadata?.descriptionHTML == "<p>Collection abstract.</p>")
    }
}

@Suite("Podcast TTML Extraction")
struct PodcastTTMLExtractionTests {
    @Test("Extracts speaker text from single quoted TTML attributes")
    func extractsSingleQuotedAttributes() throws {
        let ttml = """
        <tt xmlns:podcasts="http://podcasts.apple.com/transcript-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin='0.0' end='1.0' ttm:agent='SPEAKER_1'>
                <span podcasts:unit='word'>Hello</span>
                <span podcasts:unit='word'>R&amp;D</span>
                <span podcasts:unit='word'>team.</span>
              </p>
              <p begin='1.0' end='2.0' agent='SPEAKER_2'>Thanks for having me.</p>
            </div>
          </body>
        </tt>
        """

        let extracted = try SourceService.extractTextFromTTMLContent(ttml)

        #expect(extracted.contains("[SPEAKER_1]\nHello R&D team."))
        #expect(extracted.contains("[SPEAKER_2]\nThanks for having me."))
    }
}

@Suite("Podcast TTML Display Parsing")
struct PodcastTTMLDisplayParsingTests {
    // A transcript the retired 50,000-character cap cut is recognised by where
    // it stops in its episode's TTML text, not by its length: formatting pushes
    // a capped one past 50,000 and the ad pass pulls a complete one under it.
    // See PodcastTranscriptCompletenessTests.

    @Test("Preserves readable paragraphs for long same-speaker runs")
    func preservesReadableParagraphsForLongSameSpeakerRuns() {
        let first = repeatedSentence(
            "Mitochondria organize energy flow across muscle cells during repeated stress.",
            count: 6
        )
        let second = repeatedSentence(
            "The speaker connects those structures to adaptation, repair, and disease risk.",
            count: 6
        )
        let ttml = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="0.0" end="30.0" ttm:agent="SPEAKER_1">\(first)</p>
              <p begin="30.0" end="60.0" ttm:agent="SPEAKER_1">\(second)</p>
              <p begin="60.0" end="63.0" ttm:agent="SPEAKER_2">Thanks for explaining that.</p>
            </div>
          </body>
        </tt>
        """

        let segments = PodcastTranscriptParser.parseTTML(ttml)

        #expect(segments.count == 2)
        #expect(segments[0].speakerID == "SPEAKER_1")
        #expect(segments[0].text.contains("\n\n"))
        #expect(segments[0].text.contains(first))
        #expect(segments[0].text.contains(second))
    }

    @Test("Splits oversized single-speaker TTML paragraphs")
    func splitsOversizedSingleSpeakerTTMLParagraphs() {
        let monologue = repeatedSentence(
            "Energy demand changes mitochondrial structure before metabolism reaches a new steady state.",
            count: 24
        )
        let ttml = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="0.0" end="120.0" ttm:agent="SPEAKER_1">\(monologue)</p>
            </div>
          </body>
        </tt>
        """

        let segments = PodcastTranscriptParser.parseTTML(ttml)

        #expect(segments.count == 1)
        #expect(segments[0].text.contains("\n\n"))
        #expect(segments[0].text.contains("Energy demand changes"))
    }

    private func repeatedSentence(_ sentence: String, count: Int) -> String {
        Array(repeating: sentence, count: count).joined(separator: " ")
    }
}

// MARK: - Supplementary PDF URLs

/// A PDF that belongs to a paper without being the paper — Nature's Reporting
/// Summary and Source Data under `MediaObjects`, a `/suppl/` file — is never
/// taken for the paper, whichever route offered it.
@Suite("Supplementary PDF URLs")
struct SupplementaryPDFURLTests {
    @Test("A publisher's PDF viewer page names the file it shows")
    func viewerPageNamesItsPDF() {
        // JCI Insight: /articles/view/<id>/pdf is HTML around a Download PDF
        // form and an iframe a script points at render.pdf; no citation_pdf_url.
        let html = """
        <!DOCTYPE html><html><head><title>JCI Insight - Allotopic Expression of ND6</title></head><body>
        <form id="download_pdf_form" action="/articles/view/209108/version/1/pdf/render.pdf"> <button>Download PDF  (6.26 MB)</button>
        <input type="hidden" id="recaptcha-token-RENDER_PDF" name="g-recaptcha-response" value="empty"/></form>
        <div id='asset_display'><iframe id='asset_source' src=''></iframe></div>
        <script>$(document).ready(function() { document.getElementById('asset_source').src = "/articles/view/209108/version/1/pdf/render.pdf"; });</script>
        </body></html>
        """
        let page = URL(string: "https://insight.jci.org/articles/view/209108/pdf")!
        #expect(PaperService.extractPDFURL(fromHTML: html, relativeTo: page) == "https://insight.jci.org/articles/view/209108/version/1/pdf/render.pdf")
        #expect(PaperService.looksLikeHTMLDocument(html))
        #expect(!PaperService.looksLikeHTMLDocument("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3} 1 0 obj"))
    }

    @Test("Atypon's cloud reader page names the paper's PDF, or its address does")
    func atyponReaderPageNamesItsPDF() {
        // Science: the PDF button is /doi/reader/<doi>, which lands on
        // /doi/epdf/<doi> — HTML around a PDF renderer fed by script from a
        // signed /doi/pdfdirect/ address; no citation_pdf_url, no frame, no form.
        let html = """
        <!DOCTYPE html><html><head><title>The missing piece</title></head><body>
        <a href="/action/ssostart?redirectUri=%2Fdoi%2Fepdf%2F10.1126%2Fscience.aec9580">Sign in</a>
        <a aria-label="Download PDF • 1.2 MB" class="navbar-download btn" href="/doi/pdf/10.1126/science.aec9580?download=true" target="_blank" title="Download" data-download-files-key="pdf"><span class="icon material-icons">get_app</span></a>
        <script>window.reader = {"epubConfig":{"epubUrl":"/doi/pdfdirect/10.1126/science.aec9580?hmac\\u003d1790029739-Q7Ze"}};</script>
        </body></html>
        """
        let page = URL(string: "https://www.science.org/doi/epdf/10.1126/science.aec9580")!
        #expect(PaperService.extractPDFURL(fromHTML: html, relativeTo: page) == "https://www.science.org/doi/pdf/10.1126/science.aec9580?download=true")
        #expect(!PaperService.isSupplementaryPDFURL("https://www.science.org/doi/pdf/10.1126/science.aec9580?download=true"))

        // An access wall in the viewer's place has no Download control; the
        // viewer's own address still names the paper.
        let wall = """
        <html><head><title>Science</title></head><body>
        <a href="/action/ssostart?redirectUri=%2Fdoi%2Fepdf%2F10.1126%2Fscience.aec9580">Sign in</a>
        <a href="https://www.science.org/action/registration?redirectUri=%2Fdoi%2Fepdf%2F10.1126%2Fscience.aec9580">Register</a>
        </body></html>
        """
        #expect(PaperService.extractPDFURL(fromHTML: wall, relativeTo: page) == "https://www.science.org/doi/pdf/10.1126/science.aec9580")
        let reader = URL(string: "https://www.science.org/doi/reader/10.1126/science.aec9580")!
        #expect(PaperService.extractPDFURL(fromHTML: wall, relativeTo: reader) == "https://www.science.org/doi/pdf/10.1126/science.aec9580")

        // A /doi/pdf/ link to another host, or a non-viewer page with none of
        // its own, is not this paper.
        let elsewhere = """
        <html><body><a href="https://www.pnas.org/doi/pdf/10.1073/pnas.1721683115">A cited paper</a></body></html>
        """
        #expect(PaperService.extractPDFURL(fromHTML: elsewhere, relativeTo: URL(string: "https://example.org/articles/1")!) == nil)
    }

    @Test("A viewer page's other frames and forms are not the paper")
    func viewerPageFramesThatAreNotPDFs() {
        let html = """
        <html><body>
        <form action="/search"><input name="q"></form>
        <iframe src="https://www.youtube.com/embed/abc"></iframe>
        <iframe src="/articles/view/1/MediaObjects/supplement.pdf"></iframe>
        <embed src="/articles/view/1/version/1/pdf/render.pdf" type="application/pdf">
        </body></html>
        """
        let page = URL(string: "https://insight.jci.org/articles/view/1/pdf")!
        #expect(PaperService.extractPDFURL(fromHTML: html, relativeTo: page) == "https://insight.jci.org/articles/view/1/version/1/pdf/render.pdf", "the supplement is skipped, the paper behind it found")
        let noPaper = html.replacingOccurrences(of: "<embed src=\"/articles/view/1/version/1/pdf/render.pdf\" type=\"application/pdf\">", with: "")
        #expect(PaperService.extractPDFURL(fromHTML: noPaper, relativeTo: page) == nil)
    }

    @Test("Nature MediaObjects, ESM, suppl and reporting-summary files are supplementary")
    func supplementaryFilesAreRecognized() {
        for url in [
            "https://static-content.springer.com/esm/art%3A10.1038%2Fs41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM1_ESM.pdf",
            "https://www.nature.com/articles/s41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM2_ESM.pdf",
            "https://www.cell.com/cms/10.1016/j.cmet.2014.05.006/attachment/abc/mmc1.pdf?supplementary=1",
            "https://www.science.org/doi/suppl/10.1126/science.abc1234/suppl_file/science.abc1234_sm.pdf",
            "https://www.pnas.org/doi/suppl/10.1073/pnas.1721683115",
            "https://example.org/papers/reporting-summary.pdf",
        ] {
            #expect(PaperService.isSupplementaryPDFURL(url), "\(url)")
        }
    }

    @Test("The paper's own PDF is not")
    func paperPDFsAreNot() {
        for url in [
            "https://www.nature.com/articles/s41593-026-02421-x.pdf",
            "https://www.nature.com/articles/s41593-026-02421-x_reference.pdf",
            "https://export.arxiv.org/pdf/2401.01234.pdf",
            "https://www.biorxiv.org/content/10.1101/2024.01.01.573000v1.full.pdf",
            "https://www.cell.com/action/showPdf?pii=S1550-4131(16)30428-4",
            "https://journals.plos.org/plosone/article/file?id=10.1371/journal.pone.0000001&type=printable",
        ] {
            #expect(!PaperService.isSupplementaryPDFURL(url), "\(url)")
        }
    }

    @Test("A page whose only advertised PDF is supplementary yields no link")
    func pageExtractionSkipsSupplementary() {
        let html = """
        <html><head>
        <meta name="citation_pdf_url" content="https://www.nature.com/articles/s41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM1_ESM.pdf">
        <link rel="alternate" type="application/pdf" href="/articles/s41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM2_ESM.pdf">
        </head><body>
        <a data-article-pdf="true" href="/articles/s41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM1_ESM.pdf">Reporting Summary</a>
        </body></html>
        """
        let page = URL(string: "https://www.nature.com/articles/s41593-026-02421-x")!
        #expect(PaperService.extractPDFURL(fromHTML: html, relativeTo: page) == nil)

        let withPaper = html.replacingOccurrences(
            of: "<a data-article-pdf=\"true\" href=\"/articles/s41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM1_ESM.pdf\">Reporting Summary</a>",
            with: "<a data-article-pdf=\"true\" href=\"/articles/s41593-026-02421-x.pdf\">Download PDF</a>"
        )
        #expect(PaperService.extractPDFURL(fromHTML: withPaper, relativeTo: page) == "https://www.nature.com/articles/s41593-026-02421-x.pdf")
    }
}

// MARK: - Article metadata answer

@Suite("Article metadata answer")
struct ArticleMetadataAnswerTests {
    @Test("The request labels every title the page offered")
    func requestCarriesEvidence() {
        var evidence = PaperService.WebArticleTitleEvidence()
        evidence.documentTitle = "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners"
        evidence.siteName = "Amplify Partners"
        evidence.headline = "Waypoint Bio: Immune Engineering"
        let request = AIService.articleMetadataRequest(
            currentTitle: "Waypoint Bio: Immune Engineering \u{2014} Amplify Partners",
            url: "https://www.amplifypartners.com/blog-posts/waypoint-bio-immune-engineering",
            evidence: evidence,
            content: "Blog\nMay 2026\nWaypoint Bio: Immune Engineering\nBy Amplify Partners"
        )
        #expect(request.hasPrefix("URL: https://www.amplifypartners.com/blog-posts/waypoint-bio-immune-engineering\nCurrent title in the library: Waypoint Bio: Immune Engineering \u{2014} Amplify Partners"))
        #expect(request.contains("- <title>: Waypoint Bio: Immune Engineering \u{2014} Amplify Partners"))
        #expect(request.contains("- og:title: (none)"))
        #expect(request.contains("- Site name: Amplify Partners"))
        #expect(request.contains("- First <h1>: Waypoint Bio: Immune Engineering"))
        #expect(request.contains("Opening of the text:\nBlog\nMay 2026"))
    }

    @Test("Without the page, the request is the address, the title held and the text")
    func requestWithoutEvidence() {
        let request = AIService.articleMetadataRequest(currentTitle: "example.com", url: "https://example.com/a", evidence: nil, content: nil)
        #expect(request == "URL: https://example.com/a\nCurrent title in the library: example.com")
    }

    @Test("The answer is read line by line; a quoted title is unwrapped and a blank, host-only or endless one is no title")
    func answerIsParsed() {
        let url = "https://www.waypointbio.com/writings/out-of-distribution-medicines"
        let good = AIService.parseArticleMetadataResponse("TITLE: \u{201C}Building Out-of-Distribution Medicines\u{201D}\nAUTHOR: Waypoint Bio\nYEAR: 2026", url: url)
        #expect(good?.title == "Building Out-of-Distribution Medicines")
        #expect(good?.author == "Waypoint Bio")
        #expect(good?.year == "2026")
        let hostOnly = AIService.parseArticleMetadataResponse("TITLE: www.waypointbio.com\nAUTHOR: ?\nYEAR: ?", url: url)
        #expect(hostOnly == nil)
        let bareHost = AIService.parseArticleMetadataResponse("TITLE: waypointbio.com\nAUTHOR: ?\nYEAR: 2026", url: url)
        #expect(bareHost?.title == nil)
        #expect(bareHost?.year == "2026")
        let endless = AIService.parseArticleMetadataResponse("TITLE: \(String(repeating: "x", count: 300))\nAUTHOR: ?\nYEAR: ?", url: url)
        #expect(endless == nil)
        #expect(AIService.parseArticleMetadataResponse("I cannot determine that.", url: url) == nil)
    }
}

// MARK: - Paper PDF URL Conversion

@Suite("Paper PDF URL Conversion")
struct PaperPDFURLTests {

    // -- arXiv --

    @Test("Converts arXiv abstract URL to PDF")
    func arxivAbsToPDF() {
        let result = PaperService.paperPDFURL(from: "https://arxiv.org/abs/2301.07041")
        #expect(result == "https://export.arxiv.org/pdf/2301.07041.pdf")
    }

    @Test("Converts arXiv DOI link to PDF")
    func arxivDOI() {
        let result = PaperService.paperPDFURL(from: "https://doi.org/10.48550/arXiv.2301.07041")
        #expect(result == "https://export.arxiv.org/pdf/2301.07041.pdf")
    }

    @Test("Returns already-PDF arXiv URL as-is")
    func arxivAlreadyPDF() {
        let result = PaperService.paperPDFURL(from: "https://arxiv.org/pdf/2301.07041.pdf")
        #expect(result == "https://arxiv.org/pdf/2301.07041.pdf")
    }

    // -- bioRxiv / medRxiv --

    @Test("Converts bioRxiv DOI to PDF")
    func biorxivDOI() {
        let result = PaperService.paperPDFURL(from: "https://doi.org/10.1101/2024.01.15.123456")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2024.01.15.123456.full.pdf")
    }

    @Test("Converts bioRxiv abstract page to PDF")
    func biorxivAbstract() {
        let result = PaperService.paperPDFURL(from: "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1.full.pdf")
    }

    @Test("Strips .full suffix from bioRxiv before adding .full.pdf")
    func biorxivFullSuffix() {
        let result = PaperService.paperPDFURL(from: "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1.full")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1.full.pdf")
    }

    @Test("Converts medRxiv URL to PDF")
    func medrxiv() {
        let result = PaperService.paperPDFURL(from: "https://www.medrxiv.org/content/10.1101/2024.02.20.567890v1")
        #expect(result == "https://www.medrxiv.org/content/10.1101/2024.02.20.567890v1.full.pdf")
    }

    @Test("Strips query params from bioRxiv DOI")
    func biorxivDOIWithQuery() {
        let result = PaperService.paperPDFURL(from: "https://doi.org/10.1101/2024.01.15.123456?ref=pdf")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2024.01.15.123456.full.pdf")
    }

    // -- Nature --

    @Test("Converts Nature article to PDF")
    func natureArticle() {
        let result = PaperService.paperPDFURL(from: "https://www.nature.com/articles/s41586-024-07386-0")
        #expect(result == "https://www.nature.com/articles/s41586-024-07386-0.pdf")
    }

    @Test("Converts Nature DOI to PDF")
    func natureDOI() {
        let result = PaperService.paperPDFURL(from: "https://doi.org/10.1038/s41586-024-07386-0")
        #expect(result == "https://www.nature.com/articles/s41586-024-07386-0.pdf")
    }

    @Test("Strips query params from Nature URL")
    func natureWithQuery() {
        let result = PaperService.paperPDFURL(from: "https://www.nature.com/articles/s41586-024-07386-0?fromSearch=true")
        #expect(result == "https://www.nature.com/articles/s41586-024-07386-0.pdf")
    }

    @Test("Prefers article download button over stale citation PDF meta tag")
    func articleDownloadButtonBeatsStaleCitationMeta() throws {
        let html = """
        <html>
          <head>
            <meta name="citation_pdf_url" content="https://www.nature.com/articles/s42003-026-10312-x.pdf"/>
          </head>
          <body>
            <a href="/articles/s42003-026-10312-x_reference.pdf" data-article-pdf="true" data-test="download-pdf">
              Download PDF
            </a>
          </body>
        </html>
        """
        let result = PaperService.extractPDFURL(
            fromHTML: html,
            relativeTo: try #require(URL(string: "https://www.nature.com/articles/s42003-026-10312-x"))
        )
        #expect(result == "https://www.nature.com/articles/s42003-026-10312-x_reference.pdf")
    }

    @Test("Finds PDF metadata beyond the retired head fallback cap")
    func findsLatePDFMetadataWithoutClosingHeadTag() throws {
        let padding = String(repeating: "x", count: 25_000)
        let html = "<html><head>\(padding)<meta name=\"citation_pdf_url\" content=\"/complete-paper.pdf\">"

        let result = PaperService.extractPDFURL(
            fromHTML: html,
            relativeTo: try #require(URL(string: "https://example.org/article"))
        )

        #expect(result == "https://example.org/complete-paper.pdf")
    }

    // -- PMC --

    @Test("PMC article URL returns nil (delegates to EuropePMC lookup)")
    func pmcArticle() {
        let result = PaperService.paperPDFURL(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1234567/")
        #expect(result == nil)
    }

    @Test("PMC article URL without slash also returns nil")
    func pmcNoSlash() {
        let result = PaperService.paperPDFURL(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1234567")
        #expect(result == nil)
    }

    // -- ScienceDirect --

    @Test("Converts ScienceDirect PII landing page to pdfft PDF endpoint")
    func scienceDirectPIIPage() {
        let result = PaperService.paperPDFURL(from: "https://www.sciencedirect.com/science/article/pii/S1568163724001284")
        #expect(result == "https://www.sciencedirect.com/science/article/pii/S1568163724001284/pdfft?isDTMRedir=true&download=true")
    }

    @Test("Converts ScienceDirect abstract PII page to canonical pdfft PDF endpoint")
    func scienceDirectAbstractPIIPage() {
        let result = PaperService.paperPDFURL(from: "https://www.sciencedirect.com/science/article/abs/pii/S1568163724001284?via%3Dihub")
        #expect(result == "https://www.sciencedirect.com/science/article/pii/S1568163724001284/pdfft?isDTMRedir=true&download=true")
    }

    @Test("Keeps ScienceDirect pdfft URL and adds download query")
    func scienceDirectPDFEndpoint() {
        let result = PaperService.paperPDFURL(from: "https://www.sciencedirect.com/science/article/pii/S1568163724001284/pdfft?md5=abc")
        #expect(result == "https://www.sciencedirect.com/science/article/pii/S1568163724001284/pdfft?md5=abc&isDTMRedir=true&download=true")
    }

    // -- Generic DOI landing pages --

    @Test("Converts NEJM full DOI page to PDF")
    func nejmFullDOIPage() {
        let result = PaperService.paperPDFURL(from: "https://www.nejm.org/doi/full/10.1056/NEJMoa2307817")
        #expect(result == "https://www.nejm.org/doi/pdf/10.1056/NEJMoa2307817")
    }

    @Test("Converts generic DOI abstract page to PDF")
    func genericDOIAbstractPage() {
        let result = PaperService.paperPDFURL(from: "https://example-journal.org/doi/abs/10.1234/example.paper?download=true")
        #expect(result == "https://example-journal.org/doi/pdf/10.1234/example.paper")
    }

    @Test("Converts Atypon viewer pages to the PDF they show")
    func atyponViewerPages() {
        #expect(PaperService.paperPDFURL(from: "https://www.science.org/doi/reader/10.1126/science.aec9580") == "https://www.science.org/doi/pdf/10.1126/science.aec9580")
        #expect(PaperService.paperPDFURL(from: "https://www.science.org/doi/epdf/10.1126/science.aec9580") == "https://www.science.org/doi/pdf/10.1126/science.aec9580")
    }

    @Test("Keeps generic DOI PDF page as PDF")
    func genericDOIPDFPage() {
        let result = PaperService.paperPDFURL(from: "https://example-journal.org/doi/pdf/10.1234/example.paper")
        #expect(result == "https://example-journal.org/doi/pdf/10.1234/example.paper")
    }

    // PLOS, eLife, Frontiers, MDPI, PeerJ: handled by extractPDFURLFromWebPage() fallback
    // (reads citation_pdf_url meta tag from the page) — no hardcoded URL patterns needed.

    // -- Negative / edge cases --

    @Test("Returns nil for unknown domain")
    func unknownDomain() {
        let result = PaperService.paperPDFURL(from: "https://example.com/paper")
        #expect(result == nil)
    }

    @Test("Returns direct PDF link as-is for any domain")
    func directPDFLink() {
        let result = PaperService.paperPDFURL(from: "https://example.com/paper.pdf")
        #expect(result == "https://example.com/paper.pdf")
    }

    @Test("Returns nil for empty string")
    func emptyString() {
        let result = PaperService.paperPDFURL(from: "")
        #expect(result == nil)
    }
}


/// Security audit, 2026-11-12: a URL import (from the app or any MCP client)
/// fetched loopback, link-local and private addresses.
@Suite("Outbound address policy")
struct OutboundAddressPolicyTests {
    @Test("Names and literals of this Mac or its network are refused")
    func privateHostsAreRefused() {
        for host in [
            "localhost", "LOCALHOST.", "printer.local", "app.localhost", "db.internal", "router.home.arpa", "intranet",
            "127.0.0.1", "127.1", "2130706433", "0x7f.0.0.1", "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "255.255.255.255",
            "::1", "[::1]", "::", "fe80::1", "fd00::1", "fc00::1", "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::a9fe:a9fe",
        ] {
            #expect(!OutboundAddressPolicy.isPublicHostName(host), "\(host)")
        }
        for host in ["example.com", "arxiv.org", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            #expect(OutboundAddressPolicy.isPublicHostName(host), "\(host)")
        }
    }

    @Test("A fetch to a private address is refused before it is made")
    func checkRefusesBeforeTheFetch() async throws {
        for address in ["http://127.0.0.1:8765/mcp", "http://[::1]/", "https://169.254.169.254/latest/meta-data", "file:///etc/hosts", "http://localhost/"] {
            await #expect(throws: OutboundAddressPolicy.Refusal.self, "\(address)") {
                try await OutboundAddressPolicy.check(try #require(URL(string: address)))
            }
        }
        try await OutboundAddressPolicy.check(try #require(URL(string: "https://8.8.8.8/")))
        #expect(!OutboundAddressPolicy.isAllowed(try #require(URL(string: "http://10.0.0.1/admin"))))
        await #expect(throws: OutboundAddressPolicy.Refusal.self) {
            try await SourceService.shared.downloadPDF(from: "http://127.0.0.1:1/paper.pdf", to: NSTemporaryDirectory() + "never.pdf")
        }
    }
}
