import Foundation
import Testing
@testable import ForeverLM

@Suite("X Post Thread Capture", .serialized)
struct XPostThreadTests {

    // MARK: - Post Identity

    @Test("Reads the post id out of every X permalink shape")
    func readsPostIDFromPermalinks() {
        #expect(XPostThreadService.postID(from: "https://x.com/owl_posting/status/1234567890") == "1234567890")
        #expect(XPostThreadService.postID(from: "https://twitter.com/owl_posting/status/1234567890") == "1234567890")
        #expect(XPostThreadService.postID(from: "https://mobile.twitter.com/a/statuses/42") == "42")
        #expect(XPostThreadService.postID(from: "https://x.com/i/status/99?s=20") == "99")
    }

    @Test("Never claims a URL that is not an X post")
    func rejectsNonPostURLs() {
        // Host-level matching: a domain that merely ends in x.com is not X.
        #expect(XPostThreadService.postID(from: "https://nfx.com/status/12") == nil)
        #expect(XPostThreadService.postID(from: "https://x.com/owl_posting") == nil)
        #expect(XPostThreadService.postID(from: "https://x.com/i/status/not-a-number") == nil)
        #expect(XPostThreadService.postID(from: "https://example.com/x.com/status/5") == nil)
    }

    // MARK: - Decoding

    /// The shape X's embed endpoint answers with, trimmed to the fields a
    /// capture reads.
    private func syndicationJSON(
        id: String,
        text: String,
        handle: String = "owl_posting",
        name: String = "Owl",
        replyTo: String? = nil,
        truncated: Bool = false
    ) throws -> Data {
        var object: [String: Any] = [
            "__typename": "Tweet",
            "id_str": id,
            "text": text,
            "created_at": "2026-08-20T10:15:00.000Z",
            "user": ["name": name, "screen_name": handle],
        ]
        if let replyTo { object["in_reply_to_status_id_str"] = replyTo }
        if truncated { object["note_tweet"] = ["id": "note-\(id)"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("Decodes a post, its reply target, media, and quoted post")
    func decodesPost() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "__typename": "Tweet",
            "id_str": "222",
            "text": "the argument in https://t.co/short is wrong",
            "created_at": "2026-08-20T10:15:00.000Z",
            "user": [
                "name": "Owl",
                "screen_name": "owl_posting",
                "profile_image_url_https": "https://pbs.twimg.com/profile_images/9/owl_normal.jpg",
            ],
            "entities": ["urls": [[
                "url": "https://t.co/short",
                "expanded_url": "https://example.com/paper",
            ]]],
            "photos": [["url": "https://pbs.twimg.com/media/one.jpg"]],
            "in_reply_to_status_id_str": "111",
            "quoted_tweet": [
                "id_str": "100",
                "text": "the original claim",
                "user": ["name": "Dario", "screen_name": "darioamodei"],
            ],
        ])

        let post = try XPostThreadService.decodePost(id: "222", from: data)
        #expect(post.id == "222")
        #expect(post.authorHandle == "owl_posting")
        #expect(post.byline == "Owl (@owl_posting)")
        // t.co shortlinks are swapped for the URL published alongside them.
        #expect(post.text == "the argument in https://example.com/paper is wrong")
        #expect(post.photoURLs == ["https://pbs.twimg.com/media/one.jpg"])
        // The embed endpoint publishes the 48-pixel copy; a source row draws
        // the 400-pixel one.
        #expect(post.authorAvatarURL == "https://pbs.twimg.com/profile_images/9/owl_400x400.jpg")
        #expect(post.replyToPostID == "111")
        #expect(post.quoted?.authorHandle == "darioamodei")
        #expect(post.isTruncated == false)
        #expect(post.permalink == "https://x.com/owl_posting/status/222")
    }

    @Test("Reads the entities X puts in a post's text as the characters they stand for")
    func decodesEntitiesInPostText() throws {
        let data = try syndicationJSON(id: "5", text: "Pharma spends $400B/yr on R&amp;D &lt;5 years &gt; 2")
        let post = try XPostThreadService.decodePost(id: "5", from: data)
        #expect(post.text == "Pharma spends $400B/yr on R&D <5 years > 2")
        // Escaped once, when the archive writes HTML, and not twice.
        let thread = XPostThread(subjectID: "5", posts: [post], earlierPostsIncomplete: false)
        #expect(thread.archiveHTML.contains("R&amp;D &lt;5"))
        #expect(!thread.archiveHTML.contains("&amp;amp;"))
    }

    @Test("Flags a long post the public endpoint cut short")
    func flagsTruncatedPost() throws {
        let data = try syndicationJSON(id: "1", text: "opening of a long essay", truncated: true)
        #expect(try XPostThreadService.decodePost(id: "1", from: data).isTruncated)
    }

    @Test("Asks X for the picture size a source row draws")
    func upgradesAvatarSize() {
        #expect(
            XPostThreadService.displayAvatarURL(
                "https://pbs.twimg.com/profile_images/9/owl_normal.jpg"
            ) == "https://pbs.twimg.com/profile_images/9/owl_400x400.jpg"
        )
        // A picture already published at a usable size is left alone.
        #expect(
            XPostThreadService.displayAvatarURL(
                "https://pbs.twimg.com/profile_images/9/owl_bigger.png"
            ) == "https://pbs.twimg.com/profile_images/9/owl_bigger.png"
        )
    }

    @Test("Treats a placeholder picture as no picture")
    func rejectsUnusableAvatars() {
        // X's grey egg says no more than the X mark the row draws without it,
        // and it is not published in the larger size.
        #expect(
            XPostThreadService.displayAvatarURL(
                "https://abs.twimg.com/sticky/default_profile_images/default_profile_normal.png"
            ) == nil
        )
        #expect(XPostThreadService.displayAvatarURL(nil) == nil)
        #expect(XPostThreadService.displayAvatarURL("  ") == nil)
        // Only X's own image host, over TLS, and never a local file.
        #expect(XPostThreadService.displayAvatarURL("http://pbs.twimg.com/profile_images/9/owl_normal.jpg") == nil)
        #expect(XPostThreadService.displayAvatarURL("https://example.com/profile_images/9/owl_normal.jpg") == nil)
        #expect(XPostThreadService.displayAvatarURL("https://nottwimg.com/profile_images/9/owl_normal.jpg") == nil)
        #expect(XPostThreadService.displayAvatarURL("file:///tmp/owl_normal.jpg") == nil)
    }

    @Test("Refuses a removed post and a non-post response")
    func refusesUnavailablePosts() throws {
        let tombstone = try JSONSerialization.data(withJSONObject: [
            "__typename": "TweetTombstone",
            "tombstone": ["text": ["text": "This Post was deleted by the Post author."]],
        ])
        #expect(throws: XPostThreadError.self) {
            try XPostThreadService.decodePost(id: "1", from: tombstone)
        }
        #expect(throws: XPostThreadError.self) {
            try XPostThreadService.decodePost(id: "1", from: Data("<!DOCTYPE html>".utf8))
        }
    }

    @Test("Walks ancestors once and reports an incomplete reply chain")
    func walksAncestorsAndStopsAtCycle() async throws {
        XPostThreadMockURLProtocol.install([
            "3": (200, try syndicationJSON(id: "3", text: "third", replyTo: "2")),
            "2": (200, try syndicationJSON(id: "2", text: "second", replyTo: "3")),
        ])
        let service = XPostThreadService(session: XPostThreadMockURLProtocol.session())

        let thread = try await service.capture(
            postURL: "https://x.com/owl_posting/status/3"
        )

        #expect(thread.posts.map(\.id) == ["2", "3"])
        #expect(thread.earlierPostsIncomplete)
        #expect(thread.plainText.contains("Earlier posts in this thread were not captured."))
    }

    // MARK: - Renderings

    private func post(
        id: String,
        text: String,
        handle: String = "owl_posting",
        truncated: Bool = false,
        quoted: XQuotedPost? = nil
    ) -> XThreadPost {
        XThreadPost(
            id: id,
            authorName: "Owl",
            authorHandle: handle,
            createdAt: nil,
            text: text,
            isTruncated: truncated,
            photoURLs: [],
            videoPosterURL: nil,
            authorAvatarURL: nil,
            quoted: quoted,
            replyToPostID: nil
        )
    }

    @Test("Unrolls the thread oldest first and marks the saved post")
    func unrollsThread() throws {
        let thread = XPostThread(
            subjectID: "3",
            posts: [
                post(id: "1", text: "first"),
                post(id: "2", text: "second"),
                post(id: "3", text: "third"),
            ],
            earlierPostsIncomplete: false
        )

        let text = thread.plainText
        let first = try #require(text.range(of: "first"))
        let third = try #require(text.range(of: "third"))
        #expect(first.lowerBound < third.lowerBound)
        #expect(text.contains("saved post"))
        #expect(text.contains("https://x.com/owl_posting/status/2"))
        // The capture cannot see replies below the saved post, and says so
        // rather than letting the thread look finished.
        #expect(text.contains("Replies to this post are not captured"))
    }

    @Test("Says so when a long post or an earlier post is missing")
    func reportsIncompleteCaptures() {
        let thread = XPostThread(
            subjectID: "1",
            posts: [post(id: "1", text: "opening", truncated: true)],
            earlierPostsIncomplete: true
        )
        #expect(thread.plainText.contains("Earlier posts in this thread were not captured."))
        #expect(thread.plainText.contains("This post is longer on X"))
        #expect(thread.archiveHTML.contains("This post is longer on X."))
    }

    @Test("Archives markup the reader's sanitizer keeps, with escaped text")
    func archivesSanitizerSafeHTML() {
        let thread = XPostThread(
            subjectID: "1",
            posts: [post(
                id: "1",
                text: "5 < 6 & \"quoted\"",
                quoted: XQuotedPost(id: "9", authorName: "Dario", authorHandle: "darioamodei", text: "original")
            )],
            earlierPostsIncomplete: false
        )

        let html = thread.archiveHTML
        #expect(html.contains("5 &lt; 6 &amp; &quot;quoted&quot;"))
        #expect(html.contains("<blockquote>"))
        #expect(!html.contains("<script"))

        // Everything the document carries has to survive the archive sanitizer,
        // since that is what writes the saved copy to disk.
        let sanitized = SourceService.readerHTML(from: html)
        #expect(sanitized.contains("5 &lt; 6 &amp; &quot;quoted&quot;"))
        #expect(sanitized.contains("<blockquote>"))
        #expect(sanitized.contains("@darioamodei"))
    }

    @Test("Recognizes its own synced rendering without mistaking raw post text for it")
    func recognizesRenderedCapture() {
        let thread = XPostThread(
            subjectID: "1",
            posts: [post(id: "1", text: "the raw post")],
            earlierPostsIncomplete: false
        )

        #expect(XPostThreadService.isRenderedCapture(thread.plainText, subjectID: "1"))
        #expect(!XPostThreadService.isRenderedCapture("the raw post", subjectID: "1"))
    }

    // MARK: - Long Posts

    @Test("Reads which posts a saved capture holds, and which of them are cut short")
    func readsCutPostsFromCapture() {
        let capture = XPostThread(
            subjectID: "2",
            posts: [
                post(id: "1", text: "opening", truncated: true),
                post(id: "2", text: "whole"),
            ],
            earlierPostsIncomplete: true
        ).plainText

        #expect(XPostThreadService.cutPostIDs(inCapture: capture) == ["1"])
        #expect(XPostThreadService.postIDs(inCapture: capture) == ["1", "2"])
        // A capture that opens with the earlier-posts note is still a capture,
        // not a post's own text to put back into the saved post.
        #expect(XPostThreadService.isRenderedCapture(capture, subjectID: "2"))
        #expect(XPostThreadService.cutPostIDs(inCapture: "a bookmark's own text").isEmpty)
    }

    @Test("A bookmark's full text goes back into a post the public copy cut short")
    func keepsBookmarkText() async throws {
        XPostThreadMockURLProtocol.install([
            "7": (200, try syndicationJSON(id: "7", text: "opening", truncated: true)),
        ])
        // The account would answer too, but the library's own text comes
        // first: it costs no paid read.
        let service = XPostThreadService(
            session: XPostThreadMockURLProtocol.session(),
            longPostLookup: { ids in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, "opening, and then the account's copy of every paragraph") })
            }
        )

        let thread = try await service.capture(
            postURL: "https://x.com/owl_posting/status/7",
            existingText: "opening, and then every paragraph after it"
        )

        #expect(thread.subject?.text == "opening, and then every paragraph after it")
        #expect(XPostThreadService.cutPostIDs(inCapture: thread.plainText).isEmpty)
    }

    @Test("A capture keeps every post an earlier capture holds whole")
    func keepsFullerSavedCapture() async throws {
        XPostThreadMockURLProtocol.install([
            "7": (200, try syndicationJSON(id: "7", text: "opening", truncated: true)),
        ])
        let url = "https://x.com/owl_posting/status/7"
        let signedOut = XPostThreadService(
            session: XPostThreadMockURLProtocol.session(),
            longPostLookup: { _ in [:] }
        )

        // The refetch a Mac without an X account ran for the phone: the saved
        // capture holds the whole post, the public copy 280 characters of it.
        let whole = XPostThread(
            subjectID: "7",
            posts: [post(id: "7", text: "opening, and then every paragraph after it\n\nwith a second one")],
            earlierPostsIncomplete: false
        ).plainText
        let kept = try await signedOut.capture(postURL: url, existingText: whole)
        #expect(kept.subject?.text == "opening, and then every paragraph after it\n\nwith a second one")
        #expect(XPostThreadService.cutPostIDs(inCapture: kept.plainText).isEmpty)

        // A saved capture that is cut short itself has nothing to keep.
        let cut = XPostThread(
            subjectID: "7",
            posts: [post(id: "7", text: "opening", truncated: true)],
            earlierPostsIncomplete: false
        ).plainText
        #expect(XPostThreadService.wholeText(of: post(id: "7", text: "opening"), inCapture: cut) == nil)
        let again = try await signedOut.capture(postURL: url, existingText: cut)
        #expect(XPostThreadService.cutPostIDs(inCapture: again.plainText) == ["7"])

        // With an account connected the rest is read, and the note goes.
        let signedIn = XPostThreadService(
            session: XPostThreadMockURLProtocol.session(),
            longPostLookup: { ids in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, "opening, and then every paragraph after it") })
            }
        )
        let filled = try await signedIn.capture(postURL: url, existingText: cut)
        #expect(filled.subject?.text == "opening, and then every paragraph after it")
        #expect(XPostThreadService.cutPostIDs(inCapture: filled.plainText).isEmpty)
    }

    @Test("A whole post that cannot be read back from the saved capture is never replaced by its opening")
    func refusesToCutAPostHeldWhole() async throws {
        XPostThreadMockURLProtocol.install([
            "7": (200, try syndicationJSON(id: "7", text: "opening", truncated: true)),
        ])
        let signedOut = XPostThreadService(
            session: XPostThreadMockURLProtocol.session(),
            longPostLookup: { _ in [:] }
        )
        // The saved capture wrote the post with a picture X no longer serves,
        // so its block does not end the way the new capture's would.
        let pictured = XThreadPost(
            id: "7",
            authorName: "Owl",
            authorHandle: "owl_posting",
            createdAt: nil,
            text: "opening, and then every paragraph after it",
            isTruncated: false,
            photoURLs: ["https://pbs.twimg.com/media/owl.jpg"],
            videoPosterURL: nil,
            authorAvatarURL: nil,
            quoted: nil,
            replyToPostID: nil
        )
        let saved = XPostThread(subjectID: "7", posts: [pictured], earlierPostsIncomplete: false).plainText

        await #expect(throws: XPostThreadError.savedCopyIsFuller) {
            try await signedOut.capture(postURL: "https://x.com/owl_posting/status/7", existingText: saved)
        }
    }

    @Test("Renders canonical dates in UTC on every device")
    func rendersCanonicalDate() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-08-20T10:15:00Z"))
        let dated = XThreadPost(
            id: "1",
            authorName: "Owl",
            authorHandle: "owl_posting",
            createdAt: date,
            text: "dated post",
            isTruncated: false,
            photoURLs: [],
            videoPosterURL: nil,
            authorAvatarURL: nil,
            quoted: nil,
            replyToPostID: nil
        )
        let thread = XPostThread(
            subjectID: "1",
            posts: [dated],
            earlierPostsIncomplete: false
        )

        #expect(thread.plainText.contains("Aug 20, 2026 at 10:15 UTC"))
        #expect(thread.archiveHTML.contains("Aug 20, 2026 at 10:15 UTC"))
    }

    @Test("Names a source the same way whether it arrived by bookmark or by link")
    func namesSourceConsistently() {
        #expect(XPostThread.sourceTitle(handle: "owl_posting", text: "short one")
            == "@owl_posting: short one")
        let long = String(repeating: "a", count: 200)
        #expect(XPostThread.sourceTitle(handle: "owl_posting", text: long).hasSuffix("…"))
        #expect(XPostThread.sourceTitle(handle: "owl_posting", text: "line\nbreak")
            == "@owl_posting: line break")
    }

    // MARK: - Capture Backlog

    @Test("An X post without a saved capture still needs the fetch")
    func xPostWithTextStillNeedsCapture() {
        // A bookmark arrives `.ready` with the post's text and no saved copy.
        // Offline readability is what the fetch buys, so text alone is not done.
        var bookmarked = StudioArticle(
            url: "https://x.com/owl_posting/status/1",
            title: "@owl_posting: a post",
            sourceType: .xPost
        )
        bookmarked.content = "a post"
        bookmarked.state = .ready

        #expect(StudioViewModel.sourceNeedsInitialContentFetch(bookmarked, alreadyAttempted: []))
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(
            bookmarked,
            alreadyAttempted: [bookmarked.id]
        ))

        var captured = bookmarked
        captured.localFilePath = "Articles/\(bookmarked.id)/article.html"
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(captured, alreadyAttempted: []))
    }

    @Test("A bookmarked post that holds its text still gets its thread captured, once")
    func bookmarkedPostGetsThreadCapture() {
        // The fetch used to end as soon as it saw the bookmark's text, so the
        // capture the backlog asks for above never ran.
        var bookmarked = StudioArticle(
            url: "https://x.com/owl_posting/status/1",
            title: "@owl_posting: a post",
            sourceType: .xPost
        )
        bookmarked.content = "a post"
        bookmarked.state = .ready
        #expect(StudioViewModel.xPostNeedsThreadCapture(bookmarked, alreadyAttempted: []))
        #expect(!StudioViewModel.xPostNeedsThreadCapture(bookmarked, alreadyAttempted: [bookmarked.id]))

        var captured = bookmarked
        captured.localFilePath = "Articles/\(bookmarked.id)/article.html"
        #expect(!StudioViewModel.xPostNeedsThreadCapture(captured, alreadyAttempted: []))

        // Without text there is nothing to keep: the ordinary fetch captures it.
        var empty = bookmarked
        empty.content = nil
        #expect(!StudioViewModel.xPostNeedsThreadCapture(empty, alreadyAttempted: []))

        var article = bookmarked
        article.sourceType = .article
        #expect(!StudioViewModel.xPostNeedsThreadCapture(article, alreadyAttempted: []))
    }
}

private final class XPostThreadMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installedResponses: [String: (Int, Data)] = [:]

    static func install(_ responses: [String: (Int, Data)]) {
        lock.lock()
        installedResponses = responses
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XPostThreadMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cdn.syndication.twimg.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let installed = Self.installedResponses[id]
        Self.lock.unlock()
        let status = installed?.0 ?? 404
        let data = installed?.1 ?? Data()
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Opt-in live check against X's public embed endpoint — the one route a
/// capture depends on. Disabled during ordinary runs (network), enabled with
/// `FOREVERLM_LIVE_API_TESTS=1` like the other live smoke tests.
@Suite(
    "Live X post capture",
    .enabled(if: ProcessInfo.processInfo.environment["FOREVERLM_LIVE_API_TESTS"] == "1")
)
struct LiveXPostCaptureTests {
    @Test("Captures a real post and unrolls the thread above it")
    func capturesLiveThread() async throws {
        // The second post of a long-lived public thread, so the walk has an
        // ancestor to find.
        let thread = try await XPostThreadService.shared.capture(
            postURL: "https://x.com/naval/status/1002103497725173760"
        )

        #expect(thread.subjectID == "1002103497725173760")
        #expect(thread.posts.count >= 2)
        #expect(thread.posts.first?.id == "1002103360646823936")
        #expect(thread.posts.last?.id == thread.subjectID)
        #expect(thread.subject?.authorHandle.lowercased() == "naval")
        #expect(!thread.plainText.isEmpty)
        #expect(thread.archiveHTML.contains("<p>"))
    }
}
