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

@Suite("Legacy transcript repair detection")
struct LegacyTranscriptRepairDetectionTests {
    @Test("Recognizes the retired YouTube transcript caps")
    func recognizesLegacyTruncatedYouTubeTranscript() {
        let marker = StudioViewModel.legacyYouTubeTranscriptTruncationMarker
        let capped = String(repeating: "x", count: StudioViewModel.legacyYouTubeTranscriptCharacterLimit)

        #expect(StudioViewModel.isLegacyTruncatedYouTubeTranscript("captions\n\n\(marker)"))
        #expect(StudioViewModel.isLegacyTruncatedYouTubeTranscript(capped))
        #expect(!StudioViewModel.isLegacyTruncatedYouTubeTranscript(String(capped.dropLast())))
        #expect(!StudioViewModel.isLegacyTruncatedYouTubeTranscript("\(marker)\n"))
        #expect(!StudioViewModel.isLegacyTruncatedYouTubeTranscript("complete captions"))
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

// MARK: - In-app web session cookies

/// The reader's cookies reach ForeverLM's own fetches through the jar
/// `URLSession` reads, with cookie handling left on, so a publisher's sign-in
/// bounce that sets cookies mid-redirect (nature.com's `idp` transit) is
/// followed the way a browser follows it instead of looping.
@Suite("In-App Web Session Cookies")
struct InAppWebSessionCookieTests {
    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "v-\(name)", .domain: domain, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    @Test("Applicable cookies match by domain, path, scheme and expiry")
    func applicableMatching() {
        let url = URL(string: "https://www.nature.com/articles/s41593-026-02421-x.pdf")!
        let wide = cookie("idp_session", domain: ".nature.com", secure: true)
        let exact = cookie("csrf", domain: "www.nature.com")
        let other = cookie("other", domain: ".science.org")
        let deepPath = cookie("deep", domain: ".nature.com", path: "/search")
        var expired = [HTTPCookiePropertyKey: Any]()
        expired[.name] = "old"; expired[.value] = "x"; expired[.domain] = ".nature.com"; expired[.path] = "/"
        expired[.expires] = Date(timeIntervalSinceNow: -60)
        let stale = HTTPCookie(properties: expired)!
        let matched = InAppWebSession.applicable([wide, exact, other, deepPath, stale], to: url).map(\.name)
        #expect(matched.sorted() == ["csrf", "idp_session"])
        // A secure cookie stays off a plain http request.
        let plain = URL(string: "http://www.nature.com/articles/x")!
        #expect(InAppWebSession.applicable([wide, exact], to: plain).map(\.name) == ["csrf"])
    }

    @Test("Applying cookies puts them in the shared jar and leaves cookie handling on")
    func applySeedsSharedJar() {
        let url = URL(string: "https://www.nature.com/articles/s41593-026-02421-x.pdf")!
        let name = "foreverlm-test-\(UUID().uuidString.prefix(8))"
        let session = cookie(name, domain: ".nature.com", secure: true)
        var request = URLRequest(url: url)
        InAppWebSession.apply([session], to: &request)
        defer { HTTPCookieStorage.shared.deleteCookie(session) }

        #expect(request.httpShouldHandleCookies)
        // No fixed header: the jar supplies the cookies hop by hop, and keeps
        // what a redirect sets.
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let stored = HTTPCookieStorage.shared.cookies(for: url)?.map(\.name) ?? []
        #expect(stored.contains(name))
        #expect(HTTPCookieStorage.shared.cookieAcceptPolicy == .always)
    }

    @Test("No cookies leaves the request alone")
    func applyNothing() {
        var request = URLRequest(url: URL(string: "https://example.org/")!)
        request.httpShouldHandleCookies = false
        InAppWebSession.apply([], to: &request)
        #expect(!request.httpShouldHandleCookies)
    }
}

// MARK: - Publisher PDF through the reader's web session

@Suite("Web Session PDF Download Decision")
struct WebSessionPDFDownloadDecisionTests {
    private let naturePDF = "https://www.nature.com/articles/s41593-026-02421-x.pdf"

    private func cookie(_ name: String, domain: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "v-\(name)", .domain: domain, .path: "/", .secure: "TRUE",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private var natureSession: [HTTPCookie] {
        [cookie("idp_session", domain: ".nature.com"), cookie("consent", domain: "www.nature.com")]
    }

    @Test("An HTML answer to a paper's PDF, with the reader signed in to the host, is fetched as the reader")
    func htmlAnswerWithReaderSession() {
        let decision = WebSessionPDFDownload.decision(
            pdfURL: naturePDF, after: SourceError.fetchFailed, cookies: natureSession, paperHasPDF: false
        )
        #expect(decision == .attempt)
    }

    @Test("A 403 aimed at non-browser clients is a refusal the reader's client can answer")
    func accessDeniedWithReaderSession() {
        let decision = WebSessionPDFDownload.decision(
            pdfURL: "https://www.jneurosci.org/content/jneuro/46/1/e1.full.pdf",
            after: SourceError.accessDenied,
            cookies: [cookie("cf_clearance", domain: ".jneurosci.org")],
            paperHasPDF: false
        )
        #expect(decision == .attempt)
    }

    @Test("A paper that already has its PDF is never fetched again, whatever else holds")
    func paperWithPDFIsLeftAlone() {
        let decision = WebSessionPDFDownload.decision(
            pdfURL: naturePDF, after: SourceError.fetchFailed, cookies: natureSession, paperHasPDF: true
        )
        #expect(decision == .skipped(.paperHasPDF))
    }

    @Test("A supplementary file is refused even when the reader could fetch it")
    func supplementaryFileIsRefused() {
        let reportingSummary = "https://static-content.springer.com/esm/art%3A10.1038%2Fs41593-026-02421-x/MediaObjects/41593_2026_2421_MOESM1_ESM.pdf"
        let decision = WebSessionPDFDownload.decision(
            pdfURL: reportingSummary,
            after: SourceError.fetchFailed,
            cookies: [cookie("idp_session", domain: ".springer.com")],
            paperHasPDF: false
        )
        #expect(decision == .skipped(.supplementaryFile))
    }

    @Test("Without cookies for the host there is no reader session to fetch with")
    func noReaderSession() {
        let elsewhere = [cookie("session", domain: ".science.org")]
        #expect(
            WebSessionPDFDownload.decision(pdfURL: naturePDF, after: SourceError.fetchFailed, cookies: elsewhere, paperHasPDF: false)
                == .skipped(.noReaderSession(host: "www.nature.com"))
        )
        #expect(
            WebSessionPDFDownload.decision(pdfURL: naturePDF, after: SourceError.fetchFailed, cookies: [], paperHasPDF: false)
                == .skipped(.noReaderSession(host: "www.nature.com"))
        )
        // An expired cookie is no session either.
        let stale = [cookie("idp_session", domain: ".nature.com", expires: Date(timeIntervalSinceNow: -60))]
        #expect(
            WebSessionPDFDownload.decision(pdfURL: naturePDF, after: SourceError.fetchFailed, cookies: stale, paperHasPDF: false)
                == .skipped(.noReaderSession(host: "www.nature.com"))
        )
    }

    @Test("Failures the publisher did not cause are not retried as the reader")
    func onlyRefusalsAreRetried() {
        let notRefusals: [Error] = [
            SourceError.httpError(404),
            SourceError.httpError(500),
            SourceError.pdfReadFailed,
            SourceError.invalidURL,
            SourceError.paperIngestionFailed("Sign in with Apple in ForeverLM to fetch a file posted in Slack."),
            URLError(.timedOut),
            URLError(.notConnectedToInternet),
        ]
        for error in notRefusals {
            #expect(
                WebSessionPDFDownload.decision(pdfURL: naturePDF, after: error, cookies: natureSession, paperHasPDF: false)
                    == .skipped(.notARefusedPDFRequest),
                "\(error)"
            )
            #expect(!WebSessionPDFDownload.publisherRefusedTheFile(error), "\(error)")
        }
        #expect(WebSessionPDFDownload.publisherRefusedTheFile(SourceError.fetchFailed))
        #expect(WebSessionPDFDownload.publisherRefusedTheFile(SourceError.accessDenied))
    }

    @Test("A PDF URL that is not a URL is skipped before anything else is asked")
    func invalidURL() {
        #expect(
            WebSessionPDFDownload.decision(pdfURL: "not a url", after: SourceError.fetchFailed, cookies: natureSession, paperHasPDF: false)
                == .skipped(.invalidURL)
        )
        #expect(
            WebSessionPDFDownload.decision(pdfURL: "/articles/x.pdf", after: SourceError.fetchFailed, cookies: natureSession, paperHasPDF: false)
                == .skipped(.invalidURL)
        )
    }

    @Test("Skip reasons read as sentences for the download log")
    func reasonsDescribeThemselves() {
        #expect(WebSessionPDFDownload.Reason.noReaderSession(host: "www.nature.com").description.contains("www.nature.com"))
        #expect(!WebSessionPDFDownload.Reason.supplementaryFile.description.isEmpty)
        #expect(!WebSessionPDFDownload.Reason.paperHasPDF.description.isEmpty)
    }

    @Test("The paper's page is the PDF URL without its .pdf, or nothing")
    func landingPageFromPDFURL() {
        // nature.com's `<id>.pdf` is bounced to the article page for any bare
        // request; the page's own control is what hands over the file.
        #expect(
            WebSessionPDFDownloader.landingPageURL(forPDF: URL(string: naturePDF)!)?.absoluteString
                == "https://www.nature.com/articles/s41593-026-02421-x"
        )
        #expect(
            WebSessionPDFDownloader.landingPageURL(forPDF: URL(string: "https://www.jneurosci.org/content/jneuro/46/1/e1.full.pdf?download=true")!)?.absoluteString
                == "https://www.jneurosci.org/content/jneuro/46/1/e1.full"
        )
        #expect(WebSessionPDFDownloader.landingPageURL(forPDF: URL(string: "https://example.org/paper.PDF#page=2")!)?.absoluteString == "https://example.org/paper")
        // Not a PDF path: no page to derive.
        #expect(WebSessionPDFDownloader.landingPageURL(forPDF: URL(string: "https://www.nature.com/articles/s41593-026-02421-x")!) == nil)
        #expect(WebSessionPDFDownloader.landingPageURL(forPDF: URL(string: "https://example.org/download?id=7")!) == nil)
    }

    @Test("A navigation's PDF response, an unshowable type or an attachment becomes a download")
    func responseToDownload() {
        #expect(WebSessionPDFDownloader.responseIsDownload(mimeType: "application/pdf", canShowMIMEType: true, contentDisposition: nil))
        #expect(WebSessionPDFDownloader.responseIsDownload(mimeType: "APPLICATION/PDF", canShowMIMEType: true, contentDisposition: nil))
        #expect(WebSessionPDFDownloader.responseIsDownload(mimeType: "application/octet-stream", canShowMIMEType: false, contentDisposition: nil))
        #expect(WebSessionPDFDownloader.responseIsDownload(
            mimeType: "text/html", canShowMIMEType: true, contentDisposition: "attachment; filename=\"paper.pdf\""
        ))
        // The publisher's page renders as a page, so its script gets to run.
        #expect(!WebSessionPDFDownloader.responseIsDownload(mimeType: "text/html", canShowMIMEType: true, contentDisposition: nil))
        #expect(!WebSessionPDFDownloader.responseIsDownload(mimeType: "text/html", canShowMIMEType: true, contentDisposition: "inline"))
    }
}

// MARK: - Paper Abstract URL (PDF → Landing Page)

@Suite("Publisher Access Wall Detection")
struct PublisherAccessWallDetectionTests {
    private static let referenceList = (1...40).map {
        "\($0). Author, A. & Author, B. A reference title of ordinary length for a journal. J. Sci. 12, 345–678 (2020)."
    }.joined(separator: "\n")

    private static let fullTextParagraph = String(
        repeating: "The complex adopts a closed conformation upon binding its substrate, "
            + "and the resulting rearrangement propagates through the linker domain. ",
        count: 40
    )

    @Test("A landing page with an abstract and a purchase panel is the wall")
    func landingPageIsAWall() {
        let text = """
        Abstract
        We report a finding of some consequence.
        Access options
        Access through your institution
        Buy this article
        Prices may be subject to local taxes which are calculated during checkout
        References
        \(Self.referenceList)
        """
        #expect(PaperService.looksLikePublisherAccessWall(text: text))
        // Long enough on its references alone, and still not the paper.
        #expect(!PaperService.looksLikePaperFullText(text))
    }

    @Test("One phrase in a paper that discusses publishing is not a wall")
    func singlePhraseIsNotAWall() {
        let text = Self.fullTextParagraph
            + " Readers were asked whether they would buy this article at the listed price. "
            + Self.fullTextParagraph
        #expect(!PaperService.looksLikePublisherAccessWall(text: text))
        #expect(PaperService.looksLikePaperFullText(text))
    }

    @Test("A page too short to be the paper is not full text")
    func shortPageIsNotFullText() {
        let abstract = "We report a finding of some consequence, described in the few hundred words a landing page shows."
        #expect(!PaperService.looksLikePublisherAccessWall(text: abstract))
        #expect(!PaperService.looksLikePaperFullText(abstract))
    }

    /// The page Nature shows for a paper the reader cannot access, after the
    /// chrome filter has removed the purchase panel: the abstract, one-line
    /// figure titles, and every Extended Data legend in full. This is what two
    /// Nature Neuroscience papers were stored as on 2026-09-06.
    private static let publisherPreview: String = {
        var lines = [
            "Mitochondrial calcium influx-driven bioenergetics selectively enable drug addiction",
            "",
            "## Abstract",
            String(repeating: "Addictive substances hijack the reward system and drive dopamine surges that underlie compulsive behavior. ", count: 20),
        ]
        for figure in 1...6 {
            lines.append("Fig. \(figure): A one-line figure title describing what the panels show.")
        }
        lines.append("## Extended data")
        for figure in 1...10 {
            lines.append("### Extended Data Fig. \(figure) A legend title of ordinary length for the figure.")
            lines.append(String(
                repeating: "a, Representative images and traces (n = 25 cells per group; two-tailed paired Student's t-test, P = 0.012). ",
                count: 12
            ))
        }
        return lines.joined(separator: "\n")
    }()

    @Test("A preview whose only body is the abstract is not the paper, however long its legends run")
    func previewWithLongLegendsIsNotFullText() {
        let text = Self.publisherPreview
        let allWords = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        #expect(allWords > PaperService.minimumPaperFullTextWordCount)
        #expect(!PaperService.looksLikePublisherAccessWall(text: text))
        #expect(PaperService.paperBodyWordCount(text) < PaperService.minimumPaperFullTextWordCount)
        #expect(!PaperService.looksLikePaperFullText(text))
    }

    @Test("A paper whose body carries no section headings is judged on that body")
    func headinglessBodyIsFullText() {
        let text = "## Abstract\n" + Self.fullTextParagraph + "\n## References\n" + Self.referenceList
        #expect(PaperService.looksLikePaperFullText(text))
        // The reference list is set aside, not counted.
        let allWords = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        #expect(PaperService.paperBodyWordCount(text) < allWords)
    }

    @Test("A reference list does not make an abstract the paper")
    func abstractWithReferencesIsNotFullText() {
        let abstract = String(repeating: "We report a finding of some consequence in a sentence of ordinary length. ", count: 12)
        let text = "## Abstract\n" + abstract + "\n## References\n" + Self.referenceList
        #expect(!PaperService.looksLikePublisherAccessWall(text: text))
        #expect(!PaperService.looksLikePaperFullText(text))
    }

    @Test("Titled body sections count, and a bare heading marker opens no section")
    func titledSectionsCount() {
        let text = "## Abstract\nA short abstract.\n## Main\n" + Self.fullTextParagraph
            + "\n###\n" + Self.fullTextParagraph + "\n## Extended data\n### Extended Data Fig. 1 Legend.\nLegend text."
        #expect(PaperService.looksLikePaperFullText(text))
        let bodyOnly = Self.fullTextParagraph.split(whereSeparator: { $0.isWhitespace }).count * 2 + 3
        #expect(PaperService.paperBodyWordCount(text) == bodyOnly)
    }
}

@Suite("eLife Article URLs")
struct ELifeArticleURLTests {
    @Test("Article and reviewed-preprint URLs name their API collection and id")
    func parsesELifeURLs() {
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/articles/107661")
                == PaperService.ELifeArticle(collection: "articles", id: "107661"))
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/articles/93172v2#abstract")
                == PaperService.ELifeArticle(collection: "articles", id: "93172"))
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/articles/17210/figures?x=1")
                == PaperService.ELifeArticle(collection: "articles", id: "17210"))
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/reviewed-preprints/106000")
                == PaperService.ELifeArticle(collection: "reviewed-preprints", id: "106000"))
    }

    @Test("Other eLife pages and other hosts are not articles")
    func rejectsOtherURLs() {
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/") == nil)
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/articles") == nil)
        #expect(PaperService.eLifeArticle(from: "https://elifesciences.org/subjects/neuroscience") == nil)
        #expect(PaperService.eLifeArticle(from: "https://cdn.elifesciences.org/articles/107661/elife-107661-v1.pdf") == nil
                || PaperService.eLifeArticle(from: "https://cdn.elifesciences.org/articles/107661/elife-107661-v1.pdf")?.id == "107661")
        #expect(PaperService.eLifeArticle(from: "https://www.nature.com/articles/s41593-026-02421-x") == nil)
    }
}

@Suite("Paper Abstract URL Conversion")
struct PaperAbstractURLTests {

    @Test("Converts arXiv PDF to abstract page")
    func arxivPDFToAbs() {
        let result = PaperService.paperAbstractURL(from: "https://arxiv.org/pdf/2301.07041.pdf")
        #expect(result == "https://arxiv.org/abs/2301.07041")
    }

    @Test("Converts arXiv PDF without extension to abstract page")
    func arxivPDFNoExt() {
        let result = PaperService.paperAbstractURL(from: "https://arxiv.org/pdf/2301.07041")
        #expect(result == "https://arxiv.org/abs/2301.07041")
    }

    @Test("Converts bioRxiv full PDF to abstract page")
    func biorxivFullPDF() {
        let result = PaperService.paperAbstractURL(from: "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1.full.pdf")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2024.01.15.123456v1")
    }

    @Test("Converts bioRxiv early-path PDF to canonical abstract")
    func biorxivEarlyPath() {
        let result = PaperService.paperAbstractURL(from: "https://www.biorxiv.org/content/biorxiv/early/2025/02/15/2022.03.16.484643.full.pdf")
        #expect(result == "https://www.biorxiv.org/content/10.1101/2022.03.16.484643")
    }

    @Test("Converts medRxiv PDF to abstract page")
    func medrxivPDF() {
        let result = PaperService.paperAbstractURL(from: "https://www.medrxiv.org/content/10.1101/2024.02.20.567890v1.full.pdf")
        #expect(result == "https://www.medrxiv.org/content/10.1101/2024.02.20.567890v1")
    }

    @Test("Converts ScienceDirect pdfft PDF URL to article page")
    func scienceDirectPDFToArticle() {
        let result = PaperService.paperAbstractURL(from: "https://www.sciencedirect.com/science/article/pii/S1568163724001284/pdfft?download=true")
        #expect(result == "https://www.sciencedirect.com/science/article/pii/S1568163724001284")
    }

    @Test("Returns nil for non-paper URL")
    func nonPaperURL() {
        let result = PaperService.paperAbstractURL(from: "https://example.com/paper.pdf")
        #expect(result == nil)
    }

    @Test("Returns nil for arXiv abstract (not a PDF)")
    func arxivAbsAlready() {
        let result = PaperService.paperAbstractURL(from: "https://arxiv.org/abs/2301.07041")
        #expect(result == nil)
    }
}

// MARK: - Paper Title Extraction

@Suite("Paper Title Extraction")
struct PaperTitleExtractionTests {

    @Test("Extracts from citation_title meta tag")
    func citationTitle() {
        let html = """
        <meta name="citation_title" content="CRISPR-Cas9 gene editing in plants">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "CRISPR-Cas9 gene editing in plants")
    }

    @Test("Extracts from og:title meta tag")
    func ogTitle() {
        let html = """
        <meta property="og:title" content="Epigenetic clocks and aging">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "Epigenetic clocks and aging")
    }

    @Test("Strips journal suffix from title tag")
    func titleTagStripped() {
        let html = "<title>My Paper Title | Nature</title>"
        #expect(PaperService.extractPaperTitle(from: html) == "My Paper Title")
    }

    @Test("Decodes HTML entities in title")
    func htmlEntities() {
        let html = """
        <meta name="citation_title" content="RNA &amp; DNA: A Study">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "RNA & DNA: A Study")
    }

    @Test("Returns nil for empty HTML")
    func emptyHTML() {
        #expect(PaperService.extractPaperTitle(from: "") == nil)
    }

    @Test("Returns nil for HTML without any title")
    func noTitle() {
        let html = "<html><body>Just content</body></html>"
        #expect(PaperService.extractPaperTitle(from: html) == nil)
    }

    @Test("Prefers citation_title over og:title")
    func prefersCitationTitle() {
        let html = """
        <meta name="citation_title" content="Citation Title">
        <meta property="og:title" content="OG Title">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "Citation Title")
    }

    @Test("Handles dc.title meta tag")
    func dcTitle() {
        let html = """
        <meta name="dc.title" content="Dublin Core Title">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "Dublin Core Title")
    }

    /// Elsevier's linkinghub, as served for https://doi.org/10.1016/j.cmet.2022.02.001
    /// on 2026-09-18: no citation meta, a meta refresh, and `<title>Redirecting</title>`.
    /// Four 10.1016 papers were saved under that title before the fallback
    /// learned that a redirect page's title is the wait, not the document.
    static let elsevierLinkinghubInterstitial = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "https://www.w3.org/TR/html4/loose.dtd">
    <html>
    <head>
    <meta charset="utf-8">
    <META http-equiv=Content-Type content="text/html">
    <meta HTTP-EQUIV="REFRESH" content="2; url='/retrieve/articleSelectPrefsTemp?Redirect=https%3A%2F%2Fcell.com%2Fcell-metabolism%2Fretrieve%2Fpii%2FS1550413122000456&amp;key=9017b71d6e9d962868812752ea31880d82c657d7'"/>
    <meta name="tdm-reservation" content="1" />
    <meta name="tdm-policy" content="https://www.elsevier.com/tdm/tdmrep-policy.json" />
    <title>Redirecting</title>
    <META http-equiv=Content-Type content="text/html; charset=utf-8">
    </head>
    <body onload="autoRedirectToURL();">
    <input type="hidden" name="redirectURL" value="https%3A%2F%2Fcell.com%2Fcell-metabolism%2Fretrieve%2Fpii%2FS1550413122000456" id="redirectURL"/>
    </body>
    </html>
    """

    @Test("An Elsevier linkinghub redirect page has no paper title")
    func elsevierRedirectPageHasNoTitle() {
        let html = Self.elsevierLinkinghubInterstitial
        let url = "https://linkinghub.elsevier.com/retrieve/pii/S1550413122000456"
        #expect(PaperService.extractPaperTitle(from: html) == nil)
        // Nothing on the page identifies a paper, so there is no page metadata
        // at all; the importer falls through to the DOI record.
        #expect(PaperService.extractPaperPageMetadata(from: html, url: url) == nil)
    }

    @Test("A title that is only the host's name is the page's, not the paper's")
    func hostNameTitleIsNotAPaperTitle() {
        let html = "<html><head><title>linkinghub.elsevier.com</title></head></html>"
        #expect(PaperService.extractPaperPageMetadata(
            from: html,
            url: "https://linkinghub.elsevier.com/retrieve/pii/S0896627326004489"
        ) == nil)
        #expect(PaperService.extractPaperPageMetadata(
            from: "<html><head><title>Cell Press</title></head></html>",
            url: "https://www.cell.com/cell-metabolism/fulltext/S1550-4131(22)00045-6"
        )?.title == "Cell Press")
    }

    @Test("Interstitial titles: redirects, bot checks, hosts, blanks — and not papers about redirecting")
    func interstitialTitles() {
        let url = "https://linkinghub.elsevier.com/retrieve/pii/S1550413122000456"
        #expect(PaperService.isInterstitialPageTitle("Redirecting", url: url))
        #expect(PaperService.isInterstitialPageTitle("Redirecting…", url: url))
        #expect(PaperService.isInterstitialPageTitle("Redirecting...", url: url))
        #expect(PaperService.isInterstitialPageTitle("Redirect", url: url))
        #expect(PaperService.isInterstitialPageTitle("", url: url))
        #expect(PaperService.isInterstitialPageTitle("  \n ", url: url))
        #expect(PaperService.isInterstitialPageTitle("linkinghub.elsevier.com", url: url))
        #expect(PaperService.isInterstitialPageTitle("nature.com", url: "https://www.nature.com/articles/s41586-023-06621-4"))
        #expect(PaperService.isInterstitialPageTitle("Just a moment...", url: "https://www.cell.com/action/showPdf?pii=S0092-8674(24)00304-0"))
        #expect(PaperService.isInterstitialPageTitle("Redirecting"))

        #expect(!PaperService.isInterstitialPageTitle("Redirecting T cells against cancer", url: url))
        #expect(!PaperService.isInterstitialPageTitle("The NADPARK study: A randomized phase I trial of nicotinamide riboside supplementation in Parkinson's disease", url: url))
        #expect(!PaperService.isInterstitialPageTitle("Redirection of lipid flux toward phospholipids", url: url))
    }

    @Test("A paper titled with a redirect word keeps its title")
    func paperAboutRedirectingKeepsTitle() {
        let html = """
        <meta name="citation_title" content="Redirecting T cells against cancer">
        """
        #expect(PaperService.extractPaperTitle(from: html) == "Redirecting T cells against cancer")
    }
}

@Suite("Paper Metadata Result Validation")
struct PaperMetadataResultValidationTests {

    @Test("Reads the five field lines from a reply")
    func readsFieldLines() throws {
        let result = try AIService.paperMetadata(fromReply: """
        TITLE: Evidence for improved DNA repair in the long-lived bowhead whale
        AUTHOR: Firsanov, Denis; Zacher, Max
        JOURNAL: Nature
        YEAR: 2025
        DOI: 10.1038/s41586-025-08984-0
        """)

        #expect(result.title == "Evidence for improved DNA repair in the long-lived bowhead whale")
        #expect(result.author == "Firsanov, Denis; Zacher, Max")
        #expect(result.journal == "Nature")
        #expect(result.year == "2025")
        #expect(result.doi == "10.1038/s41586-025-08984-0")
    }

    @Test("A safety verdict names no field and is refused")
    func refusesSafetyVerdict() {
        // 2026-10-06: the Free Models Router's content-safety pick answered two
        // papers with this, and the cached reply failed every Retry.
        #expect(throws: AIError.self) {
            _ = try AIService.paperMetadata(fromReply: "User Safety: safe")
        }
    }

    /// Page 0 of Precambrian Research 23 (1983) 1-8 as PDFKit reads it, down
    /// to the abstract's citation line.
    static let ancientMicrospheresFrontMatter = """
    Precambrian Research, 23 (1983) 1-8
    Elsevier Science Publishers B.V.. Amsterdam -Printed in The Netherlands
    ANCIENT MICROSPHERES: ABIOGENIC, PROTOBIOGENIC, OR
    BIOGENIC?
    SIDNEY W. FOX and ROBERT M. SYREN
    NFCR Laboratory of the Institute for Molecular and Cellular Evolution, University of
    Miami, Coral Gables, FL 33134 (U.S.A.)
    MARYLOU INGRAM*, BRANDON J. PRICE** and JOHN COSTELLO
    Institute for Cell Analysis, University of Miami Medical School, Miami, FL 33136
    (U.S.A.)
    (Received January 1, 1983; revision accepted May 15, 1983)
    ABSTRACT
    Fox, S.W., Syren, R.M., Ingram, M., Price, B.J. and Costello, J., 1983. Ancient micro-
    spheres: abiogenic, protobiogenic, or biogenic? Precambrian Res., 23: l-8.
    """

    @Test("A title with words the front matter does not print is refused")
    func refusesRewrittenTitle() {
        // 2026-10-12, production build 222: liquid/lfm-2.5-2.6b:free answered
        // this, word for word, and the import kept the title.
        let reply = """
        TITLE: Ancient Microscopes: Abiogenic, Protobionic, or Biogenic?
        AUTHORS: Sidney W. Fox; Robert M. Syren; Marylou Ingram; Brandon J. Price; John Costello
        JOURNAL: Precambrian Research
        YEAR: 1983
        DOI: ?
        """
        #expect(
            AIService.wordsNotPrinted(
                in: "Ancient Microscopes: Abiogenic, Protobionic, or Biogenic?",
                given: Self.ancientMicrospheresFrontMatter
            ) == ["Microscopes", "Protobionic"]
        )
        #expect(throws: AIError.self) {
            _ = try AIService.paperMetadata(fromReply: reply, given: Self.ancientMicrospheresFrontMatter)
        }
    }

    @Test("The printed title and every author are kept, with the AUTHORS label read")
    func keepsPrintedTitleAndAuthors() throws {
        let result = try AIService.paperMetadata(fromReply: """
        TITLE: Ancient Microspheres: Abiogenic, Protobiogenic, or Biogenic?
        AUTHORS: Sidney W. Fox; Robert M. Syren; Marylou Ingram; Brandon J. Price; John Costello
        JOURNAL: Precambrian Research
        YEAR: 1983
        DOI: ?
        """, given: Self.ancientMicrospheresFrontMatter)

        #expect(result.title == "Ancient Microspheres: Abiogenic, Protobiogenic, or Biogenic?")
        #expect(result.author == "Sidney W. Fox; Robert M. Syren; Marylou Ingram; Brandon J. Price; John Costello")
        #expect(result.journal == "Precambrian Research")
        #expect(result.year == "1983")
        #expect(result.doi == nil)
    }

    @Test("Authors the front matter does not print are refused")
    func refusesUnprintedAuthor() {
        #expect(throws: AIError.self) {
            _ = try AIService.paperMetadata(fromReply: """
            TITLE: ANCIENT MICROSPHERES: ABIOGENIC, PROTOBIOGENIC, OR BIOGENIC?
            AUTHOR: Sidney W. Fox; Zara Holt
            JOURNAL: Precambrian Research
            YEAR: 1983
            DOI: ?
            """, given: Self.ancientMicrospheresFrontMatter)
        }
    }

    @Test("A reply that leaves a label out is refused, not read as a blank")
    func refusesMissingLabel() {
        #expect(throws: AIError.self) {
            _ = try AIService.paperMetadata(fromReply: """
            TITLE: Ancient Microspheres: Abiogenic, Protobiogenic, or Biogenic?
            JOURNAL: Precambrian Research
            YEAR: 1983
            DOI: ?
            """)
        }
    }

    @Test("Accents, ligatures, line breaks and a glyph PDF text lost are no difference")
    func toleratesExtractionDifferences() {
        let frontMatter = """
        Catalyzed by -Ketoglutarate Dehydrogenase: an eﬃcient sig-
        nal in Mitochondria with arti cial, cell-type-speci c and ef cient E ects
        ZARA HOLT and ŁUKASZ FRÖHLICH
        """
        #expect(AIService.wordsNotPrinted(
            in: "Catalyzed by α-Ketoglutarate Dehydrogenase: an Efficient Signal in Mitochondria",
            given: frontMatter
        ).isEmpty)
        #expect(AIService.wordsNotPrinted(
            in: "Artificial, Cell-Type-Specific and Efficient Effects",
            given: frontMatter
        ).isEmpty)
        #expect(AIService.wordsNotPrinted(in: "Zara Holt; Lukasz Frohlich", given: frontMatter).isEmpty)
        #expect(AIService.wordsNotPrinted(in: "Zara Holt; Lukasz Fischer", given: frontMatter) == ["Fischer"])
    }

    @Test("Preserves the LLM's paper title without a second heuristic cleaner")
    func preservesLLMPaperTitle() {
        let result = AIService.PaperMetadataResult.validated(
            title: "The hyperfunction theory: an emerging paradigm for the biology of aging - PMC",
            author: nil,
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.title == "The hyperfunction theory: an emerging paradigm for the biology of aging - PMC")
    }

    @Test("Preserves the LLM's complete paper author list")
    func preservesCompletePaperAuthorLists() {
        let result = AIService.PaperMetadataResult.validated(
            title: nil,
            author: "Jane Smith, John Doe, and Martin Picard",
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.author == "Jane Smith, John Doe, and Martin Picard")
    }

    @Test("Does not infer author identity while validating AI metadata")
    func doesNotInferAuthorIdentity() {
        let result = AIService.PaperMetadataResult.validated(
            title: nil,
            author: "Samuel I. Gould; Samuel I. Gould",
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.author == "Samuel I. Gould; Samuel I. Gould")
    }

    @Test("Leaves semantic author-list validation to the configured LLM task")
    func leavesSemanticAuthorValidationToLLM() {
        let result = AIService.PaperMetadataResult.validated(
            title: nil,
            author: "Smith et al.",
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.author == "Smith et al.")
    }

    @Test("Preserves comma-separated author text verbatim")
    func preservesCommaSeparatedAuthorText() {
        let result = AIService.PaperMetadataResult.validated(
            title: nil,
            author: "Bret Allan, Jane Smith",
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.author == "Bret Allan, Jane Smith")
    }

    @Test("Does not parse or invert human names")
    func doesNotParseOrInvertHumanNames() {
        let result = AIService.PaperMetadataResult.validated(
            title: nil,
            author: "Smith, Jane; Doe, John",
            journal: nil,
            year: nil,
            doi: nil
        )

        #expect(result.author == "Smith, Jane; Doe, John")
    }
}

@Suite("Paper Page Metadata Extraction")
struct PaperPageMetadataExtractionTests {
    @Test("A page's title evidence keeps every place it names itself, apart")
    func webArticleTitleEvidence() {
        let html = """
        <!doctype html><html><head>
        <title>Waypoint Bio</title>
        <meta property="og:title" content="Waypoint Bio">
        <meta property="og:site_name" content="Waypoint Bio">
        <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"Waypoint Bio"},{"@type":"BlogPosting","headline":"Building Out-of-Distribution Medicines","author":[{"@type":"Person","name":"Rob Chen"},{"@type":"Person","name":"Dana Lee"}]}]}</script>
        </head><body><nav><a href="/">Waypoint Bio</a></nav>
        <h1>Writings &#8211; Building <em>Out&#x2011;of&#x2011;Distribution</em> Medicines</h1>
        <p>The post.</p></body></html>
        """
        let meta = PaperService.extractWebArticleMetadata(from: html)
        let evidence = meta?.titleEvidence
        #expect(evidence?.documentTitle == "Waypoint Bio")
        #expect(evidence?.socialTitle == "Waypoint Bio")
        #expect(evidence?.siteName == "Waypoint Bio")
        #expect(evidence?.headline == "Writings \u{2013} Building Out\u{2011}of\u{2011}Distribution Medicines", "tags stripped, numeric entities decoded")
        #expect(evidence?.structuredHeadline == "Building Out-of-Distribution Medicines")
        #expect(evidence?.structuredAuthor == "Rob Chen & Dana Lee")
        // The structural placeholder is the JSON-LD headline, and the byline
        // comes from the record when the head names no author.
        #expect(meta?.title == "Building Out-of-Distribution Medicines")
        #expect(meta?.author == "Rob Chen & Dana Lee")
        // A title the page supplied may be replaced by the model's answer; one a person typed may not.
        #expect(evidence?.supplied("waypoint bio", host: "www.waypointbio.com") == true)
        #expect(evidence?.supplied("waypointbio.com", host: "www.waypointbio.com") == true)
        #expect(evidence?.supplied("My notes on OOD medicines", host: "www.waypointbio.com") == false)
    }

    @Test("A <title> that is only the site's name gives way to the page's headline")
    func siteNameTitleGivesWayToHeadline() {
        let html = """
        <html><head><title>Waypoint Bio</title><meta property="og:site_name" content="Waypoint Bio"></head>
        <body><h1>The Missing Dimension in Pooled Screens</h1></body></html>
        """
        let meta = PaperService.extractWebArticleMetadata(from: html)
        #expect(meta?.title == "The Missing Dimension in Pooled Screens")
        #expect(meta?.titleEvidence.titleCandidates == ["The Missing Dimension in Pooled Screens", "Waypoint Bio"])
        #expect(PaperService.extractWebArticleMetadata(from: "<html><body><p>nothing</p></body></html>") == nil)
    }


    @Test("Extracts scholarly metadata from citation meta tags")
    func citationMetadata() {
        let html = """
        <meta name="citation_title" content="A Better Paper Setup">
        <meta name="citation_author" content="Jane Smith">
        <meta name="citation_author" content="John Doe">
        <meta name="citation_journal_title" content="Nature Aging">
        <meta name="citation_publication_date" content="2025-03-14">
        <meta name="citation_doi" content="10.1038/s43587-025-00001-1">
        <meta name="citation_pdf_url" content="/content/paper.pdf">
        """

        let meta = PaperService.extractPaperPageMetadata(from: html)

        #expect(meta?.title == "A Better Paper Setup")
        #expect(meta?.authorsDisplay == "Jane Smith; John Doe")
        #expect(meta?.journal == "Nature Aging")
        #expect(meta?.year == "2025")
        #expect(meta?.doi == "10.1038/s43587-025-00001-1")
        #expect(meta?.pdfURL == "/content/paper.pdf")
    }

    @Test("Prefers citation authors over duplicate Dublin Core metadata")
    func prefersCitationAuthorsOverDublinCoreMetadata() {
        let html = """
        <meta name="citation_title" content="Single Author Paper">
        <meta name="citation_author" content="Gould, Samuel I.">
        <meta name="dc.creator" content="Duplicate Metadata Source">
        """

        let meta = PaperService.extractPaperPageMetadata(from: html)

        #expect(meta?.authorsDisplay == "Gould, Samuel I.")
    }

    @Test("Uses Dublin Core authors when citation metadata is absent")
    func usesDublinCoreAuthorsAsFallback() {
        let html = """
        <meta name="citation_title" content="Dublin Core Paper">
        <meta name="dc.creator" content="Gould, Samuel I.">
        """

        let meta = PaperService.extractPaperPageMetadata(from: html)

        #expect(meta?.authorsDisplay == "Gould, Samuel I.")
    }

    @Test("Extracts blog article title and author from HTML head metadata")
    func webArticleMetadata() {
        let html = """
        <title data-rh="true">The antibody revolution is real. The business, less so.</title>
        <meta data-rh="true" property="og:title" content="The antibody revolution is real. The business, less so."/>
        <meta name="author" content="Carlos Outeiral" />
        """

        let meta = PaperService.extractWebArticleMetadata(from: html)

        #expect(meta?.title == "The antibody revolution is real. The business, less so.")
        #expect(meta?.author == "Carlos Outeiral")
    }

    @Test("Metadata attributes may be reversed and contain the other quote style")
    func reversedWebArticleMetadataAttributes() {
        let html = """
        <meta content="A Better Article" property='og:title'>
        <meta content="Morgan O'Brien" name='author'>
        """

        let meta = PaperService.extractWebArticleMetadata(from: html)

        #expect(meta?.title == "A Better Article")
        #expect(meta?.author == "Morgan O'Brien")
    }

    @Test("Large Next.js bodies do not make missing metadata scans unbounded")
    func largeNextJSBodyMetadata() {
        let serializedBody = String(repeating: #"self.__next_f.push([1,"body payload"]);"#, count: 50_000)
        let html = """
        <!doctype html><html><head>
        <title>The Anti-Aging Therapeutics Boom | Contrary Research</title>
        <meta property="og:title" content="The Anti-Aging Therapeutics Boom | Contrary Research">
        </head><body><script>\(serializedBody)</script></body></html>
        """

        let clock = ContinuousClock()
        let start = clock.now
        let meta = PaperService.extractWebArticleMetadata(from: html)
        let elapsed = start.duration(to: clock.now)

        #expect(meta?.title == "The Anti-Aging Therapeutics Boom | Contrary Research")
        #expect(meta?.author == nil)
        #expect(elapsed < .seconds(1))
    }

    @Test("Extracts DOI from dc.identifier URL")
    func dcIdentifierDOI() {
        let html = """
        <meta name="dc.title" content="Open Access Result">
        <meta name="dc.identifier" content="https://doi.org/10.48550/arXiv.2401.12345">
        <meta name="dc.date" content="2024-01-15">
        """

        let meta = PaperService.extractPaperPageMetadata(from: html)

        #expect(meta?.title == "Open Access Result")
        #expect(meta?.doi == "10.48550/arXiv.2401.12345")
        #expect(meta?.year == "2024")
    }
}

// MARK: - HTML tag attributes

/// Every head reader shares one tag reader. These pin how it reads: inside one
/// tag, in either attribute order, the way a browser tokenizes.
@Suite("HTML tag attributes")
struct HTMLTagAttributesTests {
    private func contents(_ html: String, _ attribute: String, _ value: String) -> [String] {
        HTMLTagAttributes.tags(named: "meta", in: html).compactMap { tag in
            guard tag[attribute]?.caseInsensitiveCompare(value) == .orderedSame else { return nil }
            return tag["content"]
        }
    }

    @Test("A value is read inside its own tag, content before or after name")
    func valueStaysInItsTag() {
        // The shape that stored 1,290 characters of quantum.country's head as
        // its author: the viewport tag first, content written before name.
        let head = """
        <meta charset="utf-8"><meta content="width=device-width,initial-scale=1,maximum-scale=1" name="viewport"><link href="/fonts/libre-franklin-v4-latin-regular.woff2" rel="preload" as="font" crossorigin="anonymous"><title>Quantum Country</title><meta content="A free introduction to quantum computing" data-rh="true" name="description"><meta content="Andy Matuschak" data-rh="true" name="author">
        """
        #expect(contents(head, "name", "author") == ["Andy Matuschak"])
        #expect(contents(head, "name", "viewport") == ["width=device-width,initial-scale=1,maximum-scale=1"])
        #expect(contents(#"<meta name='author' content="Morgan O'Brien">"#, "name", "author") == ["Morgan O'Brien"])
    }

    @Test("A > inside quotes is text, and a data- attribute is not the attribute")
    func quotesAndExactNames() {
        #expect(contents(#"<meta name="description" content="a > b, c < d"><meta name="author" content="Jane">"#, "name", "description") == ["a > b, c < d"])
        #expect(contents(#"<meta data-name="author" data-content="Wrong" name="author" content="Right">"#, "name", "author") == ["Right"])
        #expect(contents(#"<meta name="author" name="viewport" content="First">"#, "name", "author") == ["First"], "the first of a repeated attribute wins")
    }

    @Test("Unquoted, uppercase and self-closing tags read like any other")
    func looseSyntax() {
        let html = "<META NAME=author CONTENT = Jane_Doe /><Meta Property = \"og:title\" Content = 'T'/>"
        #expect(contents(html, "name", "author") == ["Jane_Doe"])
        #expect(contents(html, "property", "og:title") == ["T"])
        let links = HTMLTagAttributes.tags(named: "link", in: #"<link rel="preload" crossorigin href="/a.css"><link href='/b.png' rel=icon>"#)
        #expect(links.count == 2)
        #expect(links.first?["crossorigin"] == "", "a bare attribute has the empty value")
        #expect(links.first?["href"] == "/a.css")
        #expect(links.last?["rel"] == "icon")
    }

    @Test("Comments, scripts and styles hold no tags; text with a < is text")
    func passesOverNonMarkup() {
        let html = """
        <!-- <meta name="author" content="Commented"> -->
        <script>document.write('<meta content="' + x + '" name="author">')</script>
        <style>.a:before{content:"<meta name=author content=Styled>"}</style>
        <p>p < 0.05 and Robin <> Zara</p>
        <meta name="author" content="Real">
        """
        #expect(contents(html, "name", "author") == ["Real"])
        let opf = #"<?xml version="1.0"?><package><![CDATA[<meta name="cover" content="bad"/>]]><meta content="cover-image" name="cover"/></package>"#
        #expect(contents(opf, "name", "cover") == ["cover-image"])
    }

    @Test("A quote that never closes drops its own tag, not the rest of the page")
    func unterminatedQuote() {
        let html = #"<meta name="description" content="never closed><meta name='author' content='After'>"#
        #expect(contents(html, "name", "author") == ["After"])
    }
}

// MARK: - Web article bylines

@Suite("Web article bylines")
struct WebArticleBylineTests {
    /// quantum.country's head as served, trimmed to the tags up to its authors.
    private static let quantumHead = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta content="width=device-width,initial-scale=1,maximum-scale=1" name="viewport"><link href="/fonts/libre-franklin-v4-latin-regular.woff2" rel="preload" as="font" crossorigin="anonymous"><link href="/logo-180x180.png" rel="apple-touch-icon" sizes="180x180"><title>Quantum Country</title><meta content="A free introduction to quantum computing and quantum mechanics, presented in a new mnemonic medium which makes it almost effortless to remember what you read." data-rh="true" name="description"><meta content="Andy Matuschak" data-rh="true" name="author"><meta content="Michael Nielsen" data-rh="true" name="author"><meta content="Quantum Country" data-rh="true" name="citation_title"><meta content="Quantum Country" data-rh="true" property="og:title"><meta content="Quantum Country" data-rh="true" property="og:site_name"></head><body></body></html>
    """

    /// The Scientist's head as served, trimmed the same way.
    private static let scientistHead = """
    <!DOCTYPE html><html lang="en"><head><meta charSet="utf-8" data-next-head=""/><meta name="viewport" content="width=device-width" data-next-head=""/><link href="https://www.the-scientist.com/rebranding-mitochondria-71490" rel="canonical" data-next-head=""/><title data-next-head="">Rebranding Mitochondria: Beyond the Powerhouse of the Cell | The Scientist</title><meta content="As scientists realize the multifaceted role of mitochondria, some feel that the “powerhouse of the cell” analogy is out of date." name="description" data-next-head=""/><meta content="Rebranding Mitochondria: Beyond the Powerhouse of the Cell | The Scientist" property="og:title" data-next-head=""/><meta content="The Scientist" property="og:site_name" data-next-head=""/><meta content="https://cdn.the-scientist.com/assets/image/52223/powerhouse-of-the-cell-800x560-l.png" name="twitter:image" data-next-head=""/><meta content="Danielle Gerhard, PhD" name="author" data-next-head=""/></head><body></body></html>
    """

    @Test("The two heads that stored their markup as the author give their bylines")
    func productionHeads() {
        #expect(PaperService.extractWebArticleMetadata(from: Self.quantumHead)?.author == "Andy Matuschak & Michael Nielsen")
        #expect(PaperService.extractWebArticleMetadata(from: Self.scientistHead)?.author == "Danielle Gerhard, PhD")
        #expect(PaperService.extractWebArticleMetadata(from: Self.scientistHead)?.title == "Rebranding Mitochondria: Beyond the Powerhouse of the Cell | The Scientist")
        // The margin card reads the same heads.
        #expect(ReferenceLinkPreviews.metaContent(inHead: Self.scientistHead, key: "og:site_name") == "The Scientist")
    }

    @Test("An Open Graph profile link is not a byline; the page's JSON-LD author stands in")
    func profileLinkGivesWay() {
        let head = """
        <head><meta property="article:author" content="https://www.nytimes.com/by/jasmine-sun">
        <script type="application/ld+json">{"@type":"NewsArticle","headline":"Chinese peptides","author":[{"@type":"Person","name":"Jasmine Sun","url":"https://www.nytimes.com/by/jasmine-sun"}]}</script>
        </head>
        """
        #expect(PaperService.extractWebArticleMetadata(from: head)?.author == "Jasmine Sun")
        let linkOnly = #"<head><title>A post</title><meta property="article:author" content="https://www.patreon.com/quantumcountry"></head>"#
        #expect(PaperService.extractWebArticleMetadata(from: linkOnly)?.author == nil, "no name anywhere: no author, and the metadata model reads the byline")
        let named = #"<head><meta property="article:author" content="Kim Tingley"></head>"#
        #expect(PaperService.extractWebArticleMetadata(from: named)?.author == "Kim Tingley")
    }

    @Test("The same author named twice is named once")
    func duplicateAuthorTags() {
        let head = #"<meta name="author" content="Jane Doe"><meta name="author" content="jane doe">"#
        #expect(PaperService.extractWebArticleMetadata(from: head)?.author == "Jane Doe")
    }
}

// MARK: - Source author

@Suite("Source author")
struct SourceAuthorTests {
    @Test("A name or a list of names is an author")
    func namesAreAuthors() {
        for value in [
            "Andy Matuschak", "Danielle Gerhard, PhD", "Morgan O'Brien", "Smith, Jane; Doe, John",
            "Laszlo Tretter; Vera Adam-Vizi", StudioArticle.unknownPaperAuthor, "Robin <> Zara",
            "Jane Doe <jane@example.com>", "jack", "Gero Miesenböck", "A & B", "@handle", "",
            String(repeating: "Author Name; ", count: 400),
        ] {
            #expect(SourceAuthor.isPlausible(value), "\(value.prefix(40))")
        }
    }

    @Test("Markup, a web address or a name longer than any name is not")
    func otherFieldsAreNot() {
        for value in [
            #"width=device-width,initial-scale=1" name="viewport"><link href="/fonts/a.woff2" rel="preload">"#,
            "<b>Jane</b>", "Jane<br/>Doe", #"content="Jane""#,
            "https://www.nytimes.com/by/jasmine-sun", "http://example.com/a", "www.patreon.com/quantumcountry",
            String(repeating: "x", count: SourceAuthor.maximumNameLength + 1),
        ] {
            #expect(!SourceAuthor.isPlausible(value), "\(value.prefix(40))")
        }
    }

    @Test("A source turns such a value away wherever it arrives")
    func studioArticleRefusesAtEveryWayIn() throws {
        var article = StudioArticle(
            url: "https://quantum.country/",
            title: "Quantum Country",
            sourceType: .article,
            author: #"width=device-width" name="viewport"><link href="/x">"#
        )
        #expect(article.author == nil, "the initializer")
        article.author = "https://www.patreon.com/quantumcountry"
        #expect(article.author == nil, "an assignment")
        article.author = "Andy Matuschak & Michael Nielsen"
        #expect(article.author == "Andy Matuschak & Michael Nielsen")

        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(article)) as? [String: Any] ?? [:]
        payload["author"] = "https://www.nytimes.com/by/kim-tingley"
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(decoded.author == nil, "a stored row or a CloudKit payload")
    }
}

// MARK: - Registered paper title

@Suite("Registered paper title")
struct RegisteredPaperTitleTests {
    private static let damaged = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by -Ketoglutarate Dehydrogenase"
    private static let registered = "Generation of Reactive Oxygen Species in the Reaction Catalyzed by α-Ketoglutarate Dehydrogenase"

    @Test("A title that lost a glyph takes back the DOI's registered title")
    func restoresLostCharacters() {
        #expect(RegisteredPaperTitle.restoringLostCharacters(in: Self.damaged, registered: Self.registered) == Self.registered)
        #expect(RegisteredPaperTitle.restoringLostCharacters(in: Self.registered, registered: Self.registered) == nil)
        #expect(RegisteredPaperTitle.restoringLostCharacters(in: Self.damaged, registered: nil) == nil)
        for (held, registered) in [
            ("Enhancing Mitochondrial Ca Uptake", "Enhancing Mitochondrial Ca²⁺ Uptake"),
            ("Role of NF-B in aging", "Role of NF-κB in aging"),
            ("Role of NF-\u{FFFD}B in aging", "Role of NF-κB in aging"),
            ("The - and -secretases", "The α- and β-secretases"),
            ("A 2 decrease", "A −2 decrease"),
        ] {
            #expect(RegisteredPaperTitle.restoringLostCharacters(in: held, registered: registered) == registered, "\(held)")
        }
        #expect(RegisteredPaperTitle.restoringLostCharacters(in: "Title with", registered: " Title  with\nα ") == "Title with α")
    }

    @Test("An edition's difference, typography or another paper's record leaves the title alone")
    func leavesOtherDifferencesAlone() {
        for (held, registered) in [
            // A footnote letter in the catalog's record.
            ("Mitochondrial Free Radical Production and Aging in Mammals and Birds", "Mitochondrial Free Radical Production and Aging in Mammals and Birdsa"),
            ("Somatic mutations reveal the ontogeny of microglia in human aging", "Somatic mutations reveal the ontogeny of microglia in human ageing"),
            ("A synthetic human genome is still worth building", "Why a synthetic human genome is still worth building"),
            // Typography: flattened scripts, spacing, a soft hyphen.
            ("Enhancing Mitochondrial Ca2+ Uptake", "Enhancing Mitochondrial Ca ²⁺ Uptake"),
            ("Mitochondrial Transplantation Promotes Memory CD4+ T Cell Response", "Mitochondrial Transplantation Promotes Memory CD4 ⁺ T Cell Response"),
            ("Plasma GDF15 affects long-\u{AD} term dementia risk", "Plasma GDF15 affects long-term dementia risk"),
            // A DOI whose record is another paper's.
            ("KL1333, a derivative of β-lapachone, protects against cisplatin-induced ototoxicity", "Cardiac function and tolerance to ischemia/reperfusion injury"),
            // Case, ligature loss, and a title that lost more than it kept.
            ("the -secretase", "The γ-Secretase"),
            ("Specic binding", "Specific binding"),
            ("COVID-19", "Изучение COVID-19 у детей"),
        ] {
            #expect(RegisteredPaperTitle.restoringLostCharacters(in: held, registered: registered) == nil, "\(held)")
        }
    }

    private func paper() -> StudioArticle {
        var paper = StudioArticle(
            url: "https://doi.org/10.1523/jneurosci.1842-04.2004",
            title: "jneurosci.1842 04",
            sourceType: .paper,
            id: "src_901f36ad0112f7d80758f2eb513a32b16d456a4dfdc9f23066a5f132414b8f6a"
        )
        paper.doi = "10.1523/jneurosci.1842-04.2004"
        return paper
    }

    @Test("Metadata extraction keeps the registered title and never the identity it names")
    func extractionAppliesTheRule() {
        let result = AIService.PaperMetadataResult.validated(
            title: Self.damaged,
            author: "Laszlo Tretter; Vera Adam-Vizi",
            journal: "J Neurosci",
            year: "2004",
            doi: "10.1523/jneurosci.1842-04.2004"
        )

        var viaApp = paper()
        StudioViewModel.applyExtractedPaperMetadata(result, to: &viaApp, overwriteTitle: true, registeredTitle: Self.registered)
        #expect(viaApp.title == Self.registered)
        #expect(viaApp.doi == "10.1523/jneurosci.1842-04.2004")
        #expect(viaApp.url == "https://doi.org/10.1523/jneurosci.1842-04.2004")
        #expect(viaApp.id == paper().id)

        var viaMCP = paper()
        let fields = MCPDataStore.applyExtractedPaperMetadata(result, to: &viaMCP, registeredTitle: Self.registered)
        #expect(viaMCP.title == Self.registered)
        #expect(fields.contains("title"))
        #expect(viaMCP.doi == "10.1523/jneurosci.1842-04.2004")

        // A registered title that is another work's leaves the model's reading.
        var mismatched = paper()
        StudioViewModel.applyExtractedPaperMetadata(result, to: &mismatched, overwriteTitle: true, registeredTitle: "Cardiac function and tolerance to ischemia")
        #expect(mismatched.title == Self.damaged)
        // No registered title at all: the model's title stands, as before.
        var unregistered = paper()
        StudioViewModel.applyExtractedPaperMetadata(result, to: &unregistered, overwriteTitle: true)
        #expect(unregistered.title == Self.damaged)
    }
}

// MARK: - Source Type Detection

@Suite("Studio Source Type Detection")
@MainActor
struct StudioSourceTypeDetectionTests {

    @Test("Detects arXiv as paper")
    func arxiv() {
        #expect(StudioViewModel.detectSourceType(url: "https://arxiv.org/abs/2301.07041") == .paper)
    }

    @Test("Detects Nature as paper")
    func nature() {
        #expect(StudioViewModel.detectSourceType(url: "https://www.nature.com/articles/s41586-024-07386-0") == .paper)
    }

    @Test("Detects bioRxiv as paper")
    func biorxiv() {
        #expect(StudioViewModel.detectSourceType(url: "https://www.biorxiv.org/content/10.1101/2024.01.15.123456") == .paper)
    }

    @Test("Detects DOI link as paper")
    func doi() {
        #expect(StudioViewModel.detectSourceType(url: "https://doi.org/10.1038/s41586-024-07386-0") == .paper)
    }

    @Test("Detects NEJM DOI landing page as paper")
    func nejmFullDOIPage() {
        #expect(StudioViewModel.detectSourceType(url: "https://www.nejm.org/doi/full/10.1056/NEJMoa2307817") == .paper)
    }

    @Test("Detects YouTube as video")
    func youtube() {
        #expect(StudioViewModel.detectSourceType(url: "https://www.youtube.com/watch?v=abc123") == .video)
    }

    @Test("Detects youtu.be as video")
    func youtubeShort() {
        #expect(StudioViewModel.detectSourceType(url: "https://youtu.be/abc123") == .video)
    }

    @Test("Detects a Zoom recording as a meeting, and other Zoom links as video")
    func zoomRecording() {
        // A recording of a call is a meeting session, so it lands in the series
        // it is an occurrence of rather than among YouTube videos.
        #expect(StudioViewModel.detectSourceType(url: "https://us02web.zoom.us/rec/share/abc123") == .meeting)
        #expect(StudioViewModel.detectSourceType(url: "https://us02web.zoom.us/rec/play/abc123") == .meeting)
        // A join link or a marketing page is not a recording and keeps the
        // broad video classification the domain list gives it.
        #expect(StudioViewModel.detectSourceType(url: "https://us02web.zoom.us/j/123456789") == .video)
    }

    @Test("Detects read.ai as video")
    func readAI() {
        #expect(StudioViewModel.detectSourceType(url: "https://app.read.ai/analytics/meetings/12345") == .video)
    }

    @Test("Detects Vimeo as video")
    func vimeo() {
        #expect(StudioViewModel.detectSourceType(url: "https://vimeo.com/123456") == .video)
    }

    @Test("Detects Loom as video")
    func loom() {
        #expect(StudioViewModel.detectSourceType(url: "https://www.loom.com/share/abc123") == .video)
    }

    @Test("Detects local PDF as paper")
    func localPDF() {
        #expect(StudioViewModel.detectSourceType(url: "/Users/me/Documents/papers/myfile.pdf") == .paper)
    }

    @Test("Detects Books folder PDF as book")
    func bookPDF() {
        #expect(StudioViewModel.detectSourceType(url: "/Users/me/Documents/Books/chapter.pdf") == .book)
    }

    @Test("Detects Courses path as course")
    func coursePath() {
        #expect(StudioViewModel.detectSourceType(url: "/Users/me/Documents/Courses/lecture.pdf") == .course)
    }

    @Test("Detects podcast paths as podcast")
    func podcastPaths() {
        #expect(StudioViewModel.detectSourceType(url: "/path/to/podcasts/episode.ttml") == .podcast)
        #expect(StudioViewModel.detectSourceType(url: "/path/scrape/transcript.md") == .podcast)
    }

    @Test("Detects blog URLs as unclassified pending LLM classification")
    func blogArticle() {
        #expect(StudioViewModel.detectSourceType(url: "https://paulgraham.com/greatwork.html") == .unclassified)
        #expect(StudioViewModel.detectSourceType(url: "https://substack.com/some-post") == .unclassified)
    }
}

// MARK: - PDF Download Integration Tests

/// Live-network integration tests (arXiv, EuropePMC, NCBI, Unpaywall) are skipped
/// by default: they depend on external services whose data drifts over time (e.g.
/// EuropePMC's PMCID answer for a DOI can change) and whose availability flakes.
/// Run them manually by setting FOREVERLM_NETWORK_TESTS=1 in the test scheme's
/// environment variables (or the shell environment when invoking the test runner).
private let liveNetworkTestsEnabled = ProcessInfo.processInfo.environment["FOREVERLM_NETWORK_TESTS"] == "1"

@Suite("PDF Download Pipeline")
struct PDFDownloadTests {

    private func downloadAndVerifyPDF(from url: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        try await service.downloadPDF(from: url, to: destPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
        // PDF magic bytes: %PDF-
        #expect(data.count > 100, "Downloaded file is too small")
        #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]), "File does not have PDF magic bytes")
    }

    @Test("Downloads arXiv PDF", .enabled(if: liveNetworkTestsEnabled))
    func arxivPDF() async throws {
        try await downloadAndVerifyPDF(from: "https://arxiv.org/pdf/2301.07041.pdf")
    }

    @Test("PMC lookup finds PDF URL for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupFindsPDF() async {
        // PepTune paper — PMC11703081
        let result = await PaperService.lookupPMCByPMCID(pmcid: "PMC11703081")
        #expect(result != nil, "PMC lookup returned nil")
        #expect(result?.pmcid == "PMC11703081")
        // Should find either a direct PDF URL or at least the PMCID for text fallback
        let hasPDF = result?.pdfURL != nil
        let hasPMCID = result?.pmcid != nil
        #expect(hasPDF || hasPMCID, "PMC lookup returned neither PDF URL nor PMCID")
    }

    @Test("PMC full text fetch works for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func pmcFullTextFetch() async {
        let text = await PaperService.fetchPMCFullText(pmcid: "PMC11703081")
        #expect(text != nil, "PMC full text fetch returned nil")
        if let text {
            #expect(text.count > 500, "PMC full text is suspiciously short: \(text.count) chars")
        }
    }

    @Test("PMC article URL returns nil from paperPDFURL (delegates to lookup)")
    func pmcURLReturnsNil() {
        // PMC URLs should NOT return a direct PDF URL — they use the EuropePMC lookup path
        let result = PaperService.paperPDFURL(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11703081/")
        #expect(result == nil)

        let result2 = PaperService.paperPDFURL(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081/")
        #expect(result2 == nil)
    }

    @Test("Extracts PMC ID from various URL formats")
    func pmcIDExtraction() {
        #expect(PaperService.extractPMCID(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11703081/") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081/") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11703081") == "PMC11703081")
        #expect(PaperService.extractPMCID(from: "https://example.com/not-a-pmc-url") == nil)
    }

    @Test("Downloads PDF from direct URL with browser-like headers", .enabled(if: liveNetworkTestsEnabled))
    func downloadWithBrowserHeaders() async throws {
        // PNAS is open access and serves PDFs
        try await downloadAndVerifyPDF(from: "https://arxiv.org/pdf/2505.00784.pdf")
    }
}

// MARK: - Paywall → PMC → PDF Integration Tests

// Live-network suite: every test except the DOI extraction hits EuropePMC, NCBI,
// or Unpaywall. Skipped by default (remote data drifts — a July 2026 run showed
// EuropePMC returning a PMCID other than PMC6345342 for the DOI below); run with
// FOREVERLM_NETWORK_TESTS=1 in the test environment.
@Suite("Paywall to PMC Pipeline")
struct PaywallToPMCTests {

    // Use a Nature Methods paper known to be in PMC:
    // "Deep generative modeling for single-cell transcriptomics"
    // DOI: 10.1038/s41592-018-0229-2, PMCID: PMC6345342
    static let natureDOI = "10.1038/s41592-018-0229-2"
    static let natureURL = "https://www.nature.com/articles/s41592-018-0229-2"
    static let expectedPMCID = "PMC6345342"

    // -- Step 1: DOI extraction from paywalled URL --

    @Test("Extracts DOI from Nature URL")
    func extractDOIFromNature() {
        let doi = PaperService.extractDOI(from: Self.natureURL)
        #expect(doi == Self.natureDOI, "Expected DOI \(Self.natureDOI), got \(doi ?? "nil")")
    }

    @Test("Open-access lookup prefers a stored DOI over the landing URL")
    func openAccessLookupPrefersStoredDOI() {
        let doi = PaperService.openAccessLookupDOI(
            url: "https://publisher.example/article/opaque-id",
            storedDOI: "https://doi.org/10.1000/catalog-doi"
        )
        #expect(doi == "10.1000/catalog-doi")
    }

    @Test("Open-access lookup falls back to a DOI encoded in the URL")
    func openAccessLookupFallsBackToURL() {
        let doi = PaperService.openAccessLookupDOI(
            url: "https://doi.org/10.1000/url-doi",
            storedDOI: nil
        )
        #expect(doi == "10.1000/url-doi")
    }

    // -- Step 2: PMC lookup by DOI --

    @Test("EuropePMC finds PMCID for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupByDOI() async {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        #expect(result != nil, "EuropePMC returned nil for DOI \(Self.natureDOI)")
        if let result {
            #expect(result.pmcid != nil, "EuropePMC returned no PMCID")
            #expect(result.pmcid == Self.expectedPMCID, "Expected \(Self.expectedPMCID), got \(result.pmcid ?? "nil")")
        }
    }

    @Test("EuropePMC lookup returns a PDF URL for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func pmcLookupReturnsPDFURL() async {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        #expect(result != nil, "EuropePMC returned nil")
        if let result {
            #expect(result.pdfURL != nil, "EuropePMC returned PMCID \(result.pmcid ?? "?") but no PDF URL — this means the download will need BioC/efetch text fallback")
            if let pdfURL = result.pdfURL {
                #expect(pdfURL.hasPrefix("http"), "PDF URL is not an HTTP URL: \(pdfURL)")
            }
        }
    }

    // -- Step 3: PDF URL from EuropePMC is actually downloadable --

    @Test("PDF URL from EuropePMC actually serves a valid PDF", .enabled(if: liveNetworkTestsEnabled))
    func downloadPDFFromEuropePMCURL() async throws {
        let result = await PaperService.lookupPMC(doi: Self.natureDOI)
        guard let pdfURL = result?.pdfURL else {
            // No PDF URL from EuropePMC — check if text fallback would work instead
            if let pmcid = result?.pmcid {
                let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
                #expect(text != nil, "No PDF URL and BioC text fallback also failed for \(pmcid)")
            } else {
                Issue.record("EuropePMC returned neither PDF URL nor PMCID for DOI \(Self.natureDOI)")
            }
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        do {
            try await service.downloadPDF(from: pdfURL, to: destPath)
            let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
            #expect(data.count > 100, "Downloaded file is too small (\(data.count) bytes)")
            #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                    "File from \(pdfURL) does not have PDF magic bytes — got \(String(data: data.prefix(20), encoding: .utf8) ?? "binary")")
        } catch {
            Issue.record("Download from EuropePMC PDF URL failed: \(pdfURL) — \(error)")
        }
    }

    // -- Step 4: Unpaywall fallback --

    @Test("Unpaywall finds OA PDF for Nature DOI", .enabled(if: liveNetworkTestsEnabled))
    func unpaywallFindsPDF() async {
        let pdfURL = await PaperService.lookupUnpaywall(doi: Self.natureDOI)
        // Unpaywall may or may not have this — just log
        if let pdfURL {
            #expect(pdfURL.hasPrefix("http"), "Unpaywall PDF URL is not HTTP: \(pdfURL)")
        }
    }

    @Test("Unpaywall exposes every OA PDF candidate after the preferred URL")
    func unpaywallExposesAllPDFCandidates() {
        let json: [String: Any] = [
            "is_oa": true,
            "best_oa_location": [
                "host_type": "publisher",
                "url_for_pdf": "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
            ],
            "oa_locations": [
                [
                    "host_type": "publisher",
                    "url_for_pdf": "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
                ],
                [
                    "host_type": "repository",
                    "url_for_pdf": "https://www.biorxiv.org/content/biorxiv/early/2025/06/04/2025.06.04.657785.full.pdf",
                ],
                [
                    "host_type": "repository",
                    "url_for_pdf": "https://pmc.ncbi.nlm.nih.gov/articles/PMC13403736/pdf/ADVS-9999-e76740.pdf",
                ],
            ],
        ]

        let candidates = PaperService.unpaywallPDFURLs(from: json)

        #expect(candidates == [
            "https://onlinelibrary.wiley.com/doi/pdfdirect/10.1002/advs.76740",
            "https://www.biorxiv.org/content/biorxiv/early/2025/06/04/2025.06.04.657785.full.pdf",
            "https://pmc.ncbi.nlm.nih.gov/articles/PMC13403736/pdf/ADVS-9999-e76740.pdf",
        ])
    }

    @Test("Unpaywall rejects malformed candidates without discarding valid ones")
    func unpaywallFiltersMalformedPDFCandidates() {
        let json: [String: Any] = [
            "is_oa": true,
            "best_oa_location": [
                "host_type": "publisher",
                "url_for_pdf": "not a URL",
            ],
            "oa_locations": [
                ["url_for_pdf": "file:///tmp/paper.pdf"],
                ["url_for_pdf": "https://repository.example/paper.pdf"],
            ],
        ]

        #expect(PaperService.unpaywallPDFURLs(from: json) == [
            "https://repository.example/paper.pdf",
        ])
    }

    @Test("OA candidate pipeline reaches a readable copy after an inaccessible lead", .enabled(if: liveNetworkTestsEnabled))
    func openAccessCandidateFallbackDownloadsPasta() async throws {
        let sourceURL = "https://advanced.onlinelibrary.wiley.com/doi/full/10.1002/advs.76740"
        let alternatives = await PaperService.findOpenAccessAlternatives(
            url: sourceURL,
            title: "Pasta, a Versatile Transcriptomic Clock, Maps the Chemical and Genetic Determinants of Aging and Rejuvenation",
            doi: "10.1002/advs.76740"
        )
        #expect(alternatives.count > 1, "Expected multiple independent OA leads")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent("pasta.pdf")

        var downloadedFrom: String?
        var failures: [String] = []
        for alternative in alternatives {
            do {
                try await SourceService.shared.downloadPDF(
                    from: alternative.replacementURL,
                    to: destination.path
                )
                guard SourceService.canOpenPDF(at: destination.path) else {
                    throw SourceError.pdfReadFailed
                }
                downloadedFrom = alternative.replacementURL
                break
            } catch {
                failures.append("\(alternative.replacementURL): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destination)
            }
        }

        #expect(
            downloadedFrom != nil,
            "No discovered OA candidate returned a readable PDF: \(failures.joined(separator: "; "))"
        )
    }

    // -- Step 5: Text fallback when PDF is unavailable --

    @Test("BioC full text works as fallback for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func biocTextFallback() async {
        let text = await PaperService.fetchPMCFullText(pmcid: Self.expectedPMCID)
        #expect(text != nil, "BioC full text returned nil for \(Self.expectedPMCID)")
        if let text {
            #expect(text.count > 500, "BioC full text suspiciously short: \(text.count) chars")
        }
    }

    @Test("efetch JATS XML works as fallback for known PMCID", .enabled(if: liveNetworkTestsEnabled))
    func efetchTextFallback() async {
        let text = await PaperService.fetchPMCFullTextViaEfetch(pmcid: Self.expectedPMCID)
        #expect(text != nil, "efetch returned nil for \(Self.expectedPMCID)")
        if let text {
            #expect(text.count > 500, "efetch text suspiciously short: \(text.count) chars")
        }
    }

    // -- Step 6: End-to-end findOpenAccessAlternative --

    @Test("findOpenAccessAlternative finds PMC version for Nature URL", .enabled(if: liveNetworkTestsEnabled))
    func findOAAlternative() async {
        let result = await PaperService.findOpenAccessAlternative(url: Self.natureURL, title: "Deep generative modeling for single-cell transcriptomics")
        #expect(result != nil, "findOpenAccessAlternative returned nil for \(Self.natureURL)")
        if let result {
            #expect(result.replacementURL.contains("pmc") || result.replacementURL.contains("ncbi") || result.replacementURL.contains("europepmc"),
                    "Expected PMC/NCBI URL, got: \(result.replacementURL) from \(result.sourceName)")
        }
    }

    // -- Step 7: End-to-end — the replacement URL's PDF is downloadable --

    @Test("Replacement URL from findOpenAccessAlternative leads to downloadable PDF", .enabled(if: liveNetworkTestsEnabled))
    func oaAlternativeDownloadsPDF() async throws {
        guard let alternative = await PaperService.findOpenAccessAlternative(url: Self.natureURL, title: "Deep generative modeling") else {
            Issue.record("No OA alternative found — can't test download")
            return
        }

        let replacementURL = alternative.replacementURL
        // The replacement URL is typically a PMC article URL — extract PMCID and do lookup
        var pdfURL: String?

        if let directPDF = PaperService.paperPDFURL(from: replacementURL) {
            pdfURL = directPDF
        } else if let pmcid = PaperService.extractPMCID(from: replacementURL) {
            // This is the exact path downloadPaperPDF takes
            let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid)
            pdfURL = pmcResult?.pdfURL
            if pdfURL == nil, let pmcid = pmcResult?.pmcid {
                // No PDF — check text fallback
                let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
                #expect(text != nil, "Replacement URL \(replacementURL) has no downloadable PDF and BioC text fallback failed for \(pmcid)")
                return  // Text fallback is acceptable
            }
        }

        guard let pdfURL else {
            Issue.record("Could not derive PDF URL from replacement URL: \(replacementURL)")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destPath = tempDir.appendingPathComponent("test.pdf").path
        let service = SourceService()
        do {
            try await service.downloadPDF(from: pdfURL, to: destPath)
            let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
            #expect(data.count > 100, "Downloaded file too small: \(data.count) bytes from \(pdfURL)")
            #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                    "Not a PDF from \(pdfURL) — first bytes: \(String(data: data.prefix(40), encoding: .utf8) ?? "binary")")
        } catch {
            Issue.record("PDF download failed from \(pdfURL) (via \(alternative.sourceName)): \(error)")
        }
    }

    // -- Step 8: PMCID-based lookup for direct PMC URL (non-paywalled PMC path) --

    @Test("Direct PMC URL → lookupPMCByPMCID → PDF download works end-to-end", .enabled(if: liveNetworkTestsEnabled))
    func directPMCURLPipeline() async throws {
        let pmcURL = "https://pmc.ncbi.nlm.nih.gov/articles/\(Self.expectedPMCID)/"

        // paperPDFURL should return nil for PMC URLs
        #expect(PaperService.paperPDFURL(from: pmcURL) == nil)

        // extractPMCID should work
        let pmcid = PaperService.extractPMCID(from: pmcURL)
        #expect(pmcid == Self.expectedPMCID)

        // lookupPMCByPMCID should find something
        guard let pmcid else { return }
        let result = await PaperService.lookupPMCByPMCID(pmcid: pmcid)
        #expect(result != nil, "lookupPMCByPMCID returned nil for \(pmcid)")

        guard let result else { return }

        if let pdfURL = result.pdfURL {
            // Try downloading the PDF
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let destPath = tempDir.appendingPathComponent("test.pdf").path
            let service = SourceService()
            do {
                try await service.downloadPDF(from: pdfURL, to: destPath)
                let data = try Data(contentsOf: URL(fileURLWithPath: destPath))
                #expect(data.prefix(5) == Data([0x25, 0x50, 0x44, 0x46, 0x2D]),
                        "Not a PDF from \(pdfURL)")
            } catch {
                Issue.record("PDF download from \(pdfURL) failed: \(error) — this is likely the bug causing 'Could not load PDF'")
            }
        } else if let pmcid = result.pmcid {
            // Text fallback should work
            let text = await PaperService.fetchPMCFullText(pmcid: pmcid)
            #expect(text != nil, "No PDF URL and BioC text fallback also failed for \(pmcid)")
        } else {
            Issue.record("lookupPMCByPMCID returned neither pdfURL nor pmcid")
        }
    }
}

@Suite("Substack Post Extraction")
struct SubstackPostExtractionTests {
    static let substackHTML = """
    <html><body>
    <article class="typography newsletter-post post">
      <div class="post-header">
        <h1 dir="auto" class="post-title published title-X77sOw">Uneven Frontiers</h1>
        <h3 dir="auto" class="subtitle subtitle-HEEcLo">How AI will transform biopharma</h3>
        <div class="byline-wrapper">
          <img src="avatar.png" alt="Benjamine Liu">
          <a href="/about">Benjamine Liu</a><div>Jun 17, 2026</div>
        </div>
        <div class="post-ufi style-compressed justified themed">
          <div class="like-button-container post-ufi-button">716</div>
          <button class="post-ufi-button">Share</button>
        </div>
      </div>
      <div class="available-content">
        <div dir="auto" class="body markup">
          <p>First paragraph of the post.</p>
          <div class="captioned-image-container"><figure><img src="chart.png"></figure></div>
          <p>Second paragraph.</p>
        </div>
        <div class="subscription-widget"><button>Subscribe to continue</button></div>
      </div>
      <div class="post-ufi style-compressed">footer toolbar</div>
    </article>
    </body></html>
    """

    @Test("Extracts authored Substack content without publication chrome")
    func extractsSpecialPostSlice() throws {
        let extracted = try #require(SourceService.substackPostHTML(from: Self.substackHTML))

        #expect(extracted.contains("<h1>Uneven Frontiers</h1>"))
        #expect(extracted.contains("<h3>How AI will transform biopharma</h3>"))
        #expect(extracted.contains("First paragraph of the post."))
        #expect(extracted.contains("chart.png"))
        #expect(extracted.contains("Second paragraph."))
        #expect(!extracted.contains("avatar.png"))
        #expect(!extracted.contains("Benjamine Liu"))
        #expect(!extracted.contains("Jun 17, 2026"))
        #expect(!extracted.contains("footer toolbar"))
        #expect(!extracted.contains("Share"))
        #expect(!extracted.contains("Subscribe to continue"))
    }

    @Test("Reader and synced text use the same clean Substack boundary")
    func readerUsesSpecialPostSlice() {
        let readerHTML = SourceService.readerHTML(from: Self.substackHTML)
        let text = SourceService.readableTextFromHTML(Self.substackHTML)

        #expect(readerHTML.contains("Uneven Frontiers"))
        #expect(readerHTML.contains("First paragraph of the post."))
        #expect(!readerHTML.contains("avatar.png"))
        #expect(!readerHTML.contains("footer toolbar"))
        #expect(text.contains("# Uneven Frontiers"))
        #expect(text.contains("### How AI will transform biopharma"))
        #expect(text.contains("First paragraph of the post."))
        #expect(!text.contains("Benjamine Liu"))
        #expect(!text.contains("Share"))
        #expect(!text.contains("Subscribe to continue"))
    }

    @Test("Returns nil for pages without a Substack body container")
    func returnsNilForNonSubstackPages() {
        let html = "<html><body><article><p>Regular article content.</p></article></body></html>"
        #expect(SourceService.substackPostHTML(from: html) == nil)
    }
}

/// A page its scripts write: what `substack.com/home/post/p-214954598` (Alex
/// Plesa's "AI for Bio Doesn't Need More Data") answered a signed-in fetch
/// with on 2026-10-06, the post only in script data. The plain fetch took it
/// as the article and the source was saved as its navigation bar.
@Suite("Pages written by script")
struct ScriptRenderedPageTests {
    static let signedInShell = """
    <!DOCTYPE html><html><head>
    <title data-rh="true">AI for Bio Doesn’t Need More Data - by Alex Plesa</title>
    <link rel="canonical" href="https://substack.com/home/post/p-214954598" />
    <meta name="author" content="Substack"/>
    </head><body>
    <div id="entry"><div class="reader-nav">
    <a aria-label="Home" role="button" href="https://substack.com/">Home</a>
    <a aria-label="Subscriptions" role="button" href="https://substack.com/inbox">Subscriptions</a>
    <a aria-label="Chat" role="button" href="https://substack.com/chat">Chat</a>
    <a aria-label="Activity" role="button" href="https://substack.com/activity">Activity</a>
    <a aria-label="Explore" role="button" href="https://substack.com/explore">Explore</a>
    <a aria-label="Dashboard" role="button" href="https://substack.com/dashboard">Dashboard</a>
    <a aria-label="Profile" role="button" href="https://substack.com/profile">Profile</a>
    <button>Create</button><button>More</button>
    <div>What&#x27;s on your mind?</div><div>For you</div>
    </div>
    <div>This site requires JavaScript to run correctly. Please turn on JavaScript or unblock scripts</div>
    </div>
    <script>window._preloads = JSON.parse("{\\"post\\":{\\"body_html\\":\\"<p>It needs instruments.</p>\\"}}")</script>
    </body></html>
    """

    /// The same post once a browser has run the page's scripts.
    static let renderedPost: String = {
        let paragraph = "<p>Biology does not lack data so much as instruments that can keep up with a living cell, measuring it while it changes.</p>"
        return """
        <html><head><title>AI for Bio Doesn’t Need More Data - by Alex Plesa</title></head><body>
        <div class="available-content"><div dir="auto" class="body markup">
        \(String(repeating: paragraph, count: 20))
        </div></div>
        </body></html>
        """
    }()

    @Test("The shell reads too thin to be taken as it came")
    func shellIsBelowThreshold() {
        let words = SourceService.readableWordCount(ofHTML: Self.signedInShell)
        #expect(words < SourceService.scriptRenderedPageWordThreshold)
        #expect(SourceService.readableWordCount(ofHTML: Self.renderedPost)
            >= SourceService.scriptRenderedPageWordThreshold)
    }

    @Test("The browser's copy wins when it reads longer than the shell")
    func renderedCopyReplacesShell() {
        let chosen = SourceService.fullerPageHTML(fetched: Self.signedInShell, rendered: Self.renderedPost)
        #expect(chosen == Self.renderedPost)
        let text = SourceService.readableTextFromHTML(chosen ?? "")
        #expect(text.contains("instruments that can keep up with a living cell"))
        #expect(!text.contains("Subscriptions"))
    }

    @Test("A short page that needs no script keeps its fetched copy")
    func shortPlainPageKeepsFetchedCopy() {
        let note = "<html><body><article><p>A short note that is the whole page.</p></article></body></html>"
        let sameNoteRendered = "<html><body><p>A short note.</p></body></html>"
        #expect(SourceService.fullerPageHTML(fetched: note, rendered: sameNoteRendered) == note)
        #expect(SourceService.fullerPageHTML(fetched: note, rendered: nil) == note)
        #expect(SourceService.fullerPageHTML(fetched: note, rendered: " \n ") == note)
    }

    @Test("Whichever copy exists is used when the other could not be had")
    func missingCopies() {
        #expect(SourceService.fullerPageHTML(fetched: nil, rendered: Self.renderedPost) == Self.renderedPost)
        #expect(SourceService.fullerPageHTML(fetched: nil, rendered: nil) == nil)
        #expect(SourceService.fullerPageHTML(fetched: nil, rendered: "  ") == nil)
    }
}

@Suite("Semantic Article Extraction")
struct SemanticArticleExtractionTests {
    @Test("Keeps the complete visible body")
    func preservesVisibleBody() {
        let html = """
        <html><body>
          <header>Site navigation</header>
          <div class="entry-content article-body-copy">
            <h2>Challenge and Opportunity</h2>
            <p>The real article begins here with enough material to read comfortably.</p>
            <div class="nested"><p>The nested conclusion remains part of the article.</p></div>
            <ul><li>First recommendation</li><li>Second recommendation</li></ul>
            <p>A result increased<sup>12</sup> after treatment.</p>
          </div>
          <section class="related-posts">
            <p>Unrelated critical-minerals story</p><a>read more</a>
            <p>Unrelated technology story</p><a>read more</a>
          </section>
        </body></html>
        """

        let readerHTML = SourceService.readerHTML(from: html)
        let text = SourceService.readableTextFromHTML(html)

        #expect(readerHTML.contains("The nested conclusion remains part of the article."))
        #expect(readerHTML.contains("Unrelated critical-minerals story"))
        #expect(text.contains("## Challenge and Opportunity"))
        #expect(text.contains("- First recommendation"))
        #expect(text.contains("- Second recommendation"))
        #expect(text.contains("increased^(12) after treatment"))
        #expect(text.localizedCaseInsensitiveContains("read more"))
        #expect(text.contains("Site navigation"))
    }

    @Test("Keeps in-page anchor targets that live on stripped wrappers")
    func keepsLinkedAnchorTargets() {
        let html = """
        <body>
          <main id="page">
            <p><a href="#priority-1">Priority #1</a> <a href="#summary">Summary</a></p>
            <div class="anchor" id="summary"></div>
            <h2 id="overview">Executive Summary</h2>
            <section class="anchor" id="priority-1"><p>Accelerating the path to market.</p></section>
            <div id="sqs-block-9f21c4">Unlinked block wrapper.</div>
          </main>
        </body>
        """

        let readerHTML = SourceService.readerHTML(from: html)

        #expect(readerHTML.contains("<a id=\"summary\"></a>"))
        #expect(readerHTML.contains("<a id=\"priority-1\"></a>"))
        // Ids on allowed tags survive on their own element.
        #expect(readerHTML.contains("<h2 id=\"overview\">"))
        // Unreferenced wrapper ids stay out; pages carry hundreds of them.
        #expect(!readerHTML.contains("sqs-block-9f21c4"))
        #expect(readerHTML.contains("Accelerating the path to market."))
        #expect(readerHTML.contains("Unlinked block wrapper."))
    }

    @Test("Rewrites relative links to absolute so the archive can follow them")
    func absolutizesRelativeLinks() throws {
        let base = try #require(URL(string: "https://amaranth.foundation/bottlenecks-of-aging"))
        let html = """
        <p><a href="/team">Team</a> <a href="notes.html">Notes</a>
        <a href='/engage'>Engage</a>
        <a href="#priority-1">Priority #1</a>
        <a href="mailto:info@amaranth.foundation">Email</a>
        <a href="https://example.com/paper">Paper</a></p>
        """

        let rewritten = SourceService.absolutizingLinks(in: html, baseURL: base)

        #expect(rewritten.contains("href=\"https://amaranth.foundation/team\""))
        #expect(rewritten.contains("href='https://amaranth.foundation/engage'"))
        #expect(rewritten.contains("href=\"https://amaranth.foundation/notes.html\""))
        #expect(rewritten.contains("href=\"#priority-1\""))
        #expect(rewritten.contains("href=\"mailto:info@amaranth.foundation\""))
        #expect(rewritten.contains("href=\"https://example.com/paper\""))
    }

    @Test("Relative links resolve against a declared base href")
    func resolvesAgainstDeclaredBase() throws {
        let pageURL = try #require(URL(string: "https://example.com/blog/post"))
        let html = "<html><head><base href=\"https://cdn.example.com/site/\"></head><body></body></html>"

        let base = SourceService.linkResolutionBase(forRawHTML: html, pageURL: pageURL)
        let rewritten = SourceService.absolutizingLinks(in: "<a href=\"team\">Team</a>", baseURL: base)

        #expect(rewritten.contains("href=\"https://cdn.example.com/site/team\""))
    }

    @Test("Preserves visible siblings while removing scripts")
    func preservesVisibleSiblings() {
        let html = """
        <body>
          <script>const template = '<div class="entry-content">Script template junk</div>';</script>
          <div itemprop="articleBody"><p>Schema-marked article text.</p></div>
          <div><p>Newsletter signup and unrelated footer copy.</p></div>
        </body>
        """

        let text = SourceService.readableTextFromHTML(html)

        #expect(text.contains("Schema-marked article text."))
        #expect(text.contains("Newsletter signup and unrelated footer copy."))
        #expect(!text.contains("Script template junk"))
    }

    /// The Illustrated AlphaFold (2026-10-06): Distill draws its footnotes with
    /// a script, so the stripped element ran each note into its sentence —
    /// "nearby atomsSpecifically, for an atom-pair l,m…".
    @Test("Distill footnotes become numbered notes after the article instead of running into the sentence")
    func numbersDistillFootnotes() {
        let html = """
        <body><d-article>
          <p>we only want the model to focus on nearby atoms<d-footnote>Specifically, for an atom-pair <em>l,m</em>, we ignore the loss.</d-footnote>.</p>
          <p>Search relies on HMM methods<d-footnote><p>Specifically, they use jackhmmer, HHBlits, and nhmmer</p></d-footnote> to scan databases.</p>
        </d-article>
        <d-appendix><d-footnote-list></d-footnote-list></d-appendix></body>
        """

        let readerHTML = SourceService.readerHTML(from: html)
        let text = SourceService.readableTextFromHTML(html)

        #expect(readerHTML.contains("nearby atoms<sup><a href=\"#flm-footnote-1\" id=\"flm-footnote-ref-1\">1</a></sup>."))
        #expect(readerHTML.contains("<p id=\"flm-footnote-1\"><sup>1</sup> Specifically, for an atom-pair <em>l,m</em>, we ignore the loss.</p>"))
        #expect(!readerHTML.lowercased().contains("d-footnote"))
        #expect(text.contains("focus on nearby atoms^(1)."))
        #expect(text.contains("HMM methods^(2) to scan databases."))
        #expect(!text.contains("atomsSpecifically"))
        #expect(text.contains("## Footnotes"))
        #expect(text.contains("^(1) Specifically, for an atom-pair l,m, we ignore the loss."))
        // A note's own paragraph does not split it from its number, and the
        // appendix's empty footnote list is no note.
        #expect(text.contains("^(2) Specifically, they use jackhmmer, HHBlits, and nhmmer"))
        #expect(!text.contains("^(3)"))
    }

    @Test("A page without inline footnotes is left as it was")
    func leavesPagesWithoutFootnotes() {
        let html = "<p>A sentence with a <span>wrapped</span> word.</p>"
        #expect(SourceService.numberingInlineFootnotes(in: html) == html)
    }

    @Test("A disclosure's label is a line of its own")
    func disclosureLabelStandsAlone() {
        let html = """
        <body><details> <summary>So how are these sequences retrieved?</summary> First, a genetic search is done.</details></body>
        """

        let text = SourceService.readableTextFromHTML(html)

        #expect(text.contains("So how are these sequences retrieved?\nFirst, a genetic search is done."))
    }
}

@Suite("HTML Character Reference Decoding")
struct HTMLCharacterReferenceDecodingTests {
    @Test("Repairs UTF-8 text decoded as Windows-1252")
    func repairsUTF8Mojibake() {
        #expect(
            "itâ€™s safer when weâ€™re careful; cafÃ©; ðŸ˜€".repairingUTF8Mojibake()
                == "it’s safer when we’re careful; café; 😀"
        )
        #expect("FranÃƒÂ§ois".repairingUTF8Mojibake() == "François")
        #expect("François — déjà vu".repairingUTF8Mojibake() == "François — déjà vu")
        #expect(SourceService.readerHTML(from: "<body><p>weâ€™re ready</p></body>").contains("we’re ready"))
    }

    @Test("Decodes named and numeric references")
    func decodesNamedAndNumericReferences() {
        let raw = "I&#39;ve heard people say &ldquo;I don&rsquo;t have a very good memory&rdquo;"
        #expect(
            raw.decodingHTMLCharacterReferences()
                == "I've heard people say \u{201C}I don\u{2019}t have a very good memory\u{201D}"
        )
        #expect("Jan Pokorn&yacute;".decodingHTMLCharacterReferences() == "Jan Pokorn\u{00FD}")
        #expect("TGF-&#946;1".decodingHTMLCharacterReferences() == "TGF-\u{03B2}1")
        #expect("-2.90&deg;".decodingHTMLCharacterReferences() == "-2.90\u{00B0}")
        #expect("mem&#xF3;ria".decodingHTMLCharacterReferences() == "mem\u{00F3}ria")
    }

    /// The regression that made the iOS reader show `&ldquo;` verbatim: a
    /// pass-per-entity decoder substituted `&amp;` first and then re-read its own
    /// output, so one decoding level could turn into two — or into none.
    @Test("Decodes exactly one level")
    func decodesExactlyOneLevel() {
        #expect("Ernst &amp; Young".decodingHTMLCharacterReferences() == "Ernst & Young")
        // Text that means the literal characters `&ldquo;` stays that way.
        #expect(
            "Use &amp;ldquo; for a left quote".decodingHTMLCharacterReferences()
                == "Use &ldquo; for a left quote"
        )
        #expect("M&amp;amp;M".decodingHTMLCharacterReferences() == "M&amp;M")
        #expect("M&amp;amp;M".decodingDoubleEscapedHTMLCharacterReferences() == "M&M")
    }

    @Test("Leaves ampersands that are not references alone")
    func leavesBareAmpersandsAlone() {
        #expect("AT&T and Q&A".decodingHTMLCharacterReferences() == "AT&T and Q&A")
        #expect("&notarealentity;".decodingHTMLCharacterReferences() == "&notarealentity;")
        #expect("trailing &".decodingHTMLCharacterReferences() == "trailing &")
        #expect("&;".decodingHTMLCharacterReferences() == "&;")
        // No semicolon anywhere after the ampersand: the scan must not walk the
        // rest of the document looking for one.
        #expect("a & b, c & d".decodingHTMLCharacterReferences() == "a & b, c & d")
    }
}

@Suite("Source Web Destination")
struct SourceWebDestinationTests {
    private func paper(url: String, title: String = "A paper", doi: String? = nil, paywalled: Bool = false) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: .paper)
        article.doi = doi
        article.isPaywalled = paywalled
        return article
    }

    @Test("Paywalled publisher page opens as stored")
    func paywalledPublisherPage() {
        let article = paper(url: "https://www.nature.com/articles/s41586-024-07386-0", paywalled: true)
        let destination = BrowserService.sourceWebDestination(for: article)
        #expect(destination?.url.absoluteString == "https://www.nature.com/articles/s41586-024-07386-0")
        #expect(destination?.isSearch == false)
    }

    @Test("A direct PDF URL resolves to its landing page")
    func directPDFResolvesToLandingPage() {
        let biorxiv = paper(url: "https://www.biorxiv.org/content/10.1101/2022.03.16.484643v1.full.pdf")
        #expect(
            BrowserService.sourceWebDestination(for: biorxiv)?.url.absoluteString
                == "https://www.biorxiv.org/content/10.1101/2022.03.16.484643v1"
        )

        let arxiv = paper(url: "https://arxiv.org/pdf/2301.07041.pdf")
        #expect(
            BrowserService.sourceWebDestination(for: arxiv)?.url.absoluteString
                == "https://arxiv.org/abs/2301.07041"
        )
    }

    @Test("A direct PDF with no known landing page falls back to the DOI")
    func directPDFFallsBackToDOI() {
        let article = paper(url: "https://publisher.example.com/download/article.pdf", doi: "10.1000/example.1")
        let destination = BrowserService.sourceWebDestination(for: article)
        #expect(destination?.url.absoluteString == "https://doi.org/10.1000/example.1")
        #expect(destination?.isSearch == false)
    }

    @Test("A direct PDF with neither landing page nor DOI still opens the PDF")
    func directPDFWithoutDOIOpensThePDF() {
        let article = paper(url: "https://publisher.example.com/download/article.pdf")
        #expect(
            BrowserService.sourceWebDestination(for: article)?.url.absoluteString
                == "https://publisher.example.com/download/article.pdf"
        )
    }

    @Test("A paper stored as a local PDF opens its DOI")
    func localPaperOpensDOI() {
        let article = paper(url: "Papers/10.1021_acs.jmedchem.5c03222.pdf", doi: "10.1021/acs.jmedchem.5c03222")
        let destination = BrowserService.sourceWebDestination(for: article)
        #expect(destination?.url.absoluteString == "https://doi.org/10.1021/acs.jmedchem.5c03222")
        #expect(destination?.isSearch == false)
    }

    @Test("A paper with no link at all falls back to a title search")
    func localPaperWithoutDOISearches() {
        let article = paper(url: "Papers/scan.pdf", title: "Hallmarks of aging")
        let destination = BrowserService.sourceWebDestination(for: article)
        #expect(destination?.url.absoluteString == "https://scholar.google.com/scholar?q=Hallmarks%20of%20aging")
        #expect(destination?.isSearch == true)
    }

    @Test("Non-paper sources offer no destination without a web URL")
    func nonPaperLocalSourceHasNoDestination() {
        let book = StudioArticle(url: "Books/some-book.epub", title: "Some book", sourceType: .book)
        #expect(BrowserService.sourceWebDestination(for: book) == nil)
    }

    @Test("A podcast without a web URL uses its episode page")
    func podcastUsesEpisodePage() {
        var episode = StudioArticle(url: "Podcasts/episode.ttml", title: "Episode", sourceType: .podcast)
        episode.podcastWebPageURL = "https://podcasts.apple.com/us/podcast/episode/id1?i=2"
        #expect(
            BrowserService.sourceWebDestination(for: episode)?.url.absoluteString
                == "https://podcasts.apple.com/us/podcast/episode/id1?i=2"
        )
    }

    @Test("An article opens its own URL")
    func articleOpensItsURL() {
        let article = StudioArticle(url: "https://example.com/post", title: "Post", sourceType: .article)
        let destination = BrowserService.sourceWebDestination(for: article)
        #expect(destination?.url.absoluteString == "https://example.com/post")
        #expect(destination?.isSearch == false)
    }
}

/// `URLNormalizer` keys one YouTube video under one address, whatever path
/// the link took: a Short saved from Brave and the same video shared as a
/// watch link were two sources, two transcripts and two AI runs until
/// 2026-09-19.
@Suite("URL normalizer: YouTube")
struct URLNormalizerYouTubeTests {
    @Test("shorts, embed, v and live paths collapse to the watch address")
    func youtubePathsCollapse() {
        let canonical = "youtube.com/watch?v=dQw4w9WgXcQ"
        for address in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://youtube.com/embed/dQw4w9WgXcQ?autoplay=1",
            "https://www.youtube.com/v/dQw4w9WgXcQ",
            "https://www.youtube.com/live/dQw4w9WgXcQ?feature=share",
        ] {
            #expect(URLNormalizer.normalize(address) == canonical, Comment(rawValue: address))
        }
    }

    @Test("a YouTube path that is not a video keeps its own address")
    func otherYouTubePagesStay() {
        #expect(URLNormalizer.normalize("https://www.youtube.com/shorts/") != "youtube.com/watch?v=")
        #expect(!URLNormalizer.normalize("https://www.youtube.com/@channel/videos").contains("watch?v="))
        #expect(!URLNormalizer.normalize("https://www.youtube.com/playlist?list=PL123").contains("watch?v="))
    }
}


/// Open-access recovery for a paywalled paper, as measured on 2026-09-23:
/// Europe PMC's `?pdf=render` answers apps with 403, NCBI's own `/pdf/` route
/// works, green copies are often listed with a landing page and no PDF, and a
/// refusal has to say what the host answered.
@Suite("Open-access PDF recovery")
struct OpenAccessPDFRecoveryTests {
    @Test("PMC's short /pdf/ link resolves to NCBI's PDF route; its article page still delegates")
    func pmcShortPDFRoute() {
        #expect(PaperService.paperPDFURL(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf/")
            == "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf/")
        #expect(PaperService.paperPDFURL(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf")
            == "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf/")
        #expect(PaperService.paperPDFURL(from: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8621950/pdf/")
            == "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf/")
        #expect(PaperService.paperPDFURL(from: "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/") == nil)
        // The file the route redirects to is already a PDF address.
        let file = "https://pmc.ncbi.nlm.nih.gov/articles/PMC8621950/pdf/nihms-1720171.pdf"
        #expect(PaperService.paperPDFURL(from: file) == file)
    }

    @Test("NCBI's PDF route is built from a PMCID in either spelling or an article URL")
    func ncbiRouteConstruction() {
        #expect(PaperService.ncbiPMCPDFURL(pmcid: "PMC6212323") == "https://pmc.ncbi.nlm.nih.gov/articles/PMC6212323/pdf/")
        #expect(PaperService.ncbiPMCPDFURL(pmcid: "pmc6212323") == "https://pmc.ncbi.nlm.nih.gov/articles/PMC6212323/pdf/")
        #expect(PaperService.ncbiPMCPDFURL(pmcid: "6212323") == "https://pmc.ncbi.nlm.nih.gov/articles/PMC6212323/pdf/")
        #expect(PaperService.ncbiPMCPDFURL(forArticleURL: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6212323/")
            == "https://pmc.ncbi.nlm.nih.gov/articles/PMC6212323/pdf/")
        #expect(PaperService.ncbiPMCPDFURL(forArticleURL: "https://example.org/paper") == nil)
    }

    @Test("PMC host and short-route detection ignore look-alikes")
    func pmcHostDetection() {
        #expect(PaperService.isNCBIPMCURL("https://pmc.ncbi.nlm.nih.gov/articles/PMC1/"))
        #expect(PaperService.isNCBIPMCURL("https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1/"))
        #expect(!PaperService.isNCBIPMCURL("https://www.ncbi.nlm.nih.gov/pubmed/123"))
        #expect(!PaperService.isNCBIPMCURL("https://europepmc.org/articles/PMC1"))
        #expect(!PaperService.isNCBIPMCURL("https://pmc.ncbi.nlm.nih.gov.example.com/articles/PMC1/"))
        #expect(PaperService.isNCBIPMCShortPDFRoute("https://pmc.ncbi.nlm.nih.gov/articles/PMC1/pdf/"))
        #expect(!PaperService.isNCBIPMCShortPDFRoute("https://pmc.ncbi.nlm.nih.gov/articles/PMC1/pdf/main.pdf"))
        #expect(!PaperService.isNCBIPMCShortPDFRoute("https://pmc.ncbi.nlm.nih.gov/articles/PMC1/"))
    }

    @Test("Europe PMC's rendered PDF is recognised as a PDF address")
    func europePMCRender() {
        #expect(PaperService.isEuropePMCRenderedPDFURL("https://europepmc.org/articles/pmc6212323?pdf=render"))
        #expect(PaperService.isEuropePMCRenderedPDFURL("https://europepmc.org/backend/ptpmcrender.fcgi?accid=PMC6212323&blobtype=pdf"))
        #expect(!PaperService.isEuropePMCRenderedPDFURL("https://europepmc.org/article/MED/30224792"))
        #expect(!PaperService.isEuropePMCRenderedPDFURL("https://example.org/x?pdf=render"))
    }

    @Test("A PMC lookup tries NCBI's route before the PDF Europe PMC lists")
    func pmcLookupOrder() {
        let result = PaperService.PMCLookupResult(
            pdfURL: "https://europepmc.org/articles/pmc6212323?pdf=render",
            pmcid: "PMC6212323",
            doi: "10.1038/s41592-018-0111-2"
        )
        #expect(result.orderedPDFURLs == [
            "https://pmc.ncbi.nlm.nih.gov/articles/PMC6212323/pdf/",
            "https://europepmc.org/articles/pmc6212323?pdf=render",
        ])
    }

    @Test("OpenAlex locations: PDFs first, then PMC pages, then repository pages; publisher pages left out")
    func openAlexLocationOrder() {
        let work: [String: Any] = [
            "best_oa_location": [
                "is_oa": true,
                "landing_page_url": "https://doi.org/10.1016/j.cell.2025.09.012",
                "pdf_url": NSNull(),
                "source": ["type": "journal"],
            ],
            "locations": [
                ["is_oa": false, "landing_page_url": "https://paywalled.example/x", "pdf_url": "https://paywalled.example/x.pdf"],
                ["is_oa": true, "landing_page_url": "https://univ-angers.hal.science/hal-05172727v1",
                 "pdf_url": "https://univ-angers.hal.science/hal-05172727v1/document", "source": ["type": "repository"]],
                ["is_oa": true, "landing_page_url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC12614355/",
                 "pdf_url": NSNull(), "source": ["type": "repository"]],
                ["is_oa": true, "landing_page_url": "http://hdl.handle.net/10138/629013",
                 "pdf_url": NSNull(), "source": ["type": "repository"]],
                ["is_oa": true, "landing_page_url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC12614355/",
                 "pdf_url": NSNull(), "source": ["type": "repository"]],
            ],
        ]
        #expect(PaperService.openAlexOpenAccessURLs(from: work) == [
            "https://univ-angers.hal.science/hal-05172727v1/document",
            "https://pmc.ncbi.nlm.nih.gov/articles/PMC12614355/",
            "http://hdl.handle.net/10138/629013",
        ])
    }

    @Test("A refusal says what the host answered and keeps its old classification")
    func refusalMessages() {
        let embargo = PDFFetchRefusal.httpStatus(
            403,
            host: "pmc.ncbi.nlm.nih.gov",
            body: Data("<html><head><title>Supplemental document is embargoed</title></head></html>".utf8),
            contentType: "text/html",
            retryAfter: nil
        )
        #expect(embargo.classification == .accessDenied)
        #expect(embargo.message.contains("HTTP 403"))
        #expect(embargo.message.contains("Supplemental document is embargoed"))
        #expect(SourceError.classifying(embargo) == .accessDenied)

        let limited = PDFFetchRefusal.httpStatus(429, host: "example.org", body: Data(), contentType: nil, retryAfter: "120")
        #expect(limited.classification == .httpError(429))
        #expect(limited.message.contains("rate-limiting"))
        #expect(limited.message.contains("120"))

        let page = PDFFetchRefusal.page(host: "example.org", body: Data("<title>Sign in</title>".utf8), contentType: "text/html")
        #expect(page.classification == .fetchFailed)
        #expect(page.message.contains("Sign in"))

        #expect(SourceError.classifying(SourceError.pdfReadFailed) == .pdfReadFailed)
        #expect(SourceError.classifying(URLError(.timedOut)) == nil)
    }

    @Test("A refusal is still paywall evidence, in the host's own words, and still retried as the reader")
    func refusalFeedsPaywallAndReaderDecisions() {
        let refusal = PDFFetchRefusal.httpStatus(403, host: "www.science.org", body: Data(), contentType: nil, retryAfter: nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: refusal) == refusal.message)
        let notFound = PDFFetchRefusal.httpStatus(404, host: "www.science.org", body: Data(), contentType: nil, retryAfter: nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: notFound) == nil)
        #expect(WebSessionPDFDownload.publisherRefusedTheFile(refusal))
        #expect(!WebSessionPDFDownload.publisherRefusedTheFile(notFound))
    }

    @Test("PMC's proof-of-work page is parsed, and its cookie is the one its script would set")
    func pmcProofOfWorkParsing() {
        let html = """
        <html><head><title>Preparing to download ...</title><script>
        const POW_CHALLENGE = "abc123";
        const POW_DIFFICULTY = "4";
        const POW_COOKIE_NAME = "cloudpmc-viewer-pow";
        const POW_COOKIE_PATH = "/";
        const POW_COOKIE_EXPIRATION = "1";
        </script></head></html>
        """
        let challenge = SourceService.pmcProofOfWorkChallenge(in: html)
        #expect(challenge?.challenge == "abc123")
        #expect(challenge?.difficulty == 4)
        #expect(challenge?.cookieName == "cloudpmc-viewer-pow")
        #expect(SourceService.pmcProofOfWorkChallenge(in: "<html>a paper</html>") == nil)

        guard let challenge else { return }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cookie = SourceService.pmcProofOfWorkCookie(for: challenge, nonce: 42, host: "pmc.ncbi.nlm.nih.gov", now: now)
        #expect(cookie?.name == "cloudpmc-viewer-pow")
        #expect(cookie?.value == "abc123,42")
        #expect(cookie?.domain.contains("pmc.ncbi.nlm.nih.gov") == true)
        #expect(cookie?.expiresDate == now.addingTimeInterval(86_400))
    }
}
