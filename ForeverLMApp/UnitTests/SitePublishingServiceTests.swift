import Foundation
import Testing
@testable import ForeverLM

@Suite("Site publishing")
struct SitePublishingServiceTests {
    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func transport(status: Int, body: String, contentType: String = "application/json", recorder: Recorder) -> SitePublishing.Transport {
        { request in
            recorder.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
            return (Data(body.utf8), response)
        }
    }

    @Test("Publishing sends the files as a bearer-authenticated PUT, text as content and bytes as base64, and reads the site back")
    func publishRequestAndResponse() async throws {
        let recorder = Recorder()
        let status = try await SitePublishing.publish(
            siteID: "site-1",
            title: "Mito Landscape",
            files: [
                SiteFile(path: "index.html", data: Data("<h1>Hi</h1>".utf8)),
                SiteFile(path: "img/dot.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])),
            ],
            slug: "mito-landscape",
            source: SitePublishingSource(repository: "acme/site", ref: "main", path: "public", commit: "abc123"),
            access: SitePublishingAccess(teamID: "team-1", readers: ["member@example.com"]),
            sessionToken: "v1.abc.9.sig",
            transport: transport(status: 200, body: """
            {"published":true,"site_id":"site-1","url":"https://sites.foreverlm.com/mito-landscape/","slug":"mito-landscape","custom_slug":true,"title":"Mito Landscape","published_at":"2026-09-09T20:00:00.000Z","updated_at":"2026-09-09T20:05:00.000Z","bytes":21,"files":2,"file_paths":["index.html","img/dot.png"],"source":{"repository":"acme/site","ref":"main","path":"public","commit":"abc123"},"created":true,"moved":false}
            """, recorder: recorder)
        )
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://foreverlm.com/api/publish/sites/site-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer v1.abc.9.sig")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["title"] as? String == "Mito Landscape")
        #expect(body["slug"] as? String == "mito-landscape")
        let files = try #require(body["files"] as? [[String: Any]])
        #expect(files.count == 2)
        #expect(files[0]["path"] as? String == "index.html")
        #expect(files[0]["content"] as? String == "<h1>Hi</h1>")
        #expect(files[0]["content_base64"] == nil)
        #expect(files[1]["content"] == nil)
        #expect(files[1]["content_base64"] as? String == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]).base64EncodedString())
        #expect((body["source"] as? [String: Any])?["commit"] as? String == "abc123")
        #expect((body["access"] as? [String: Any])?["team_id"] as? String == "team-1")
        #expect((body["access"] as? [String: Any])?["readers"] as? [String] == ["member@example.com"])
        #expect((body["access"] as? [String: Any])?["visibility"] as? String == "private")

        #expect(status.siteID == "site-1")
        #expect(status.url.absoluteString == "https://sites.foreverlm.com/mito-landscape/")
        #expect(status.slug == "mito-landscape")
        #expect(status.isCustomSlug)
        #expect(status.filePaths == ["index.html", "img/dot.png"])
        #expect(status.bytes == 21)
        #expect(status.source == SitePublishingSource(repository: "acme/site", ref: "main", path: "public", commit: "abc123"))
        #expect(status.updatedAt > status.publishedAt)
    }


    @Test("A file marked upload is declared in the publish and then sent by its own raw PUT, and a refused upload throws after the publish stood")
    func uploadsFollowThePublish() async throws {
        let recorder = Recorder()
        // A NUL among the bytes: binary, as a real PDF is.
        let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x00]) + Data(repeating: 0x25, count: 4091)
        let files = [
            SiteFile(path: "index.html", data: Data("<h1>Hi</h1>".utf8)),
            SiteFile(path: "foreverlm/sources/paper one.pdf", data: pdf, upload: true),
        ]
        let status = try await SitePublishing.publish(
            siteID: "site-1", title: "Report", files: files, sessionToken: "v1.abc.9.sig",
            transport: { request in
                recorder.requests.append(request)
                let body = request.url!.path.contains("/files/")
                    ? #"{"path":"foreverlm/sources/paper one.pdf","bytes":4096,"content_type":"application/pdf","stored":true}"#
                    : #"{"published":true,"site_id":"site-1","url":"https://sites.foreverlm.com/abcdefghjkmn/","slug":"abcdefghjkmn","title":"Report","published_at":"2026-09-10T10:00:00.000Z","updated_at":"2026-09-10T10:00:00.000Z","bytes":4107,"files":2,"file_paths":["index.html","foreverlm/sources/paper one.pdf"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
        )
        #expect(status.filePaths == ["index.html", "foreverlm/sources/paper one.pdf"])
        #expect(recorder.requests.count == 2)
        let publish = try #require(recorder.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: publish.httpBody ?? Data()) as? [String: Any])
        let declared = try #require((body["files"] as? [[String: Any]])?.last)
        #expect(declared["upload"] as? Bool == true)
        #expect(declared["bytes"] as? Int == 4096)
        #expect(declared["content"] == nil && declared["content_base64"] == nil, "the bytes never travel inside the JSON")
        #expect(publish.timeoutInterval == 180)
        let upload = try #require(recorder.requests.last)
        #expect(upload.httpMethod == "PUT")
        #expect(upload.url?.absoluteString == "https://foreverlm.com/api/publish/sites/site-1/files/foreverlm/sources/paper%20one.pdf")
        #expect(upload.httpBody == pdf)
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer v1.abc.9.sig")
        #expect(upload.timeoutInterval == 600)

        // A small file is never an upload, whatever its type.
        #expect(SiteFile(path: "a.pdf", data: pdf).payload["content_base64"] as? String == pdf.base64EncodedString())

        // The service refusing the bytes surfaces as the publish error it is.
        let refusing = Recorder()
        await #expect(throws: DocPublishingError.self) {
            try await SitePublishing.publish(siteID: "site-1", title: "Report", files: files, sessionToken: "v1.abc.9.sig", transport: { request in
                refusing.requests.append(request)
                let files = request.url!.path.contains("/files/")
                let body = files ? #"{"error":"invalid_request","error_description":"declared as 4096 bytes"}"# : #"{"published":true,"site_id":"site-1","url":"https://sites.foreverlm.com/abcdefghjkmn/","slug":"abcdefghjkmn","title":"Report","published_at":"2026-09-10T10:00:00.000Z","updated_at":"2026-09-10T10:00:00.000Z","bytes":4107,"files":2,"file_paths":["index.html","foreverlm/sources/paper one.pdf"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: files ? 400 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            })
        }
        #expect(refusing.requests.count == 2, "the publish stood; the upload was the refusal")
    }

    @Test("A signed-out Mac never sends, and the service's refusals come back in its own words")
    func refusals() async throws {
        let recorder = Recorder()
        await #expect(throws: DocPublishingError.signedOut) {
            try await SitePublishing.publish(siteID: "s", title: "T", files: [SiteFile(path: "index.html", data: Data())], sessionToken: nil, transport: transport(status: 200, body: "{}", recorder: recorder))
        }
        #expect(recorder.requests.isEmpty)
        do {
            _ = try await SitePublishing.publish(siteID: "s", title: "T", files: [SiteFile(path: "index.html", data: Data())], slug: "taken", sessionToken: "t",
                                                 transport: transport(status: 409, body: #"{"error":"slug_taken","error_description":"The address sites.foreverlm.com/taken/ is already in use. Choose another."}"#, recorder: recorder))
            Issue.record("a 409 was not thrown")
        } catch let error as DocPublishingError {
            #expect(error == .server(status: 409, code: "slug_taken", message: "The address sites.foreverlm.com/taken/ is already in use. Choose another."))
        }
        await #expect(throws: DocPublishingError.signedOut) {
            try await SitePublishing.unpublish(site: "s", sessionToken: "expired", transport: transport(status: 401, body: #"{"error":"invalid_session"}"#, recorder: recorder))
        }
    }

    @Test("Statuses, one status, a file read and a takedown use the routes the site serves")
    func otherRoutes() async throws {
        let recorder = Recorder()
        let statuses = try await SitePublishing.statuses(sessionToken: "t", transport: transport(status: 200, body: """
        {"published_sites":[{"site_id":"a","url":"https://sites.foreverlm.com/aaaaaaaaaaaa/","slug":"aaaaaaaaaaaa","custom_slug":false,"title":"A","published_at":"2026-09-09T20:00:00Z","updated_at":"2026-09-09T20:00:00Z","bytes":1,"files":1,"file_paths":["index.html"],"source":{"repository":"acme/site","ref":"main","path":"public","commit":"abc123"},"visibility":"public"}]}
        """, recorder: recorder))
        #expect(statuses["a"]?.slug == "aaaaaaaaaaaa")
        #expect(statuses["a"]?.source == SitePublishingSource(repository: "acme/site", ref: "main", path: "public", commit: "abc123"))
        #expect(statuses["a"]?.access?.visibility == .publicSite)
        #expect(recorder.requests.last?.url?.path == "/api/publish/sites")
        let none = try await SitePublishing.status(site: "gone", sessionToken: "t", transport: transport(status: 200, body: #"{"published":false}"#, recorder: recorder))
        #expect(none == nil)
        #expect(recorder.requests.last?.url?.path == "/api/publish/sites/gone")
        let file = try await SitePublishing.readFile(site: "a", path: "css/site.css", sessionToken: "t", transport: transport(status: 200, body: "h1{}", contentType: "text/css; charset=utf-8", recorder: recorder))
        #expect(String(data: file.data, encoding: .utf8) == "h1{}")
        #expect(file.contentType == "text/css; charset=utf-8")
        #expect(recorder.requests.last?.url?.path == "/api/publish/sites/a/files/css/site.css")
        _ = try await SitePublishing.updateAccess(
            site: "a",
            access: SitePublishingAccess(teamID: "team-1", readers: ["member@example.com"]),
            sessionToken: "t",
            transport: transport(status: 200, body: """
            {"published":true,"site_id":"a","url":"https://sites.foreverlm.com/aaaaaaaaaaaa/","slug":"aaaaaaaaaaaa","custom_slug":false,"title":"A","published_at":"2026-09-09T20:00:00Z","updated_at":"2026-09-09T20:01:00Z","bytes":1,"files":1,"file_paths":["index.html"],"team_id":"team-1","readers":["member@example.com"]}
            """, recorder: recorder)
        )
        #expect(recorder.requests.last?.httpMethod == "PATCH")
        let accessBody = try #require(try JSONSerialization.jsonObject(with: recorder.requests.last?.httpBody ?? Data()) as? [String: Any])
        #expect((accessBody["access"] as? [String: Any])?["team_id"] as? String == "team-1")
        #expect((accessBody["access"] as? [String: Any])?["visibility"] as? String == "private")
        let wasPublished = try await SitePublishing.unpublish(site: "a", sessionToken: "t", transport: transport(status: 200, body: #"{"published":false,"was_published":true}"#, recorder: recorder))
        #expect(wasPublished)
        #expect(recorder.requests.last?.httpMethod == "DELETE")
    }

    @Test("Slugs, paths and the entry page's text are normalised the way the site expects")
    func normalisation() throws {
        #expect(SitePublishing.normalizeCustomSlug(" Mito-Landscape ") == "mito-landscape")
        #expect(SitePublishing.normalizeCustomSlug("https://sites.foreverlm.com/mito-landscape/about.html") == "mito-landscape")
        #expect(SitePublishing.normalizeCustomSlug("api") == nil)
        #expect(SitePublishing.normalizeCustomSlug("sites") == nil)
        #expect(SitePublishing.normalizeCustomSlug("-bad") == nil)
        #expect(SitePublishing.normalizePath("./css/site.css") == "css/site.css")
        #expect(SitePublishing.normalizePath("/index.html") == "index.html")
        #expect(SitePublishing.normalizePath("img\\logo.png") == "img/logo.png")
        #expect(SitePublishing.normalizePath("../secret") == nil)
        #expect(SitePublishing.normalizePath(".env") == nil)
        #expect(SitePublishing.normalizePath("a b.html") == nil)
        #expect(SitePublishing.normalizePath("") == nil)
        let text = SitePublishing.visibleText(ofHTML: """
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

    @Test("Only a ForeverLM Site receives the managed session on its first request")
    func siteViewerAuthentication() throws {
        let site = try #require(URL(string: "https://sites.foreverlm.com/team-site/"))
        let request = LinkedDocWebView.initialRequest(url: site, kind: .foreverlmSite, sessionToken: "managed-session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer managed-session")

        let google = try #require(URL(string: "https://docs.google.com/document/d/abc/edit"))
        #expect(LinkedDocWebView.initialRequest(url: google, kind: .googleDoc, sessionToken: "managed-session")
            .value(forHTTPHeaderField: "Authorization") == nil)
        let impostor = try #require(URL(string: "https://example.com/team-site/"))
        #expect(LinkedDocWebView.initialRequest(url: impostor, kind: .foreverlmSite, sessionToken: "managed-session")
            .value(forHTTPHeaderField: "Authorization") == nil)
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

    @Test("the stored path for a page address follows the host's index and .html answers")
    func storedPathForPage() {
        let files = ["index.html", "about.html", "docs/index.html", "css/site.css"]
        let slug = "atlas"
        func path(_ address: String) -> String? {
            SitePublishing.storedPath(forPage: URL(string: address), slug: slug, filePaths: files)
        }
        #expect(path("https://sites.foreverlm.com/atlas/") == "index.html")
        #expect(path("https://sites.foreverlm.com/atlas/about.html") == "about.html")
        #expect(path("https://sites.foreverlm.com/atlas/about") == "about.html")
        #expect(path("https://sites.foreverlm.com/atlas/docs") == "docs/index.html")
        #expect(path("https://sites.foreverlm.com/atlas/missing") == nil)
        #expect(path("https://sites.foreverlm.com/other/") == nil)
        #expect(path("https://example.com/atlas/") == nil)
    }
}
