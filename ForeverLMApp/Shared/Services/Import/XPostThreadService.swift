import Foundation
import OSLog

/// Captures an X post — and the thread it hangs from — as durable text.
///
/// X is one of the documented cases where a provider exposes a genuinely
/// different protocol from the generic web fetch: `x.com/<handle>/status/<id>`
/// serves a JavaScript shell that renders nothing to an HTTP fetcher, shows a
/// login wall to logged-out clients, and is the first thing to disappear when
/// the Mac is offline or Screen Time restricts the domain. X publishes every
/// public post as JSON through the endpoint its own embed widget uses, so that
/// is the route this service takes.
///
/// What a capture holds: the post itself, every ancestor it replies to (walked
/// upward until the head of the conversation), the posts it quotes, and the
/// media attached to each. What it does not hold: replies *below* the captured
/// post. X publishes no public endpoint for a conversation's descendants, so a
/// thread bookmarked at its first post captures that post, not its
/// continuation — `plainText` says so in the document rather than pretending
/// the thread ended there.
actor XPostThreadService {

    static let shared = XPostThreadService()

    /// How far up a conversation a capture walks. Deep reply chains are rare
    /// and each hop is a request; past this the document says so instead.
    static let maximumAncestors = 24

    private let logger = Logger(subsystem: "com.foreverlm", category: "XPostThreadService")
    private let session: URLSession

    /// Reads the whole text of posts by id. X's public copy cuts a long post
    /// short, so this is the connected account's route to the rest.
    typealias LongPostLookup = @Sendable ([String]) async throws -> [String: String]

    /// Nil asks the connected X account, when there is one. A test hands in
    /// its own so a capture never reaches the Keychain or X's API.
    private let longPostLookup: LongPostLookup?

    init(session: URLSession = .shared, longPostLookup: LongPostLookup? = nil) {
        self.session = session
        self.longPostLookup = longPostLookup
    }

    // MARK: - URL Identity

    /// Host-level X/Twitter check, so unrelated domains like nfx.com never match.
    /// The single owner of this list: `StudioViewModel.isXHostURL` defers here.
    nonisolated static func isXHostURL(_ url: String) -> Bool {
        let xHosts: Set<String> = [
            "x.com", "www.x.com", "mobile.x.com",
            "twitter.com", "www.twitter.com", "mobile.twitter.com",
        ]
        let host = URLComponents(string: url)?.host?.lowercased() ?? ""
        return xHosts.contains(host)
    }

    /// The post id in an X permalink, or nil when the URL is not one.
    ///
    /// Identity stays deterministic: a post's id decides which record a capture
    /// belongs to, so it is read out of the path rather than inferred.
    nonisolated static func postID(from urlString: String) -> String? {
        guard isXHostURL(urlString),
              let components = URLComponents(string: urlString) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        // /<handle>/status/<id>, /i/status/<id>, and the older /statuses/ form.
        guard let statusIndex = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              statusIndex + 1 < parts.count else { return nil }
        let id = parts[statusIndex + 1]
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// The `token` X's embed widget derives from a post id. The endpoint is
    /// lenient about it today, but sending the value the widget would send
    /// keeps the request indistinguishable from an ordinary embed.
    nonisolated static func syndicationToken(forPostID id: String) -> String {
        guard let numeric = Double(id) else { return "0" }
        let value = (numeric / 1e15) * Double.pi
        let encoded = base36(value)
            .replacingOccurrences(of: "0", with: "")
            .replacingOccurrences(of: ".", with: "")
        return encoded.isEmpty ? "0" : encoded
    }

    /// JavaScript's `Number.prototype.toString(36)` for a positive value.
    private nonisolated static func base36(_ value: Double) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integerPart = Int(value.rounded(.down))
        var fraction = value - Double(integerPart)

        var whole = ""
        if integerPart == 0 {
            whole = "0"
        }
        while integerPart > 0 {
            whole = String(digits[integerPart % 36]) + whole
            integerPart /= 36
        }

        guard fraction > 0 else { return whole }
        var result = whole + "."
        for _ in 0..<16 {
            fraction *= 36
            let digit = Int(fraction.rounded(.down))
            result.append(digits[min(max(digit, 0), 35)])
            fraction -= Double(digit)
            if fraction <= 0 { break }
        }
        return result
    }

    // MARK: - Capture

    /// Capture `postURL` and its ancestors.
    ///
    /// `existingText` is the copy the library already holds — an X bookmark
    /// arrives with the post's full text from the authenticated API, and that
    /// copy must never be replaced by a shorter public one. A bookmark's text
    /// is put back into the saved post; an earlier capture that holds whole a
    /// post this one could only read the opening of ends the capture with
    /// `savedCopyIsFuller`, before anything is written.
    func capture(postURL: String, existingText: String? = nil) async throws -> XPostThread {
        guard let subjectID = Self.postID(from: postURL) else {
            throw XPostThreadError.notAnXPostURL
        }

        let subject = try await fetchPost(id: subjectID)

        // Ancestors, newest first as the walk finds them.
        var ancestors: [XThreadPost] = []
        var nextID = subject.replyToPostID
        var visitedIDs: Set<String> = [subjectID]
        var hops = 0
        var earlierPostsIncomplete = false
        while let ancestorID = nextID {
            guard hops < Self.maximumAncestors else {
                earlierPostsIncomplete = true
                break
            }
            guard visitedIDs.insert(ancestorID).inserted else {
                // A malformed reply chain must not spend the entire ancestor
                // budget walking the same posts over and over.
                earlierPostsIncomplete = true
                break
            }
            hops += 1
            do {
                let ancestor = try await fetchPost(id: ancestorID)
                ancestors.append(ancestor)
                nextID = ancestor.replyToPostID
            } catch {
                // A deleted, protected, or unavailable ancestor ends the walk;
                // everything captured below it is still worth keeping.
                earlierPostsIncomplete = true
                logger.info("Stopped X thread walk at \(ancestorID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        var posts = Array(ancestors.reversed()) + [subject]

        // X's public copy cuts long posts short and only flags that it did. The
        // authenticated API returns the whole thing, so fill the gaps from
        // there when the user is signed in.
        posts = await fillingTruncatedText(in: posts)

        if let existingText = existingText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingText.isEmpty {
            if Self.isRenderedCapture(existingText, subjectID: subjectID) {
                // The library holds an earlier capture. X's public copy cuts a
                // long post at 280 characters, and the rest comes only from a
                // connected X account, so a capture made on a Mac without one
                // (or while X refused the lookup) must not replace a capture
                // that read the post whole.
                let cutBefore = Set(Self.cutPostIDs(inCapture: existingText))
                let heldBefore = Self.postIDs(inCapture: existingText)
                if posts.contains(where: {
                    $0.isTruncated && heldBefore.contains($0.id) && !cutBefore.contains($0.id)
                }) {
                    throw XPostThreadError.savedCopyIsFuller
                }
            } else if let index = posts.firstIndex(where: { $0.id == subjectID }),
                      posts[index].isTruncated {
                posts[index].text = existingText
                posts[index].isTruncated = false
            }
        }

        return XPostThread(
            subjectID: subjectID,
            posts: posts,
            earlierPostsIncomplete: earlierPostsIncomplete
        )
    }

    /// A source synced from another Mac can already contain this service's
    /// durable rendering while its archive asset is still materializing. That
    /// rendering is not the subject post's authenticated text and must never be
    /// inserted into the subject during a re-capture.
    nonisolated static func isRenderedCapture(_ text: String, subjectID: String) -> Bool {
        // A capture opens with its first post's heading, or with the note that
        // earlier posts are missing when the walk stopped short of the head.
        (text.hasPrefix("## ") || text.hasPrefix(earlierPostsNote))
            && text.contains("/status/\(subjectID)")
    }

    nonisolated static let earlierPostsNote = "(Earlier posts in this thread were not captured.)"

    /// The line a rendering writes under a post X's public copy cut short. It
    /// is also how a stored capture says which of its posts are incomplete, so
    /// the rendering and the readers below share this one spelling.
    nonisolated static let cutPostNotePrefix = "(This post is longer on X: "

    nonisolated static func cutPostNote(permalink: String) -> String {
        "\(cutPostNotePrefix)\(permalink))"
    }

    /// The posts a stored capture holds only the opening of, in the order the
    /// capture lists them.
    nonisolated static func cutPostIDs(inCapture text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix(cutPostNotePrefix), line.hasSuffix(")") else { return nil }
            return postID(from: String(line.dropFirst(cutPostNotePrefix.count).dropLast()))
        }
    }

    /// Every post a stored capture holds, whole or cut: each one ends with its
    /// permalink on a line of its own.
    nonisolated static func postIDs(inCapture text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").compactMap { line in
            line.hasPrefix("https://x.com/") ? postID(from: line) : nil
        })
    }

    /// Replace the public endpoint's truncated copies with the authenticated
    /// API's full text. Best effort: one request for the whole thread, and a
    /// failure (signed out, rate limited, revoked scope) leaves the truncated
    /// copy in place with its marker.
    private func fillingTruncatedText(in posts: [XThreadPost]) async -> [XThreadPost] {
        let truncatedIDs = posts.filter(\.isTruncated).map(\.id)
        guard !truncatedIDs.isEmpty else { return posts }
        let lookup: LongPostLookup
        if let longPostLookup {
            lookup = longPostLookup
        } else {
            guard XBookmarkService.shared.isOAuthSignedIn else { return posts }
            lookup = { try await XBookmarkService.shared.fetchPostTexts(forPostIDs: $0) }
        }
        do {
            let full = try await lookup(truncatedIDs)
            guard !full.isEmpty else { return posts }
            return posts.map { post in
                guard let raw = full[post.id] else { return post }
                let text = Self.decodedPostText(raw)
                guard text.count > post.text.count else { return post }
                var filled = post
                filled.text = text
                filled.isTruncated = false
                return filled
            }
        } catch {
            logger.info("Long-post text unavailable from the X API: \(error.localizedDescription, privacy: .public)")
            return posts
        }
    }

    // MARK: - Author Picture

    /// The profile picture of whoever wrote `postID`, or nil when X publishes
    /// none for them.
    ///
    /// One post is enough to learn a handle's picture, so a library full of
    /// posts by the same author costs a single request — see
    /// `StudioViewModel.backfillXPostArtwork`, which groups by handle before
    /// asking.
    func authorAvatarURL(forPostID postID: String) async throws -> String? {
        try await fetchPost(id: postID).authorAvatarURL
    }

    /// X hands an embed widget the 48-pixel avatar, which is smaller than the
    /// thumbnail a source row draws. The same upload is published at 400
    /// pixels under a name that differs only in its size marker, so ask for
    /// that one instead of upscaling a thumbnail-sized JPEG.
    ///
    /// An account that never uploaded a picture is answered with X's grey
    /// placeholder. That is no more informative than the X mark the row draws
    /// for a post with no artwork at all, and it does not come in the larger
    /// size, so it resolves to nil.
    nonisolated static func displayAvatarURL(_ rawURL: String?) -> String? {
        guard let trimmed = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "twimg.com" || host.hasSuffix(".twimg.com") else { return nil }
        guard !url.lastPathComponent.hasPrefix("default_profile") else { return nil }
        return trimmed.replacingOccurrences(of: "_normal.", with: "_400x400.")
    }

    // MARK: - Networking

    private func fetchPost(id: String) async throws -> XThreadPost {
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "token", value: Self.syndicationToken(forPostID: id)),
            URLQueryItem(name: "lang", value: "en"),
        ]
        guard let url = components.url else { throw XPostThreadError.notAnXPostURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The endpoint answers embed widgets; an ordinary browser UA is what it
        // expects and what keeps it from serving the HTML error shell.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XPostThreadError.postUnavailable(id, "No response")
        }
        guard http.statusCode == 200 else {
            throw XPostThreadError.postUnavailable(id, "HTTP \(http.statusCode)")
        }
        return try Self.decodePost(id: id, from: data)
    }

    /// Pure decode, so the shape of a real X response can be exercised in tests
    /// without a network call.
    nonisolated static func decodePost(id: String, from data: Data) throws -> XThreadPost {
        // A missing post answers 200 with X's HTML error page, and a removed one
        // answers with a tombstone object.
        guard let decoded = try? JSONDecoder().decode(SyndicationPost.self, from: data) else {
            throw XPostThreadError.postUnavailable(id, "Response was not a post")
        }
        guard decoded.typename != "TweetTombstone", decoded.text != nil else {
            throw XPostThreadError.postUnavailable(id, "Post is no longer available")
        }
        return decoded.threadPost(fallbackID: id)
    }

    // MARK: - Syndication Response

    private struct SyndicationUser: Decodable {
        let name: String?
        let screenName: String?
        let profileImageURL: String?

        enum CodingKeys: String, CodingKey {
            case name
            case screenName = "screen_name"
            case profileImageURL = "profile_image_url_https"
        }
    }

    private struct SyndicationEntityURL: Decodable {
        let url: String?
        let expandedURL: String?

        enum CodingKeys: String, CodingKey {
            case url
            case expandedURL = "expanded_url"
        }
    }

    private struct SyndicationEntities: Decodable {
        let urls: [SyndicationEntityURL]?
    }

    private struct SyndicationPhoto: Decodable {
        let url: String?
    }

    private struct SyndicationVideo: Decodable {
        let poster: String?
    }

    private struct SyndicationNoteRef: Decodable {
        let id: String?
    }

    /// A post referenced by another one. Identical in shape to the post itself,
    /// minus the reference fields — the walk re-fetches each ancestor by id, so
    /// nothing here needs to nest further.
    private struct SyndicationRelatedPost: Decodable {
        let idStr: String?
        let text: String?
        let createdAt: String?
        let user: SyndicationUser?
        let entities: SyndicationEntities?
        let noteTweet: SyndicationNoteRef?

        enum CodingKeys: String, CodingKey {
            case text, user, entities
            case idStr = "id_str"
            case createdAt = "created_at"
            case noteTweet = "note_tweet"
        }
    }

    private struct SyndicationPost: Decodable {
        let typename: String?
        let idStr: String?
        let text: String?
        let createdAt: String?
        let user: SyndicationUser?
        let entities: SyndicationEntities?
        let photos: [SyndicationPhoto]?
        let video: SyndicationVideo?
        /// Present only when X truncated a long post's `text`.
        let noteTweet: SyndicationNoteRef?
        let inReplyToStatusIDStr: String?
        let parent: SyndicationRelatedPost?
        let quotedTweet: SyndicationRelatedPost?

        enum CodingKeys: String, CodingKey {
            case text, user, entities, photos, video, parent
            case typename = "__typename"
            case idStr = "id_str"
            case createdAt = "created_at"
            case noteTweet = "note_tweet"
            case inReplyToStatusIDStr = "in_reply_to_status_id_str"
            case quotedTweet = "quoted_tweet"
        }

        func threadPost(fallbackID: String) -> XThreadPost {
            XThreadPost(
                id: idStr ?? fallbackID,
                authorName: user?.name ?? "",
                authorHandle: user?.screenName ?? "",
                createdAt: XPostThreadService.date(fromSyndication: createdAt),
                text: XPostThreadService.expandingLinks(
                    in: text ?? "",
                    entities: entities?.urls
                ),
                isTruncated: noteTweet != nil,
                photoURLs: (photos ?? []).compactMap(\.url),
                videoPosterURL: video?.poster,
                authorAvatarURL: XPostThreadService.displayAvatarURL(user?.profileImageURL),
                // A quoted post is context for the post that quotes it, not a
                // step in the thread, so it rides along rather than becoming
                // its own entry.
                quoted: quotedTweet.map { quoted in
                    XQuotedPost(
                        id: quoted.idStr ?? "",
                        authorName: quoted.user?.name ?? "",
                        authorHandle: quoted.user?.screenName ?? "",
                        text: XPostThreadService.expandingLinks(
                            in: quoted.text ?? "",
                            entities: quoted.entities?.urls
                        )
                    )
                },
                replyToPostID: inReplyToStatusIDStr ?? parent?.idStr
            )
        }
    }

    nonisolated static func date(fromSyndication value: String?) -> Date? {
        guard let value else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return KnowledgeStore.iso8601Formatter.date(from: value)
    }

    /// Swap each `t.co` shortlink for the URL it stands for. The mapping is
    /// published with the post, so this substitutes known values rather than
    /// guessing at the text.
    private nonisolated static func expandingLinks(
        in text: String,
        entities: [SyndicationEntityURL]?
    ) -> String {
        var expanded = text
        for entity in entities ?? [] {
            guard let short = entity.url, !short.isEmpty,
                  let full = entity.expandedURL, !full.isEmpty else { continue }
            expanded = expanded.replacingOccurrences(of: short, with: full)
        }
        return decodedPostText(expanded)
    }

    /// X sends a post's text with `&`, `<` and `>` as HTML entities (both the public
    /// endpoint and the API), and the archive escapes text again when it writes
    /// HTML, so an undecoded "R&amp;D" read as that on the phone.
    nonisolated static func decodedPostText(_ text: String) -> String {
        LocalSite.decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Captured Model

/// A post inside a captured thread.
struct XThreadPost: Sendable, Equatable {
    let id: String
    let authorName: String
    let authorHandle: String
    let createdAt: Date?
    var text: String
    /// X's public copy cut a long post short and this is only its opening.
    var isTruncated: Bool
    let photoURLs: [String]
    let videoPosterURL: String?
    /// The author's profile picture, at a size worth showing — nil when the
    /// account carries X's default placeholder rather than a picture.
    let authorAvatarURL: String?
    let quoted: XQuotedPost?
    /// The post this one replies to, when it replies to one.
    let replyToPostID: String?

    var permalink: String {
        authorHandle.isEmpty
            ? "https://x.com/i/status/\(id)"
            : "https://x.com/\(authorHandle)/status/\(id)"
    }

    var byline: String {
        let handle = authorHandle.isEmpty ? "" : "@\(authorHandle)"
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return handle }
        if handle.isEmpty { return name }
        return "\(name) (\(handle))"
    }
}

/// A post quoted by a captured post.
struct XQuotedPost: Sendable, Equatable {
    let id: String
    let authorName: String
    let authorHandle: String
    let text: String
}

/// A captured post together with the ancestors it replies to, oldest first.
struct XPostThread: Sendable, Equatable {
    let subjectID: String
    let posts: [XThreadPost]
    /// The walk stopped before the head of the conversation because an earlier
    /// post was unavailable, the reply chain looped, or the depth cap was hit.
    let earlierPostsIncomplete: Bool

    var subject: XThreadPost? {
        posts.first { $0.id == subjectID } ?? posts.last
    }
}

// MARK: - Renderings

/// Both renderings descend from the same capture, so the text the assistant,
/// search, and the phone read is the text the reader shows — the same contract
/// `SourceService.readableTextFromHTML` keeps for web articles.
extension XPostThread {

    /// The title a source keeps in the library: the handle plus the opening of
    /// the post, matching what X bookmark sync writes for the same post.
    var sourceTitle: String {
        guard let subject else { return "X post" }
        return Self.sourceTitle(handle: subject.authorHandle, text: subject.text)
    }

    static func sourceTitle(handle: String, text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = flattened.count > 80
            ? String(flattened.prefix(80)) + "…"
            : flattened
        let handleLabel = handle.isEmpty ? "X post" : "@\(handle)"
        return opening.isEmpty ? handleLabel : "\(handleLabel): \(opening)"
    }

    /// The durable copy: what search indexes, what the assistant reads, what
    /// the phone syncs, and what the reader falls back to when x.com cannot be
    /// reached.
    var plainText: String {
        var blocks: [String] = []
        if earlierPostsIncomplete {
            blocks.append(XPostThreadService.earlierPostsNote)
        }
        for post in posts {
            var lines: [String] = []
            var heading = post.byline
            if let date = post.createdAt {
                heading += " · \(Self.dateFormatter.string(from: date))"
            }
            if post.id == subjectID, posts.count > 1 {
                heading += " · saved post"
            }
            lines.append("## \(heading)")
            lines.append(post.text)
            if post.isTruncated {
                lines.append(XPostThreadService.cutPostNote(permalink: post.permalink))
            }
            if let quoted = post.quoted {
                let quotedHandle = quoted.authorHandle.isEmpty ? "" : "@\(quoted.authorHandle) "
                let quotedBody = quoted.text
                    .components(separatedBy: .newlines)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                lines.append("> Quoting \(quotedHandle)\n\(quotedBody)")
            }
            for photo in post.photoURLs {
                lines.append("[Image] \(photo)")
            }
            if post.videoPosterURL != nil {
                lines.append("[Video] \(post.permalink)")
            }
            lines.append(post.permalink)
            blocks.append(lines.joined(separator: "\n\n"))
        }
        if subject != nil {
            // Nothing below the saved post is available through the public
            // capture route, including when the saved post is the thread root.
            blocks.append("(Replies to this post are not captured — open it on X to read them.)")
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    /// The archived document. Only tags `SourceService.readerHTML` keeps are
    /// used, because the archive is written through the same sanitizer as any
    /// other saved page — which is also what downloads the images for offline
    /// reading.
    var archiveHTML: String {
        var body = ""
        body += "<h1>\(sourceTitle.htmlEscaped)</h1>\n"
        if earlierPostsIncomplete {
            body += "<p><em>Earlier posts in this thread were not captured.</em></p>\n"
        }
        for (index, post) in posts.enumerated() {
            if index > 0 { body += "<hr>\n" }
            var heading = post.byline
            if let date = post.createdAt {
                heading += " · \(Self.dateFormatter.string(from: date))"
            }
            body += "<p><strong>\(heading.htmlEscaped)</strong></p>\n"
            for paragraph in post.text.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                body += "<p>\(paragraph.htmlEscaped)</p>\n"
            }
            if post.isTruncated {
                body += "<p><em>This post is longer on X.</em></p>\n"
            }
            if let quoted = post.quoted {
                let quotedHandle = quoted.authorHandle.isEmpty ? "" : "@\(quoted.authorHandle)"
                body += "<blockquote><p><strong>\(quotedHandle.htmlEscaped)</strong></p>"
                for paragraph in quoted.text.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                    body += "<p>\(paragraph.htmlEscaped)</p>"
                }
                body += "</blockquote>\n"
            }
            for photo in post.photoURLs {
                body += "<figure><img src=\"\(photo.htmlEscaped)\" alt=\"\"></figure>\n"
            }
            if let poster = post.videoPosterURL {
                body += "<figure><img src=\"\(poster.htmlEscaped)\" alt=\"\">"
                body += "<figcaption><a href=\"\(post.permalink.htmlEscaped)\">Play the video on X</a></figcaption></figure>\n"
            }
            body += "<p><a href=\"\(post.permalink.htmlEscaped)\">\(post.permalink.htmlEscaped)</a></p>\n"
        }
        if subject != nil {
            body += "<p><em>Replies to this post are not captured — open it on X to read them.</em></p>\n"
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(sourceTitle.htmlEscaped)</title></head>
        <body>\(body)</body></html>
        """
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Canonical content syncs between devices. A locale- or timezone-based
        // rendering would make the same capture hash differently on two Macs.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm 'UTC'"
        return formatter
    }()
}

// MARK: - Errors

enum XPostThreadError: LocalizedError, Equatable {
    case notAnXPostURL
    case postUnavailable(String, String)
    /// The capture holds only the opening of a post the library already holds
    /// whole. Nothing is wrong with the source; the saved text stays.
    case savedCopyIsFuller

    var errorDescription: String? {
        switch self {
        case .savedCopyIsFuller:
            return "X's public copy cuts this post short, and the saved text holds all of it."
        case .notAnXPostURL:
            return "That link is not an X post."
        case let .postUnavailable(id, reason):
            return "X post \(id) could not be read: \(reason)"
        }
    }
}
