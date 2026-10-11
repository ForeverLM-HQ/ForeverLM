import Foundation
import Testing
@testable import ForeverLM

/// `LocalSite`: the rules a site kept in the library is stored by.
@Suite("Local site")
struct LocalSiteTests {
    @Test("Paths and the entry page's text are normalised the way a site is stored")
    func normalisation() throws {
        #expect(LocalSite.normalizePath("./css/site.css") == "css/site.css")
        #expect(LocalSite.normalizePath("/index.html") == "index.html")
        #expect(LocalSite.normalizePath("img\\logo.png") == "img/logo.png")
        #expect(LocalSite.normalizePath("../secret") == nil)
        #expect(LocalSite.normalizePath(".env") == nil)
        #expect(LocalSite.normalizePath("a b.html") == nil)
        #expect(LocalSite.normalizePath("") == nil)
        let text = LocalSite.visibleText(ofHTML: """
        <!doctype html><html><head><title>T</title><style>p{}</style><script>a()</script></head>
        <body><nav><a href="/">Home</a></nav><h1>Mito &amp; Landscape</h1><p>Forty&nbsp;one<br>companies&#8217;s list.</p>
        <ul><li>One</li><li>Two</li></ul><!-- hidden --><script>b()</script></body></html>
        """)
        #expect(text.contains("Mito & Landscape"))
        #expect(text.contains("Forty one\ncompanies’s list."))
        let one = try #require(text.range(of: "One"))
        let two = try #require(text.range(of: "Two"))
        #expect(one.upperBound <= two.lowerBound, "list items keep their order, each on its own line")
        let between = String(text[one.upperBound..<two.lowerBound])
        #expect(!between.isEmpty && between.allSatisfy(\.isNewline))
        #expect(!text.contains("a()"))
        #expect(!text.contains("p{}"))
        #expect(!text.contains("hidden"))
        #expect(!text.contains("<"))
    }
}


/// `SiteTextEdit`: the app's Change action and `replace_site_text` find a
/// selected passage in a page's source and change exactly it.
@Suite("Site text edit")
struct SiteTextEditTests {
    @Test("a single line changes only its own words inside one run")
    func singleRunSubstring() throws {
        let html = "<p>Forty compounds, none with a developer.</p>"
        let change = try SiteTextEdit.apply(find: "none with a developer", replace: "one with a developer", toHTML: html)
        #expect(change.html == "<p>Forty compounds, one with a developer.</p>")
        #expect(change.found == "none with a developer")
        #expect(change.replacement == "one with a developer")
    }

    @Test("a selection across inline markup matches the visible line, not the runs")
    func inlineMarkupJoins() throws {
        let html = "<p>Real <em>pharmacology</em>, no one carrying it.</p>"
        let change = try SiteTextEdit.apply(find: "no one carrying it", replace: "nobody carrying it", toHTML: html)
        #expect(change.html == "<p>Real <em>pharmacology</em>, nobody carrying it.</p>")
    }

    @Test("the kicker and the heading under it change line by line")
    func kickerAndHeading() throws {
        let html = """
        <section>
          <p class="kicker">COMPOUNDS WITHOUT A DEVELOPER</p>
          <h2>Real pharmacology,
              no one carrying it</h2>
          <p>Body.</p>
        </section>
        """
        let change = try SiteTextEdit.apply(
            find: "COMPOUNDS WITHOUT A DEVELOPER\nReal pharmacology, no one carrying it",
            replace: "COMPOUNDS WITHOUT AN OWNER\nReal pharmacology, nobody carrying it",
            toHTML: html
        )
        #expect(change.html.contains("<p class=\"kicker\">COMPOUNDS WITHOUT AN OWNER</p>"))
        #expect(change.html.contains("<h2>Real pharmacology, nobody carrying it</h2>"))
        #expect(change.html.contains("<p>Body.</p>"))
    }

    @Test("a multi-line selection matches a tail, whole lines, and a head")
    func partialFirstAndLastLines() throws {
        let html = "<p>Start of one</p><p>two</p><p>three end</p>"
        let change = try SiteTextEdit.apply(find: "of one\ntwo\nthree", replace: "A\nB\nC", toHTML: html)
        #expect(change.html == "<p>Start A</p><p>B</p><p>C end</p>")
    }

    @Test("fewer replacement lines than selected: the first element takes the text, the rest are emptied with their tags kept")
    func collapsingLines() throws {
        let html = "<p>One</p><h2>Two</h2>"
        let change = try SiteTextEdit.apply(find: "One\nTwo", replace: "Only", toHTML: html)
        #expect(change.html == "<p>Only</p><h2></h2>")
        #expect(change.replacement == "Only")
    }

    @Test("a phrase that appears twice is refused with the count")
    func ambiguousRefused() {
        let html = "<p>the atlas</p><p>the atlas</p>"
        #expect(throws: SiteTextEdit.Failure.ambiguous(2)) {
            try SiteTextEdit.apply(find: "the atlas", replace: "an atlas", toHTML: html)
        }
    }

    @Test("a passage that is not in the source is refused, and so is an empty selection")
    func notFoundRefused() {
        let html = "<p>Nothing here</p>"
        #expect(throws: SiteTextEdit.Failure.notFound) {
            try SiteTextEdit.apply(find: "Something else", replace: "x", toHTML: html)
        }
        #expect(throws: SiteTextEdit.Failure.emptySelection) {
            try SiteTextEdit.apply(find: "  \n ", replace: "x", toHTML: html)
        }
    }

    @Test("text inside script, style, comments and attributes never matches")
    func rawTextNeverMatches() {
        let html = "<script>var atlas = 'the atlas';</script><style>.atlas{}</style><!-- the atlas --><a title=\"the atlas\" href=\"#\">Open</a>"
        #expect(throws: SiteTextEdit.Failure.notFound) {
            try SiteTextEdit.apply(find: "the atlas", replace: "x", toHTML: html)
        }
    }

    @Test("entity-encoded source matches the decoded selection and the replacement is re-encoded")
    func entities() throws {
        let html = "<p>Forty &amp; one &#8217;compounds&#8217; &lt;here&gt;</p>"
        let change = try SiteTextEdit.apply(find: "Forty & one ’compounds’ <here>", replace: "Forty & two <there>", toHTML: html)
        #expect(change.html == "<p>Forty &amp; two &lt;there&gt;</p>")
        #expect(change.found == "Forty & one ’compounds’ <here>")
    }

    @Test("indentation and line breaks inside a paragraph collapse to the rendered spacing")
    func whitespaceCollapses() throws {
        let html = "<p>\n    Real\n    pharmacology\n</p>"
        let change = try SiteTextEdit.apply(find: "Real pharmacology", replace: "Applied pharmacology", toHTML: html)
        #expect(change.html == "<p>\n    Applied pharmacology\n</p>")
    }
}
