// Substack, script-rendered page, semantic extraction, character reference and URL normalizer tests.

import Testing
import Foundation
import WebKit
@testable import ForeverLM

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

    @Test("Unquoted links and image sources are read, as minified pages write them")
    func readsUnquotedAttributes() throws {
        let base = try #require(URL(string: "https://example.com/writing/longevity/"))
        let html = #"<p><a href=/about>About</a> <img src=paul_et_al_2020_fig_2.webp alt=alt_text title="Figure 2"> <img data-src="lazy.png" src='fig3.png'></p>"#

        let sources = SourceService.attributeValues("src", ofTag: "img", in: html).map(\.value)
        #expect(sources == ["paul_et_al_2020_fig_2.webp", "fig3.png"])

        let rewritten = SourceService.absolutizingLinks(in: html, baseURL: base)
        #expect(rewritten.contains(#"href="https://example.com/about""#))

        let images = SourceService.rewritingAttribute("src", ofTag: "img", in: html) { src in
            SourceService.resolvedImageURL(src, baseURL: base)?.absoluteString
        }
        #expect(images.contains(#"src="https://example.com/writing/longevity/paul_et_al_2020_fig_2.webp" alt=alt_text"#))
        #expect(images.contains(#"data-src="lazy.png""#))
        #expect(images.contains("src='https://example.com/writing/longevity/fig3.png'"))
    }

    @Test("An archived image keeps the one picture it downloads, never a srcset that outranks it")
    func collapsesSourceSets() {
        let html = """
        <p><img alt="Hit rate" srcSet="/_next/image?url=%2Ffig1.png&amp;w=640&amp;q=75 640w, /_next/image?url=%2Ffig1.png&amp;w=1080&amp;q=75 1080w" src="/_next/image?url=%2Ffig1.png&amp;w=1080&amp;q=75" sizes="100vw">
        <img alt="" srcset="https://cdn.example.org/a.jpg 1x, https://cdn.example.org/a@2x.jpg 2x">
        <img src="data:image/gif;base64,R0lGOD" srcset="real-400.png 400w, real-800.png 800w">
        <img data-srcset="lazy.jpg 2x" src=plain.png></p>
        """

        let collapsed = SourceService.collapsingSourceSets(in: html)

        #expect(!collapsed.lowercased().contains(" srcset="))
        #expect(!collapsed.contains("sizes="))
        #expect(collapsed.contains(#"<img alt="Hit rate" src="/_next/image?url=%2Ffig1.png&amp;w=1080&amp;q=75">"#))
        #expect(collapsed.contains(#"<img src="https://cdn.example.org/a@2x.jpg" alt="">"#))
        #expect(collapsed.contains(#"<img src="real-800.png">"#))
        #expect(collapsed.contains(#"<img data-srcset="lazy.jpg 2x" src=plain.png>"#))
    }

    @Test("A srcset's candidates read as the HTML standard reads them, commas in URLs included")
    func readsSourceSetCandidates() {
        let substack = "https://cdn.example.org/image/fetch/w_424,c_limit,f_auto/pic.png 424w, https://cdn.example.org/image/fetch/w_848,c_limit,f_auto/pic.png 848w"
        let candidates = SourceService.sourceSetCandidates(substack)
        #expect(candidates.map(\.url) == [
            "https://cdn.example.org/image/fetch/w_424,c_limit,f_auto/pic.png",
            "https://cdn.example.org/image/fetch/w_848,c_limit,f_auto/pic.png",
        ])
        #expect(candidates.map(\.descriptor) == ["424w", "848w"])
        #expect(SourceService.widestSourceSetCandidate(substack) == "https://cdn.example.org/image/fetch/w_848,c_limit,f_auto/pic.png")
        #expect(SourceService.widestSourceSetCandidate("small.png, large.png 3x, mid.png 2x") == "large.png")
        #expect(SourceService.widestSourceSetCandidate("only.png") == "only.png")
        #expect(SourceService.widestSourceSetCandidate("  ") == nil)
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

/// Pages that were stored as articles before 2026-11-26, and are refused now.
@Suite("Pages that are not the article")
struct NotTheArticleTests {
    private let realArticle = "Constraints on evolutionary change\n" + String(repeating: "A lineage’s development may limit the sorts of phenotypes that it can evolve. ", count: 12)

    @Test("A cookie panel, a footer and Substack's reader bar are refused")
    func thinPagesAreRefused() {
        #expect(SourceService.notTheArticle(pageText: "CellType | The Biological World Model\n\nAnalytics preferences") == .insufficientContent)
        #expect(SourceService.notTheArticle(pageText: "# Zoe Hoare\nSubscribeSign in© 2026 Zoe Hoare · Privacy ∙ Terms ∙ Collection notice Start your SubstackGet the appSubstack is the home for great culture") == .insufficientContent)
        #expect(SourceService.notTheArticle(pageText: "Two weeks in the wetlab\n\nHomeSubscriptionsChatActivityExploreDashboardProfileCreateMoreWhat's on your mind?For you") == .insufficientContent)
    }

    @Test("A \"not found\" page is refused as a 404")
    func errorPagesAreRefused() {
        #expect(SourceService.notTheArticle(pageText: "Selling AI Products + Services to Big Pharma | Ending Unexpected Drug Toxicity.\n\n# 404\nNot Found") == .httpError(404))
        #expect(SourceService.notTheArticle(pageText: "OpenAI\n\nOpenAI\n# 404\nServer lights stay warm\nSomewhere, a small fan marks time\nThe room hums again\nby a model(opens in a new window)") == .httpError(404))
    }

    @Test("An article, even one that mentions 404 later, is kept")
    func articlesAreKept() {
        #expect(SourceService.notTheArticle(pageText: realArticle) == nil)
        #expect(SourceService.notTheArticle(pageText: realArticle + " The server answered 404.") == nil)
        #expect(SourceService.notTheArticle(pageText: "In 4040 BC " + realArticle) == nil)
    }

    @Test("Being offline is not a verdict on the page")
    func offlineIsTransient() {
        #expect(StudioViewModel.isTransientNetworkFailure("The Internet connection appears to be offline."))
        #expect(StudioViewModel.isTransientNetworkFailure("The request timed out."))
        #expect(!StudioViewModel.isTransientNetworkFailure("The page had no article text to read"))
    }

    @Test("The library repair names what a source holds, and leaves placeholders alone")
    func repairJudgesSavedText() {
        #expect(StudioViewModel.nonArticleReason(text: realArticle, title: "Constraints", url: "https://example.org/a") == nil)
        #expect(StudioViewModel.nonArticleReason(text: "Rotenone, Paraquat, and Parkinson’s Disease\n\nURL reference only. Full text intentionally not ingested.", title: "Rotenone", url: "https://doi.org/10.1289/ehp.1002839") == nil)
        let wall = "GLP-1 Drugs for Aging? | Science | AAAS\n\nwww.science.org\nPerforming security verification\nThis website uses a security service to protect against malicious bots."
        #expect(StudioViewModel.nonArticleReason(text: wall, title: "GLP-1 Drugs for Aging?", url: "https://www.science.org/content/blog-post/glp-1-drugs-aging") == "a publisher bot check")
        #expect(StudioViewModel.nonArticleReason(text: "x\n\n# 404\nNot Found", title: "x", url: "https://example.org/x") == "a \"not found\" page")
    }
}

/// An article whose page could not be saved is laid out from its stored text.
@Suite("Reading copy from stored text")
struct StoredTextReadingCopyTests {
    @Test("Each stored line is its own paragraph; list items stay one list")
    func linesBecomeParagraphs() {
        let text = "# Stories We'd Like to Publish\nIt's been a year.\nDuring that time, we released four issues.\n- one\n- two\n## A Brief History\nNSAIDs are common."
        let html = MarkdownHTML.body(SourceService.paragraphPerLine(text))
        #expect(html.contains("<h1>"))
        #expect(html.contains("<h2>"))
        #expect(html.components(separatedBy: "<p>").count - 1 == 3)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 1)
        #expect(html.components(separatedBy: "<li>").count - 1 == 2)
    }
}
