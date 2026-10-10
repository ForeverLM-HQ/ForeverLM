import Foundation
import Testing
@testable import ForeverLM

@Suite("Published page renderer")
struct PublishedPageRendererTests {
    private static let fixtureMarkdown = """
    # TechBio: modalities

    A deck paragraph with **bold**, `code` and a [link](https://example.com/paper).

    ## Companies

    ### Acme Bio
    - **Modality:** small molecule
    - **Stage:** Series A

    """

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    @Test("The preview input applies the route's rules: title collapsed or Untitled, the page's own address only for a slug the site serves")
    func previewInputRules() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let published = Date(timeIntervalSince1970: 1_787_000_000)
        let input = DocPublishing.previewInput(
            title: "  Research:\n  Foo   Bar ",
            markdown: "Body",
            pageURL: URL(string: "https://foreverlm.com/share/techbio"),
            publishedAt: published,
            now: now
        )
        #expect(input.title == "Research: Foo Bar")
        #expect(input.markdown == "Body")
        #expect(input.canonicalURL == "https://foreverlm.com/share/techbio")
        #expect(input.publishedAt == ISO8601DateFormatter().string(from: published))
        #expect(input.updatedAt == ISO8601DateFormatter().string(from: now))
        #expect(input.sourceMarks)

        let draft = DocPublishing.previewInput(title: " \n ", markdown: "", pageURL: nil, publishedAt: nil, now: now)
        #expect(draft.title == "Untitled")
        #expect(draft.canonicalURL == DocPublishing.previewCanonicalURL)
        #expect(draft.publishedAt == draft.updatedAt)

        #expect(DocPublishing.previewCanonicalURL(for: URL(string: "https://example.com/share/techbio")) == DocPublishing.previewCanonicalURL)
        #expect(DocPublishing.previewCanonicalURL(for: URL(string: "https://foreverlm.com/share/ab")) == DocPublishing.previewCanonicalURL)
        #expect(DocPublishing.previewCanonicalURL(for: URL(string: "https://foreverlm.com/share/two--hyphens")) == DocPublishing.previewCanonicalURL)
        #expect(DocPublishing.previewCanonicalURL(for: URL(string: "https://foreverlm.com/share/techbio?x=1")) == DocPublishing.previewCanonicalURL)
        #expect(DocPublishing.previewCanonicalURL(for: URL(string: "https://foreverlm.com/share/mito-landscape-2026")) == "https://foreverlm.com/share/mito-landscape-2026")
    }

    @Test("The bundled renderer draws the page as the site does: the title, the marks for Edit mode, the canonical address, the dates and the page's own script")
    func bundledRendererDrawsThePage() async throws {
        let renderer = PublishedPageRenderer()
        let input = DocPublishing.previewInput(
            title: "Research: Foo",
            markdown: Self.fixtureMarkdown,
            pageURL: URL(string: "https://foreverlm.com/share/techbio"),
            publishedAt: ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z"),
            now: ISO8601DateFormatter().date(from: "2026-09-08T20:00:00Z")!
        )
        let html = try await renderer.render(input)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<title>Research: Foo</title>"))
        // The report's own H1 leads; the Doc's title stands above it as the kicker.
        #expect(html.contains("<p class=\"kicker\">Research: Foo</p>"))
        #expect(html.contains("TechBio: modalities"))
        #expect(html.contains("data-src=\""))
        #expect(html.contains("<link rel=\"canonical\" href=\"https://foreverlm.com/share/techbio\">"))
        #expect(html.contains("Published September 1, 2026 · Updated September 8, 2026"))
        #expect(html.contains("window.ForeverLMPage"))
        #expect(html.contains("<strong>Modality:</strong>"))
    }

    @Test("A second page reuses the evaluated bundle and draws in milliseconds")
    func renderingIsFastOnceLoaded() async throws {
        let renderer = PublishedPageRenderer()
        let input = DocPublishing.previewInput(title: "Warm", markdown: Self.fixtureMarkdown, pageURL: nil, publishedAt: nil)
        _ = try await renderer.render(input)
        let long = String(repeating: Self.fixtureMarkdown + "\n", count: 40)
        let started = ContinuousClock.now
        let html = try await renderer.render(DocPublishing.previewInput(title: "Long", markdown: long, pageURL: nil, publishedAt: nil))
        let elapsed = ContinuousClock.now - started
        #expect(html.utf8.count > long.utf8.count)
        #expect(elapsed < .milliseconds(500), "a 40-section page took \(elapsed)")
    }

    @Test("The bundle declares the renderer version its manifest was built at")
    func rendererVersionMatchesTheManifest() async throws {
        let manifestURL = try #require(PublishedPageRenderer.bundledManifestURL)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let declared = try #require(manifest?["renderer_version"] as? Int)
        let version = try await PublishedPageRenderer().rendererVersion()
        #expect(version == declared)
        let sources = try #require(manifest?["sources"] as? [String: String])
        #expect(Set(sources.keys) == ["docs-site/website/publishing/page.ts", "docs-site/website/publishing/markdown.ts"])
    }

    @Test("A bundle that throws is reported as a failure, not shown as a page")
    func brokenBundleIsAFailure() async {
        let renderer = PublishedPageRenderer(script: "throw new Error('boom')")
        let input = DocPublishing.previewInput(title: "T", markdown: "Body", pageURL: nil, publishedAt: nil)
        await #expect(throws: PublishedPageRenderer.Failure.self) {
            _ = try await renderer.render(input)
        }
        let noRenderer = PublishedPageRenderer(script: "var ForeverLMPublishedPage = {};")
        await #expect(throws: PublishedPageRenderer.Failure.self) {
            _ = try await noRenderer.render(input)
        }
        let renderThrows = PublishedPageRenderer(script: "var ForeverLMPublishedPage = { renderPublishedPage: function () { throw new TypeError('bad input'); } };")
        await #expect(throws: PublishedPageRenderer.Failure.renderFailed("TypeError: bad input")) {
            _ = try await renderThrows.render(input)
        }
    }

    @Test("Without a usable bundle the page comes from the site's preview route, as before")
    func missingBundleFallsBackToTheSite() async throws {
        let recorder = Recorder()
        let html = try await DocPublishing.page(
            title: "Research: Foo",
            markdown: "# Research: Foo\n\nBody",
            pageURL: URL(string: "https://foreverlm.com/share/techbio"),
            renderer: PublishedPageRenderer(scriptURL: nil),
            sessionToken: "v1.abc.9.sig",
            transport: { request in
                recorder.requests.append(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<!DOCTYPE html><title>from the site</title>".utf8), response)
            }
        )
        #expect(html.contains("from the site"))
        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/api/publish/preview")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer v1.abc.9.sig")
    }

    @Test("A link to another doc follows to that doc's page when the Docs list knows one, and stays prose when it does not")
    func docLinksFollowToPublishedPages() async throws {
        let renderer = PublishedPageRenderer()
        let input = DocPublishing.previewInput(
            title: "Report",
            markdown: "Read [the landscape](foreverlm://doc/doc-2) and [the draft](foreverlm://doc/doc-9).",
            pageURL: nil,
            publishedAt: nil,
            docLinks: ["doc-2": "https://foreverlm.com/share/landscape"]
        )
        #expect(input.docLinks == ["doc-2": "https://foreverlm.com/share/landscape"])
        let html = try await renderer.render(input)
        #expect(html.contains("<a href=\"https://foreverlm.com/share/landscape\">the landscape</a>"))
        #expect(html.contains("and the draft."))
        #expect(!html.contains("foreverlm://"))

        // The Page view hands the statuses the Docs list holds; nothing is asked of the site.
        let recorder = Recorder()
        let page = try await DocPublishing.page(
            title: "Report",
            markdown: "See [the landscape](foreverlm://doc/doc-2).",
            docLinks: ["doc-2": "https://foreverlm.com/share/landscape"],
            renderer: renderer,
            sessionToken: nil,
            transport: { request in
                recorder.requests.append(request)
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(page.contains("<a href=\"https://foreverlm.com/share/landscape\">the landscape</a>"))
        #expect(recorder.requests.isEmpty)
    }

    @Test("With the bundle the page never leaves the Mac")
    func bundledRendererNeedsNoRoundTrip() async throws {
        let recorder = Recorder()
        let html = try await DocPublishing.page(
            title: "Research: Foo",
            markdown: Self.fixtureMarkdown,
            renderer: PublishedPageRenderer(),
            sessionToken: nil,
            transport: { request in
                recorder.requests.append(request)
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(html.contains("<title>Research: Foo</title>"))
        #expect(recorder.requests.isEmpty)
    }
}
