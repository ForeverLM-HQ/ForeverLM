import Foundation
import Testing
@testable import ForeverLM

private final class JournalFeedFixtureAnchor {}

/// The three feed dialects publishers serve, read into one shape; a page's
/// advertised feed found; and the small pure helpers around them.
@Suite("Journal feed parser")
struct JournalFeedParserTests {

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle(for: JournalFeedFixtureAnchor.self).url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    @Test("A Nature Portfolio RDF feed yields the journal, the articles, their DOIs, authors and dates")
    func natureRDF() throws {
        let feed = try JournalFeedParser.parse(try Self.fixture("journal-feed-nature-rdf", "xml"))
        #expect(feed.title == "Nature Reviews Molecular Cell Biology")
        #expect(feed.items.count == 2)

        let first = try #require(feed.items.first)
        #expect(first.url == "https://www.nature.com/articles/s41580-026-01025-4")
        #expect(first.title == "Towards 3D-oid models that integrate molecular, morphological and spatial cellular features")
        #expect(first.doi == "10.1038/s41580-026-01025-4")
        #expect(first.journal == "Nature Reviews Molecular Cell Biology")
        #expect(first.authors == ["Akos Diosdi", "Fabian J. Theis", "Peter Horvath"])
        let summary = try #require(first.summary)
        #expect(summary.contains("Combined analyses of cellular omics"))
        #expect(!summary.contains("<p>"), "HTML is stripped from the summary")
        let published = try #require(first.publishedAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day], from: published)
        #expect(components.year == 2026 && components.month == 9 && components.day == 4)
    }

    @Test("An RSS 2.0 feed: channel link, pubDate, description entities, guid permalink")
    func rss2() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>Cell Metabolism</title>
            <link>https://www.cell.com/cell-metabolism/home</link>
            <item>
              <title>Mitochondrial cristae &amp; the fate of a heart cell</title>
              <link>https://www.cell.com/cell-metabolism/fulltext/S1550-4131(26)00123-4</link>
              <description><![CDATA[<p>We show that <b>OPA1</b> shapes cristae &mdash; and survival.</p>]]></description>
              <dc:creator>A. Author</dc:creator>
              <pubDate>Wed, 02 Sep 2026 10:15:00 GMT</pubDate>
              <guid>https://www.cell.com/cell-metabolism/fulltext/S1550-4131(26)00123-4</guid>
            </item>
            <item>
              <title>No link, guid only</title>
              <guid isPermaLink="true">https://example.org/articles/2</guid>
              <description>Plain.</description>
            </item>
          </channel>
        </rss>
        """
        let feed = try JournalFeedParser.parse(Data(xml.utf8))
        #expect(feed.title == "Cell Metabolism")
        #expect(feed.siteURL == "https://www.cell.com/cell-metabolism/home")
        #expect(feed.items.count == 2)
        let first = try #require(feed.items.first)
        #expect(first.title == "Mitochondrial cristae & the fate of a heart cell")
        #expect(first.summary == "We show that OPA1 shapes cristae — and survival.")
        #expect(first.authors == ["A. Author"])
        #expect(first.doi == nil)
        let published = try #require(first.publishedAt)
        #expect(abs(published.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-09-02T10:15:00Z")!)) < 1)
        #expect(feed.items[1].url == "https://example.org/articles/2")
    }

    @Test("An Atom feed: alternate links, author names, published, DOI read off a doi.org link")
    func atom() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>eLife</title>
          <link rel="self" href="https://elifesciences.org/rss/recent.xml"/>
          <link rel="alternate" type="text/html" href="https://elifesciences.org/"/>
          <entry>
            <title>Ageing muscle mitochondria</title>
            <link rel="alternate" href="https://doi.org/10.7554/eLife.99999"/>
            <id>tag:elifesciences.org,2026:99999</id>
            <published>2026-09-01T00:00:00Z</published>
            <updated>2026-09-03T12:00:00Z</updated>
            <author><name>B. Writer</name></author>
            <author><name>C. Writer</name></author>
            <summary type="html">&lt;p&gt;A summary.&lt;/p&gt;</summary>
          </entry>
        </feed>
        """
        let feed = try JournalFeedParser.parse(Data(xml.utf8))
        #expect(feed.title == "eLife")
        #expect(feed.siteURL == "https://elifesciences.org/")
        let entry = try #require(feed.items.first)
        #expect(entry.url == "https://doi.org/10.7554/eLife.99999")
        #expect(entry.title == "Ageing muscle mitochondria")
        #expect(entry.authors == ["B. Writer", "C. Writer"])
        #expect(entry.summary == "A summary.")
        #expect(entry.doi == "10.7554/eLife.99999")
        #expect(entry.publishedAt == ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"), "published wins over updated")
    }

    @Test("An HTML page is not a feed")
    func html() {
        let html = Data("<!doctype html><html><head><title>Nature</title></head><body></body></html>".utf8)
        #expect(throws: JournalFeedParser.ParseError.notAFeed) {
            _ = try JournalFeedParser.parse(html)
        }
    }

    @Test("A journal page's advertised feeds are found and resolved, stylesheets ignored")
    func discovery() throws {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/static/app.css">
        <link rel="alternate" type="application/rss+xml" href="https://www.nature.com/nrm.rss"/>
        <link href='/atom.xml' type='application/atom+xml' rel='alternate' title='Atom'>
        <link rel="alternate" type="application/json" href="/feed.json">
        <link rel="alternate" type="application/rss+xml" href="https://www.nature.com/nrm.rss"/>
        </head><body></body></html>
        """
        let found = JournalFeedParser.discoverFeedURLs(inHTML: html, relativeTo: URL(string: "https://www.nature.com/nrm")!)
        #expect(found.map(\.absoluteString) == ["https://www.nature.com/nrm.rss", "https://www.nature.com/atom.xml"])
    }

    @Test("Plain text: tags gone, entities decoded, whitespace collapsed")
    func plainText() {
        #expect(JournalFeedParser.plainText(fromHTML: "<p>A &amp; B&nbsp;&#8212;&#x2014; C</p>\n\n<br/>D") == "A & B —— C D")
    }

    @Test("An item title keeps its formula: scripts fold to Unicode rather than falling apart at the tags")
    func itemTitleMarkup() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>FEBS Letters</title>
            <item>
              <title><![CDATA[Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production in <i>pigeon</i> heart mitochondria]]></title>
              <link>https://febs.onlinelibrary.wiley.com/doi/10.1016/0014-5793(71)80459-3</link>
            </item>
          </channel>
        </rss>
        """
        let feed = try JournalFeedParser.parse(Data(xml.utf8))
        #expect(feed.items.first?.title == "Respiratory chain linked H₂O₂ production in pigeon heart mitochondria")
    }

    @Test("Dates in the forms feeds use")
    func dates() {
        let iso = ISO8601DateFormatter()
        #expect(JournalFeedParser.parseDate("2026-09-04") == iso.date(from: "2026-09-04T00:00:00Z"))
        #expect(JournalFeedParser.parseDate("2026-09-04T08:30:00Z") == iso.date(from: "2026-09-04T08:30:00Z"))
        #expect(JournalFeedParser.parseDate("2026-09-04T08:30:00.250Z") != nil)
        #expect(JournalFeedParser.parseDate("Fri, 04 Sep 2026 08:30:00 +0000") == iso.date(from: "2026-09-04T08:30:00Z"))
        #expect(JournalFeedParser.parseDate("Fri, 04 Sep 2026 08:30 GMT") == iso.date(from: "2026-09-04T08:30:00Z"))
        #expect(JournalFeedParser.parseDate("yesterday") == nil)
    }

    @Test("DOI spellings normalise to the bare DOI, and non-DOIs to nothing")
    func dois() {
        #expect(JournalFeedParser.normalizedDOI("doi:10.1038/s41580-026-01025-4") == "10.1038/s41580-026-01025-4")
        #expect(JournalFeedParser.normalizedDOI(" https://doi.org/10.1038/x ") == "10.1038/x")
        #expect(JournalFeedParser.normalizedDOI("10.1038/x") == "10.1038/x")
        #expect(JournalFeedParser.normalizedDOI("s41580-026-01025-4") == nil)
        #expect(JournalFeedParser.normalizedDOI("") == nil)
        #expect(JournalFeedParser.normalizedDOI(nil) == nil)
    }

    @Test("A Substack feed: CDATA title and subtitle, dc:creator, pubDate, no DOI, body not taken as the summary")
    func substack() throws {
        let feed = try JournalFeedParser.parse(try Self.fixture("journal-feed-substack-rss", "xml"))
        #expect(feed.title == "Astral Codex Ten")
        #expect(feed.siteURL == "https://www.astralcodexten.com")
        #expect(feed.items.count == 2)
        let post = try #require(feed.items.first)
        #expect(post.url == "https://www.astralcodexten.com/p/god-help-us-lets-try-to-learn-about")
        #expect(post.title == "God Help Us, Let’s Try To Learn About Mechanistic Interpretability Techniques")
        #expect(post.summary == "A long, confused, and confusing attempt to get up to speed.", "the subtitle is the summary; the full post body is not")
        #expect(post.authors == ["Scott Alexander"])
        #expect(post.doi == nil)
        #expect(post.journal == nil, "a blog names no journal; the runner supplies the feed title instead")
        #expect(post.publishedAt == ISO8601DateFormatter().date(from: "2026-09-08T12:04:21Z"))
        let second = feed.items[1]
        #expect(second.summary == "An open thread body is the summary when the post has no subtitle.")
        #expect(second.url == "https://www.astralcodexten.com/p/open-thread-400", "a utm_ tail is dropped from the identity")
    }

    @Test("Tracking parameters come off article URLs; real query parameters stay")
    func cleanArticleURLs() {
        #expect(JournalFeedParser.cleanArticleURL("https://netflixtechblog.com/maps-32f96320785e?source=rss----2615bd06b42e---4") == "https://netflixtechblog.com/maps-32f96320785e")
        #expect(JournalFeedParser.cleanArticleURL("https://www.example.com/p/post?utm_source=substack&utm_medium=email&ref=home") == "https://www.example.com/p/post")
        #expect(JournalFeedParser.cleanArticleURL("https://arxiv.org/abs/2609.05453") == "https://arxiv.org/abs/2609.05453")
        #expect(JournalFeedParser.cleanArticleURL("https://www.youtube.com/watch?v=abc123&utm_campaign=x") == "https://www.youtube.com/watch?v=abc123")
        #expect(JournalFeedParser.cleanArticleURL(" https://example.com/a?id=7 ") == "https://example.com/a?id=7")
    }

    @Test("A page that advertises no feed is probed at the conventional paths, its own section first")
    func wellKnownFeedURLs() {
        let section = JournalFeedParser.wellKnownFeedURLs(for: URL(string: "https://blog.google/technology/ai/?hl=en#top")!).map(\.absoluteString)
        #expect(section.first == "https://blog.google/technology/ai/feed", "query and fragment are dropped, the section is tried first")
        #expect(section.contains("https://blog.google/technology/ai/rss/"))
        #expect(section.contains("https://blog.google/technology/ai.rss"), "Reddit's spelling: the path with .rss appended")
        #expect(section.contains("https://blog.google/feed"), "then the site root")
        #expect(section.contains("https://blog.google/index.xml"))
        #expect(section.count == Set(section).count, "no probe twice")
        #expect(section.firstIndex(of: "https://blog.google/technology/ai/rss/")! < section.firstIndex(of: "https://blog.google/feed")!)

        let root = JournalFeedParser.wellKnownFeedURLs(for: URL(string: "https://example.substack.com")!).map(\.absoluteString)
        #expect(root.first == "https://example.substack.com/feed")
        #expect(!root.contains("https://example.substack.com/.rss"), "the root gets no .rss variant")
        #expect(root.count == 8, "a root page is probed once per conventional path, not twice")
    }

    @Test("A pasted block splits into distinct addresses")
    func pastedAddresses() {
        let text = """
        https://www.nature.com/nature
        https://www.nature.com/nrm, https://www.nature.com/ncomms

        https://www.nature.com/NATURE
        """
        #expect(JournalWatch.candidateURLStrings(in: text) == [
            "https://www.nature.com/nature",
            "https://www.nature.com/nrm",
            "https://www.nature.com/ncomms",
        ])
        #expect(JournalWatch.candidateURLStrings(in: "  \n ") == [])
    }

    @Test("A feed is due when never checked or after the interval; the next instant is the earliest")
    func schedule() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let fresh = JournalFeed(feedURL: "https://a.example/rss", title: "A", lastCheckedAt: now.addingTimeInterval(-60))
        let stale = JournalFeed(feedURL: "https://b.example/rss", title: "B", lastCheckedAt: now.addingTimeInterval(-JournalWatch.checkInterval - 1))
        let never = JournalFeed(feedURL: "https://c.example/rss", title: "C")
        #expect(!JournalWatch.isDue(fresh, now: now))
        #expect(JournalWatch.isDue(stale, now: now))
        #expect(JournalWatch.isDue(never, now: now))
        #expect(JournalWatch.nextCheckInstant(feeds: [], now: now) == nil)
        #expect(JournalWatch.nextCheckInstant(feeds: [fresh], now: now) == now.addingTimeInterval(JournalWatch.checkInterval - 60))
        #expect(JournalWatch.nextCheckInstant(feeds: [fresh, stale], now: now) == now, "an overdue feed is due now, never in the past")
        #expect(JournalWatch.nextCheckInstant(feeds: [fresh, never], now: now) == now)
    }
}
