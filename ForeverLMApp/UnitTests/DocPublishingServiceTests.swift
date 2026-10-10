import Foundation
import Testing
@testable import ForeverLM

@Suite("Doc publishing")
struct DocPublishingServiceTests {
    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func transport(
        status: Int,
        body: String,
        recorder: Recorder
    ) -> DocPublishing.Transport {
        { request in
            recorder.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test("Publishing sends the title and Markdown as a bearer-authenticated PUT and reads the page back")
    func publishRequestAndResponse() async throws {
        let recorder = Recorder()
        let status = try await DocPublishing.publish(
            docID: "doc-1",
            title: "Research: Foo",
            markdown: "# Research: Foo\n\nBody",
            sessionToken: "v1.abc.9.sig",
            transport: transport(status: 200, body: """
            {"published":true,"url":"https://foreverlm.com/share/abcdefghjkmn","slug":"abcdefghjkmn","title":"Research: Foo","published_at":"2026-09-06T01:02:03.456Z","updated_at":"2026-09-06T01:02:03.456Z","created":true}
            """, recorder: recorder)
        )
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://foreverlm.com/api/publish/docs/doc-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer v1.abc.9.sig")
        let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        #expect(sent == ["title": "Research: Foo", "markdown": "# Research: Foo\n\nBody"])
        #expect(status.url.absoluteString == "https://foreverlm.com/share/abcdefghjkmn")
        #expect(status.slug == "abcdefghjkmn")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(status.publishedAt == formatter.date(from: "2026-09-06T01:02:03.456Z"))
    }

    @Test("Readers ride in the body only when the caller means to change who can read the page")
    func readersEncoding() async throws {
        let recorder = Recorder()
        let okBody = """
        {"published":true,"url":"https://foreverlm.com/share/abcdefghjkmn","slug":"abcdefghjkmn","title":"T","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T01:00:00Z","protected":true,"readers":["a@example.com"]}
        """
        let kept = try await DocPublishing.publish(docID: "d", title: "T", markdown: "x", access: .keep, sessionToken: "t", transport: transport(status: 200, body: okBody, recorder: recorder))
        _ = try await DocPublishing.publish(docID: "d", title: "T", markdown: "x", access: .open, sessionToken: "t", transport: transport(status: 200, body: okBody, recorder: recorder))
        _ = try await DocPublishing.publish(docID: "d", title: "T", markdown: "x", access: .readers(["a@example.com", "b@example.org"]), sessionToken: "t", transport: transport(status: 200, body: okBody, recorder: recorder))
        let bodies = try recorder.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] ?? [:] }
        #expect(bodies[0]["readers"] == nil)
        #expect(bodies[0]["password"] == nil)
        #expect(bodies[1]["readers"] as? [String] == [])
        #expect(bodies[2]["readers"] as? [String] == ["a@example.com", "b@example.org"])
        #expect(kept.isProtected)
        #expect(kept.readers == ["a@example.com"])
        #expect(kept.password == nil)
    }

    @Test("Typed or pasted addresses are normalised, de-duplicated and refused when one is not an address")
    func readerNormalisation() {
        #expect(DocPublishing.normalizeReader("  Reader@Example.COM ") == "reader@example.com")
        #expect(DocPublishing.normalizeReader("reader") == nil)
        #expect(DocPublishing.normalizeReader("reader@localhost") == nil)
        #expect(DocPublishing.normalizeReader("two words@example.com") == nil)
        #expect(DocPublishing.normalizeReaders("") == [])
        #expect(DocPublishing.normalizeReaders("A@example.com, b@example.org;  a@example.com\nthe product owner <c@example.net>") == ["a@example.com", "b@example.org", "c@example.net"])
        #expect(DocPublishing.normalizeReaders("a@example.com, nobody") == nil)
    }

    @Test("A custom address rides in the body only when given, and is normalised the way the site does it")
    func slugEncodingAndNormalization() async throws {
        let recorder = Recorder()
        let okBody = """
        {"published":true,"url":"https://foreverlm.com/share/mito-report","slug":"mito-report","custom_slug":true,"title":"T","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T01:00:00Z"}
        """
        let plain = try await DocPublishing.publish(docID: "d", title: "T", markdown: "x", sessionToken: "t", transport: transport(status: 200, body: okBody, recorder: recorder))
        _ = try await DocPublishing.publish(docID: "d", title: "T", markdown: "x", slug: "mito-report", sessionToken: "t", transport: transport(status: 200, body: okBody, recorder: recorder))
        let bodies = try recorder.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: String] ?? [:] }
        #expect(bodies[0]["slug"] == nil)
        #expect(bodies[1]["slug"] == "mito-report")
        #expect(plain.isCustomSlug)
        #expect(plain.url.absoluteString == "https://foreverlm.com/share/mito-report")

        #expect(DocPublishing.normalizeCustomSlug("  Obesity-Landscape-2026 ") == "obesity-landscape-2026")
        #expect(DocPublishing.normalizeCustomSlug("https://foreverlm.com/share/My-Report.md") == "my-report")
        #expect(DocPublishing.normalizeCustomSlug("https://foreverlm.com/d/My-Report") == "my-report")
        #expect(DocPublishing.normalizeCustomSlug("/mito-2026/") == "mito-2026")
        for bad in ["ab", String(repeating: "a", count: 65), "two--hyphens", "-lead", "trail-", "has space", "ünïcode", "under_score", "preview", "api"] {
            #expect(DocPublishing.normalizeCustomSlug(bad) == nil, "\(bad)")
        }
    }

    @Test("Status reads nil for an unpublished doc and the page for a published one")
    func statusParsing() async throws {
        let recorder = Recorder()
        let none = try await DocPublishing.status(
            docID: "doc-1",
            sessionToken: "token",
            transport: transport(status: 200, body: #"{"published":false}"#, recorder: recorder)
        )
        #expect(none == nil)
        #expect(recorder.requests.first?.httpMethod == "GET")
        let some = try await DocPublishing.status(
            docID: "doc-1",
            sessionToken: "token",
            transport: transport(status: 200, body: """
            {"published":true,"doc_id":"doc-1","url":"https://foreverlm.com/share/abcdefghjkmn","slug":"abcdefghjkmn","title":"T","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T02:00:00Z","protected":true,"readers":["reader@example.com"]}
            """, recorder: recorder)
        )
        #expect(some?.title == "T")
        #expect(some?.docID == "doc-1")
        #expect(some?.readers == ["reader@example.com"])
        #expect(some?.password == nil)
        #expect(some?.updatedAt.timeIntervalSince(some?.publishedAt ?? .distantPast) == 3600)
    }

    @Test("The owner-wide status projection maps live pages to their Doc ids")
    func statusList() async throws {
        let recorder = Recorder()
        let statuses = try await DocPublishing.statuses(
            sessionToken: "token",
            transport: transport(status: 200, body: """
            {"published_docs":[
              {"published":true,"doc_id":"doc-a","url":"https://foreverlm.com/share/report-a","slug":"report-a","title":"A","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T02:00:00Z","protected":false},
              {"published":true,"doc_id":"doc-b","url":"https://foreverlm.com/share/report-b","slug":"report-b","title":"B","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T03:00:00Z","protected":true,"password":"secret"},
              {"published":true,"doc_id":"doc-c","url":"https://foreverlm.com/share/report-c","slug":"report-c","title":"C","published_at":"2026-09-06T01:00:00Z","updated_at":"2026-09-06T04:00:00Z","protected":true,"readers":["one@example.com","two@example.org"]}
            ]}
            """, recorder: recorder)
        )
        #expect(recorder.requests.first?.url?.path == "/api/publish/docs")
        #expect(statuses["doc-a"]?.url.absoluteString == "https://foreverlm.com/share/report-a")
        #expect(statuses["doc-b"]?.password == "secret", "a legacy page still reports the password it answers to")
        #expect(statuses["doc-b"]?.readers == [])
        #expect(statuses["doc-c"]?.readers == ["one@example.com", "two@example.org"])
        #expect(statuses["doc-c"]?.password == nil)
    }

    @Test("A signed-out Mac never sends a request, and a 401 reads as signed out")
    func signedOut() async throws {
        let recorder = Recorder()
        await #expect(throws: DocPublishingError.signedOut) {
            try await DocPublishing.publish(
                docID: "doc-1", title: "T", markdown: "x", sessionToken: nil,
                transport: transport(status: 200, body: "{}", recorder: recorder)
            )
        }
        #expect(recorder.requests.isEmpty)
        await #expect(throws: DocPublishingError.signedOut) {
            try await DocPublishing.unpublish(
                docID: "doc-1", sessionToken: "stale",
                transport: transport(status: 401, body: #"{"error":"invalid_session","error_description":"expired"}"#, recorder: recorder)
            )
        }
    }

    @Test("The service's own refusal is surfaced in its words")
    func serverRefusal() async throws {
        let recorder = Recorder()
        await #expect(throws: DocPublishingError.server(status: 429, code: "too_many_pages", message: "You can publish up to 100 docs. Unpublish one to make room.")) {
            try await DocPublishing.publish(
                docID: "doc-1", title: "T", markdown: "x", sessionToken: "token",
                transport: transport(status: 429, body: #"{"error":"too_many_pages","error_description":"You can publish up to 100 docs. Unpublish one to make room."}"#, recorder: recorder)
            )
        }
    }

    @Test("Unpublish is a DELETE on the same address")
    func unpublishRequest() async throws {
        let recorder = Recorder()
        try await DocPublishing.unpublish(
            docID: "doc-1", sessionToken: "token",
            transport: transport(status: 200, body: #"{"published":false,"was_published":true}"#, recorder: recorder)
        )
        #expect(recorder.requests.first?.httpMethod == "DELETE")
        #expect(recorder.requests.first?.url?.path == "/api/publish/docs/doc-1")
    }
}
