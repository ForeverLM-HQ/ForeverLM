// In-app web session, publisher PDF download decision, access wall and abstract URL tests.

import Testing
import Foundation
import WebKit
@testable import ForeverLM

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

    @Test("Titled body sections count, a bare heading marker opens no section, and a few-word section is not body")
    func titledSectionsCount() {
        let text = "## Abstract\nA short abstract.\n## Main\n" + Self.fullTextParagraph
            + "\n###\n" + Self.fullTextParagraph + "\n## Extended data\n### Extended Data Fig. 1 Legend.\nLegend text."
        #expect(PaperService.looksLikePaperFullText(text))
        let bodyOnly = Self.fullTextParagraph.split(whereSeparator: { $0.isWhitespace }).count * 2
        #expect(PaperService.paperBodyWordCount(text) == bodyOnly)
    }

    /// A publisher's landing page as the reader's text extraction gives it: the
    /// abstract, then the page around it — metrics, Share and Export panels,
    /// "How to cite", the footer, and the sign-in and password forms the site
    /// keeps hidden in the page. Shaped on the page a 2004 paper was stored as
    /// on 2026-11-08.
    private static let landingPageWithSiteInterface: String = {
        var lines = [
            "A study of metabolism and lifespan in outbred mice",
            "",
            "# A study of metabolism and lifespan in outbred mice",
            "### Summary",
            String(repeating: "Mice with higher metabolic intensity had greater proton conductance and lived longer than mice with low intensity. ", count: 13),
            "## Citing Literature", "Volume3, Issue3", "June 2004", "Pages 87-95",
            "## References", "## Related", "-", "## Information", "## Article Metrics",
            "### Citations (CrossRef):", "705",
            "When publishers deposit their content metadata, article citations are tracked and linked, allowing you to see how many times each article has been cited.",
        ]
        let panels = [
            "Share QR Code", "Export citation", "How to cite", "Download Citation",
            "About the Online Library", "Help & Support", "Opportunities", "Connect with Us",
            "Log in to the Online Library", "Change Password", "Password Changed Successfully",
            "Create a new account", "Forgot your password?", "Request Username",
        ]
        for panel in panels {
            lines.append("## \(panel)")
            lines.append("Something went wrong while loading this panel. Please try again in a moment, and if the issue persists, refresh the page or contact support.")
            lines.append(contentsOf: ["Email", "Password", "Too Short", "Weak", "Strong", "COPY TEXT", "Close"])
            lines.append("If the address matches an existing account you will receive an email with instructions to continue.")
        }
        return lines.joined(separator: "\n")
    }()

    @Test("A landing page's interface does not make its abstract the paper")
    func landingPageInterfaceIsNotFullText() {
        let text = Self.landingPageWithSiteInterface
        // Long enough on the interface's words, and still not the paper.
        let allWords = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        #expect(allWords > PaperService.minimumPaperFullTextWordCount)
        #expect(!PaperService.looksLikePublisherAccessWall(text: text))
        #expect(PaperService.paperBodyWordCount(text) < PaperService.minimumPaperFullTextWordCount)
        #expect(!PaperService.looksLikePaperFullText(text))
    }

    @Test("A paper's body still counts beside the page's interface")
    func bodyBesideInterfaceIsFullText() {
        let text = Self.landingPageWithSiteInterface + "\n## Introduction\n" + Self.fullTextParagraph
        #expect(PaperService.looksLikePaperFullText(text))
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
