// Paper title and metadata extraction, byline, author, registered title and source type tests.

import Testing
import Foundation
import WebKit
@testable import ForeverLM

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
        // A footnote's card reads the same heads.
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
