import Foundation
import OSLog

/// Teachable course lectures: reading a lecture page as the signed-in learner,
/// and turning its video into a transcript.
///
/// Teachable has no API a student can use, but its lecture pages are rendered
/// on the server, and each one carries the whole course outline in its sidebar
/// (sections, lecture ids and names) plus the lecture's own attachments.
/// Everything here is structure read from that markup (ids, addresses, the
/// element a title sits in), never meaning parsed out of prose.
///
/// Access is the learner's own. Their Teachable sign-in has to be made inside
/// ForeverLM (the Browser pane's Library profile, or the reader), because the
/// app's fetches carry the in-app web session's cookies
/// (`SourceService.authenticatedBrowserRequest`) and nothing else; a page that
/// comes back as Teachable's sign-in is reported as `signInRequired`.
///
/// Video: schools on Teachable's own hosting serve lectures through Hotmart's
/// player. The lecture's attachment id buys a signed player address from the
/// school (`/api/v2/hotmart/private_video`), the player page names the HLS
/// playlist, and `HLSAudioDownloader` fetches the audio. Hotmart publishes no
/// captions for these videos (the playlists say `CLOSED-CAPTIONS=NONE`), so
/// the transcript comes from speech-to-text through `MeetingTranscriptionService`.
/// Older schools that still embed Wistia are named in the error rather than
/// half-handled.
enum TeachableCourseService {
    private static let logger = Logger(subsystem: "ForeverLM", category: "TeachableCourse")

    enum TeachableError: LocalizedError, Equatable {
        case signInRequired(host: String)
        case notALecturePage
        case noVideo(lecture: String)
        case unsupportedVideoHost(String)
        case videoUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .signInRequired(let host):
                return "Sign in to \(host) in ForeverLM’s browser (Library profile), then try again. ForeverLM reads Teachable with the sign-in made inside the app, not your web browser’s."
            case .notALecturePage:
                return "That page is not a Teachable lecture ForeverLM can read."
            case .noVideo(let lecture):
                return "“\(lecture)” has no video to transcribe."
            case .unsupportedVideoHost(let host):
                return "This lecture’s video is hosted by \(host), which ForeverLM does not transcribe yet."
            case .videoUnavailable(let detail):
                return "The lecture’s video could not be opened: \(detail)"
            }
        }
    }

    struct LectureLink: Equatable, Sendable {
        let id: String
        let url: URL
        let title: String
    }

    struct Section: Equatable, Sendable {
        let title: String
        let lectures: [LectureLink]
    }

    struct HotmartAttachment: Equatable, Sendable {
        let attachmentID: String
        let userID: String?
    }

    struct LecturePage: Equatable, Sendable {
        let url: URL
        let lectureID: String
        let courseID: String?
        let courseTitle: String?
        let title: String
        let sections: [Section]
        let hotmartVideos: [HotmartAttachment]
        let wistiaVideoIDs: [String]
        /// The lecture's text attachments as plain text: on a conference
        /// recording, the talk's title and its speakers.
        let textAttachments: [String]

        var hasVideo: Bool { !hotmartVideos.isEmpty || !wistiaVideoIDs.isEmpty }

        /// Every lecture in the outline, in course order.
        var allLectures: [LectureLink] { sections.flatMap(\.lectures) }
    }

    // MARK: - Recognising a lecture address

    /// `/courses/<slug or id>/lectures/<id>` on a Teachable school, whether on
    /// `*.teachable.com` or a school's own domain (the path is Teachable's).
    nonisolated static func isLectureURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased(),
              url.scheme?.lowercased().hasPrefix("http") == true else { return false }
        guard lectureID(inPath: url.path) != nil else { return false }
        return host == "teachable.com" || host.hasSuffix(".teachable.com") || isLecturePath(url.path)
    }

    nonisolated static func isLecturePath(_ path: String) -> Bool {
        path.range(of: #"^/courses/[^/]+/lectures/\d+/?$"#, options: .regularExpression) != nil
    }

    nonisolated static func lectureID(inPath path: String) -> String? {
        guard let match = path.range(of: #"/lectures/(\d+)"#, options: .regularExpression) else { return nil }
        return String(path[match].split(separator: "/").last ?? "")
    }

    /// The lecture address stripped to its identity: scheme, host and the
    /// `/courses/…/lectures/<id>` path, without query or fragment.
    nonisolated static func canonicalLectureURL(_ url: URL) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = url.host
        components.path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return components.url ?? url
    }

    // MARK: - Reading a lecture page

    /// Fetch and parse a lecture page as the learner signed in inside ForeverLM.
    static func fetchLecturePage(_ url: URL) async throws -> LecturePage {
        let host = url.host ?? "Teachable"
        let request = await SourceService.authenticatedBrowserRequest(for: url, timeout: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw TeachableError.signInRequired(host: host)
        }
        if isSignInAddress(finalURL) { throw TeachableError.signInRequired(host: host) }
        guard let html = String(data: data, encoding: .utf8) else { throw TeachableError.notALecturePage }
        do {
            return try parseLecturePage(html: html, url: canonicalLectureURL(finalURL))
        } catch TeachableError.notALecturePage where html.contains("sign_in") || html.contains("sso.teachable.com") {
            throw TeachableError.signInRequired(host: host)
        }
    }

    nonisolated static func isSignInAddress(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host.hasPrefix("sso.") || path.contains("/sign_in") || path.contains("/login")
            || path.hasPrefix("/secure/")
    }

    /// Parse a lecture page's markup. Throws `notALecturePage` when the page has
    /// no lecture heading, which is what a sign-in or sales page looks like.
    nonisolated static func parseLecturePage(html: String, url: URL) throws -> LecturePage {
        guard let headingTag = firstMatch(#"<h2[^>]*id=["']lecture_heading["'][^>]*>"#, in: html),
              let headingRange = html.range(of: headingTag) else {
            throw TeachableError.notALecturePage
        }
        let afterHeading = html[headingRange.upperBound...]
        let headingInner = afterHeading.range(of: "</h2>").map { String(afterHeading[..<$0.lowerBound]) } ?? ""
        let title = plainText(headingInner)
        guard !title.isEmpty else { throw TeachableError.notALecturePage }

        let lectureID = attribute("data-lecture-id", in: headingTag)
            ?? lectureID(inPath: url.path)
            ?? ""

        let hotmart = tags(containing: "hotmart_video_player", named: "div", in: html).compactMap { tag -> HotmartAttachment? in
            guard let id = attribute("data-attachment-id", in: tag) else { return nil }
            return HotmartAttachment(attachmentID: id, userID: attribute("data-user-id", in: tag))
        }
        let courseID = tags(containing: "hotmart_video_player", named: "div", in: html)
            .compactMap { attribute("data-course-id", in: $0) }.first
            ?? attribute("data-lecture-url", in: headingTag).flatMap { courseIDFromLecturePath($0) }
        let wistia = allMatches(#"data-wistia-id=["']([A-Za-z0-9]+)["']"#, in: html)

        var courseTitle: String?
        if let head = html.range(of: "course-sidebar-head") {
            let rest = html[head.upperBound...]
            if let open = rest.range(of: "<h2"), let close = rest.range(of: "</h2>", range: open.upperBound..<rest.endIndex),
               let tagEnd = rest.range(of: ">", range: open.upperBound..<close.lowerBound) {
                let text = plainText(String(rest[tagEnd.upperBound..<close.lowerBound]))
                courseTitle = text.isEmpty ? nil : text
            }
        }

        return LecturePage(
            url: url,
            lectureID: lectureID,
            courseID: courseID,
            courseTitle: courseTitle,
            title: title,
            sections: parseSections(html: html, pageURL: url),
            hotmartVideos: hotmart,
            wistiaVideoIDs: wistia,
            textAttachments: parseTextAttachments(html: html)
        )
    }

    /// The course outline in the sidebar: each `.course-section` with its
    /// `.section-title` and its `li.section-item` lectures.
    nonisolated static func parseSections(html: String, pageURL: URL) -> [Section] {
        let marker = #"<div[^>]*class=["'][^"']*\bcourse-section\b[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: marker) else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        let starts = regex.matches(in: html, range: whole).compactMap { Range($0.range, in: html)?.lowerBound }
        var sections: [Section] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : html.endIndex
            let block = String(html[start..<end])
            var sectionTitle = ""
            if let titleTag = firstMatch(#"<div[^>]*class=["'][^"']*\bsection-title\b[^"']*["'][^>]*>"#, in: block),
               let titleRange = block.range(of: titleTag) {
                let rest = block[titleRange.upperBound...]
                let inner = rest.range(of: "</div>").map { String(rest[..<$0.lowerBound]) } ?? ""
                sectionTitle = plainText(inner)
            }
            var lectures: [LectureLink] = []
            for item in tags(containing: "section-item", named: "li", in: block) {
                guard let id = attribute("data-lecture-id", in: item) else { continue }
                let path = attribute("data-lecture-url", in: item) ?? "/courses/\(pageURL.pathComponents.dropFirst(2).first ?? "")/lectures/\(id)"
                guard let url = URL(string: path, relativeTo: pageURL)?.absoluteURL else { continue }
                var name = ""
                if let itemRange = block.range(of: item) {
                    let rest = block[itemRange.upperBound...]
                    let itemBody = rest.range(of: "</li>").map { String(rest[..<$0.lowerBound]) } ?? ""
                    if let nameTag = firstMatch(#"<span[^>]*class=["'][^"']*\blecture-name\b[^"']*["'][^>]*>"#, in: itemBody),
                       let nameRange = itemBody.range(of: nameTag) {
                        let after = itemBody[nameRange.upperBound...]
                        name = removingTrailingDuration(
                            plainText(after.range(of: "</span>").map { String(after[..<$0.lowerBound]) } ?? "")
                        )
                    }
                }
                lectures.append(LectureLink(id: id, url: canonicalLectureURL(url), title: name))
            }
            if !lectures.isEmpty {
                sections.append(Section(title: sectionTitle, lectures: lectures))
            }
        }
        return sections
    }

    /// The outline prints a video lecture's running time after its name,
    /// "Acute Care (43:58)"; the time is the player's, not the title's.
    nonisolated static func removingTrailingDuration(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"\s*\(\d{1,2}(:\d{2}){1,2}\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    nonisolated static func parseTextAttachments(html: String) -> [String] {
        let pattern = #"<div[^>]*class=["'][^"']*\blecture-text-container\b[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: whole).compactMap { match -> String? in
            guard let range = Range(match.range, in: html) else { return nil }
            let rest = html[range.upperBound...]
            // Text containers hold paragraphs and lists, not nested blocks; the
            // attachment ends where its container's div does.
            let inner = rest.range(of: "</div>").map { String(rest[..<$0.lowerBound]) } ?? ""
            let text = plainTextKeepingLines(inner)
            return text.isEmpty ? nil : text
        }
    }

    nonisolated static func courseIDFromLecturePath(_ path: String) -> String? {
        guard let match = path.range(of: #"/courses/(\d+)/lectures/"#, options: .regularExpression) else { return nil }
        return path[match].split(separator: "/").dropFirst().first.map(String.init)
    }

    // MARK: - Video

    /// Download the lecture's audio and transcribe it. The text attachments
    /// (talk title, speakers) lead the transcript so a reader knows whose
    /// words these are.
    static func transcribe(_ page: LecturePage) async throws -> String {
        guard let video = page.hotmartVideos.first else {
            if !page.wistiaVideoIDs.isEmpty { throw TeachableError.unsupportedVideoHost("Wistia") }
            throw TeachableError.noVideo(lecture: page.title)
        }
        let playlist = try await hotmartPlaylistURL(for: video, lectureURL: page.url)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teachable-\(page.lectureID)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let lectureID = page.lectureID
        let audio = try await HLSAudioDownloader.downloadAudio(
            from: playlist,
            into: workDir,
            headers: hotmartCDNHeaders
        ) { finished, total in
            if finished == total || finished % 60 == 0 {
                logger.info("Teachable lecture \(lectureID, privacy: .public): \(finished)/\(total) segments")
            }
        }
        let spoken = try await MeetingTranscriptionService.shared.transcribe(
            localMediaURL: audio,
            task: "course_video_transcription"
        )
        return transcriptDocument(page: page, spoken: spoken)
    }

    nonisolated static func transcriptDocument(page: LecturePage, spoken: String) -> String {
        let header = page.textAttachments.joined(separator: "\n\n")
        guard !header.isEmpty else { return spoken }
        return header + "\n\n---\n\n" + spoken
    }

    /// Hotmart's CDN answers the playlist only for its own player's origin.
    nonisolated static let hotmartCDNHeaders: [String: String] = [
        "Referer": "https://player.hotmart.com/",
        "Origin": "https://player.hotmart.com",
        "User-Agent": SharedWebKit.desktopSafariUserAgent,
    ]

    /// The school signs a player address for this learner, and the player page
    /// names the stream.
    static func hotmartPlaylistURL(for video: HotmartAttachment, lectureURL: URL) async throws -> URL {
        guard let host = lectureURL.host else { throw TeachableError.notALecturePage }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v2/hotmart/private_video"
        components.queryItems = [URLQueryItem(name: "attachment_id", value: video.attachmentID)]
        guard let apiURL = components.url else { throw TeachableError.notALecturePage }

        var request = await SourceService.authenticatedBrowserRequest(for: apiURL, timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(lectureURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 || isSignInAddress(http.url ?? apiURL) {
                throw TeachableError.signInRequired(host: host)
            }
            guard (200...299).contains(http.statusCode) else {
                throw TeachableError.videoUnavailable("the school answered HTTP \(http.statusCode)")
            }
        }
        let grant = try hotmartGrant(fromJSON: data)

        var embed = URLComponents()
        embed.scheme = "https"
        embed.host = "player.hotmart.com"
        embed.path = "/embed/\(grant.videoID)"
        embed.queryItems = [
            URLQueryItem(name: "signature", value: grant.signature),
            URLQueryItem(name: "token", value: grant.token),
        ] + (video.userID.map { [URLQueryItem(name: "user", value: $0)] } ?? [])
        guard let embedURL = embed.url else { throw TeachableError.videoUnavailable("the player address was malformed") }
        var embedRequest = SourceService.browserRequest(for: embedURL, timeout: 30)
        embedRequest.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        embedRequest.setValue("iframe", forHTTPHeaderField: "Sec-Fetch-Dest")
        embedRequest.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        let (embedData, embedResponse) = try await URLSession.shared.data(for: embedRequest)
        if let http = embedResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TeachableError.videoUnavailable("the player answered HTTP \(http.statusCode)")
        }
        guard let html = String(data: embedData, encoding: .utf8),
              let playlist = hotmartPlaylistURL(fromPlayerHTML: html) else {
            throw TeachableError.videoUnavailable("the player page named no stream")
        }
        return playlist
    }

    struct HotmartGrant: Equatable {
        let videoID: String
        let signature: String
        let token: String
    }

    nonisolated static func hotmartGrant(fromJSON data: Data) throws -> HotmartGrant {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videoID = object["video_id"] as? String, !videoID.isEmpty,
              let signature = object["signature"] as? String, !signature.isEmpty,
              let token = object["teachable_application_key"] as? String, !token.isEmpty else {
            throw TeachableError.videoUnavailable("the school did not grant a player for this video")
        }
        return HotmartGrant(videoID: videoID, signature: signature, token: token)
    }

    /// The player page is a Next.js page whose `__NEXT_DATA__` lists the
    /// stream's `mediaAssets`, one playlist per picture height. The smallest
    /// is taken: only its audio is used.
    nonisolated static func hotmartPlaylistURL(fromPlayerHTML html: String) -> URL? {
        guard let open = firstMatch(#"<script[^>]*id=["']__NEXT_DATA__["'][^>]*>"#, in: html),
              let openRange = html.range(of: open) else { return nil }
        let rest = html[openRange.upperBound...]
        guard let close = rest.range(of: "</script>"),
              let data = String(rest[..<close.lowerBound]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let assets = firstArray(named: "mediaAssets", in: root) else { return nil }
        let playlists = assets.compactMap { $0 as? [String: Any] }.filter {
            ($0["contentType"] as? String)?.lowercased().contains("mpegurl") == true
        }
        let chosen = playlists.min { lhs, rhs in
            (lhs["height"] as? Int ?? .max) < (rhs["height"] as? Int ?? .max)
        }
        return (chosen?["url"] as? String).flatMap(URL.init(string:))
    }

    private nonisolated static func firstArray(named key: String, in value: Any) -> [Any]? {
        if let dictionary = value as? [String: Any] {
            if let array = dictionary[key] as? [Any] { return array }
            for child in dictionary.values {
                if let found = firstArray(named: key, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstArray(named: key, in: child) { return found }
            }
        }
        return nil
    }

    // MARK: - Markup helpers

    nonisolated static func plainText(_ html: String) -> String {
        JournalFeedParser.plainText(fromHTML: html)
    }

    /// Plain text with paragraph, list-item and line breaks kept as lines.
    nonisolated static func plainTextKeepingLines(_ html: String) -> String {
        let broken = html.replacingOccurrences(
            of: #"(?i)<br\s*/?>|</p>|</li>|</h[1-6]>"#,
            with: "\n",
            options: .regularExpression
        )
        return broken
            .components(separatedBy: "\n")
            .map { JournalFeedParser.plainText(fromHTML: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) {
                return JournalFeedParser.decodeEntities(String(tag[range]))
            }
        }
        return nil
    }

    /// Opening tags of `name` whose markup contains `needle` (a class name).
    nonisolated static func tags(containing needle: String, named name: String, in html: String) -> [String] {
        let pattern = "<" + name + #"\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            let tag = String(html[range])
            return tag.contains(needle) ? tag : nil
        }
    }

    nonisolated static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    nonisolated static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
