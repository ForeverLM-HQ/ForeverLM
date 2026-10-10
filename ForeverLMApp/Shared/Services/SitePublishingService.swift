import Foundation
import OSLog

/// A site published from ForeverLM, as the publishing service reports it.
struct PublishedSiteStatus: Equatable, Sendable {
    let siteID: String
    let url: URL
    let slug: String
    let title: String
    let publishedAt: Date
    let updatedAt: Date
    let bytes: Int
    let filePaths: [String]
    var isCustomSlug: Bool = false
    /// The repository the files came from, when they came from one.
    var source: SitePublishingSource?
    var access: SitePublishingAccess?
}

/// Who may open a Site. A public Site needs no account. A private Site always
/// admits the Apple account that owns it; a team Site additionally carries
/// the accepted participants' normalized account emails. The server never
/// returns this list to an unauthenticated reader.
struct SitePublishingAccess: Equatable, Sendable {
    enum Visibility: String, Equatable, Sendable {
        case privateSite = "private"
        case publicSite = "public"
    }

    var teamID: String?
    var readers: [String]
    var visibility: Visibility = .privateSite

    var payload: [String: Any] {
        var object: [String: Any] = ["readers": readers, "visibility": visibility.rawValue]
        if let teamID, !teamID.isEmpty { object["team_id"] = teamID }
        return object
    }
}

/// Where a site's files were read from: a GitHub repository at a ref, under a
/// folder, at the commit the read saw. Stored with the site so a later publish
/// can say what changed and read the same place again.
struct SitePublishingSource: Equatable, Sendable {
    var repository: String
    var ref: String?
    var path: String?
    var commit: String?

    var payload: [String: Any] {
        var object: [String: Any] = ["repository": repository]
        if let ref, !ref.isEmpty { object["ref"] = ref }
        if let path, !path.isEmpty { object["path"] = path }
        if let commit, !commit.isEmpty { object["commit"] = commit }
        return object
    }

    init(repository: String, ref: String? = nil, path: String? = nil, commit: String? = nil) {
        self.repository = repository
        self.ref = ref
        self.path = path
        self.commit = commit
    }

    init?(payload: Any?) {
        guard let object = payload as? [String: Any], let repository = object["repository"] as? String else { return nil }
        self.init(repository: repository, ref: object["ref"] as? String, path: object["path"] as? String, commit: object["commit"] as? String)
    }
}

/// Publishes a folder of files as a site at sites.foreverlm.com, or takes it
/// down. The counterpart of `DocPublishing` for HTML: where a Doc's page is
/// rendered by the site from Markdown, a site is the author's files served as
/// written on a separate host under a CSP sandbox, so nothing in them can reach
/// foreverlm.com's cookies or another site's storage. The same managed
/// session names the owner, the same slug rules apply, and the address is
/// stable across updates. Spec: docs/docs-design.md → Sites.
enum SitePublishing {
    typealias Transport = DocPublishing.Transport

    static let baseURL = DocPublishing.baseURL
    static let sitesHost = LinkedPage.foreverlmSitesHost
    static let maxFiles = 200
    /// A file sent inline in the publish body.
    static let maxFileBytes = 2_000_000
    /// A file sent by its own streamed request (`SiteFile.upload`).
    static let maxUploadFileBytes = 50_000_000
    /// The inline files of one publish together.
    static let maxInlineBytes = 10_000_000
    /// The whole site, inline and uploaded files together.
    static let maxSiteBytes = 200_000_000
    /// A site kept in the library: its files travel between devices inside
    /// the record's CloudKit body asset, whose package is capped at
    /// `ArtifactBodyPackage.maxPackageBytes`; the rest is the text copy's room.
    static let maxLocalSiteBytes = ArtifactBodyPackage.maxPackageBytes - 3 * 1_024 * 1_024
    static let entryFile = SiteFilePath.entryFile

    /// The custom address a writer typed, as the site would store it, or nil
    /// when it cannot be one. A pasted sites.foreverlm.com address is reduced
    /// to its slug; the host's own reserved words are refused.
    static func normalizeCustomSlug(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: #"^(?:https?://)?sites\.foreverlm\.com/"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
            if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        }
        guard let slug = DocPublishing.normalizeCustomSlug(text), !reservedSlugs.contains(slug) else { return nil }
        return slug
    }

    static let reservedSlugs: Set<String> = [
        "api", "admin", "app", "assets", "cdn", "d", "docs", "foreverlm", "help", "index", "mail", "new", "preview",
        "share", "sites", "static", "status", "www",
    ]

    /// A file's path inside the site, as the site will store and serve it, or
    /// nil when it cannot be one. A leading `./` or `/` is forgiven.
    static func normalizePath(_ input: String) -> String? {
        SiteFilePath.normalize(input)
    }

    // MARK: - Calls

    /// Every site this account has published, keyed by site id.
    static func statuses(
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> [String: PublishedSiteStatus] {
        let (data, response) = try await send(method: "GET", path: "api/publish/sites", body: nil, sessionToken: sessionToken, transport: transport)
        let payload = try decodeObject(data, response: response)
        guard let rows = payload["published_sites"] as? [[String: Any]] else { throw DocPublishingError.malformedResponse }
        let statuses = try rows.map { try parseStatus($0) }
        return Dictionary(statuses.map { ($0.siteID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The status of one site, by id or (for this account's own) slug; nil
    /// when nothing is published under that name.
    static func status(
        site: String,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> PublishedSiteStatus? {
        let (data, response) = try await send(method: "GET", path: endpointPath(site: site), body: nil, sessionToken: sessionToken, transport: transport)
        let payload = try decodeObject(data, response: response)
        if payload["published"] as? Bool == false { return nil }
        return try parseStatus(payload, fallbackSiteID: site)
    }

    /// Publish the files as a site, or replace the files of the site that
    /// already has this id. The address is stable across updates unless `slug`
    /// asks for a new one: then the site moves there and its old address
    /// forwards. Files marked `upload` are declared in the publish and then
    /// sent one by one as raw bodies, so a paper's PDF never travels as base64
    /// inside JSON; the site is live between the two steps with those files
    /// still arriving, and a failed upload throws after the publish stood.
    static func publish(
        siteID: String,
        title: String,
        files: [SiteFile],
        slug: String? = nil,
        source: SitePublishingSource? = nil,
        access: SitePublishingAccess? = nil,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> PublishedSiteStatus {
        var payload: [String: Any] = ["title": title, "files": files.map(\.payload)]
        if let slug, !slug.isEmpty { payload["slug"] = slug }
        if let source { payload["source"] = source.payload }
        if let access { payload["access"] = access.payload }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await send(method: "PUT", path: endpointPath(site: siteID), body: body, sessionToken: sessionToken, transport: transport, timeout: 180)
        let status = try parseStatus(try decodeObject(data, response: response), fallbackSiteID: siteID)
        for file in files where file.upload {
            let (uploadData, uploadResponse) = try await send(
                method: "PUT",
                path: "\(endpointPath(site: status.siteID))/files/\(encodedPath(file.path))",
                body: file.data,
                sessionToken: sessionToken,
                transport: transport,
                contentType: "application/octet-stream",
                timeout: 600
            )
            _ = try decodeObject(uploadData, response: uploadResponse)
        }
        return status
    }

    /// One stored file of this account's site, as stored.
    static func readFile(
        site: String,
        path: String,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> (data: Data, contentType: String) {
        let (data, response) = try await send(method: "GET", path: "\(endpointPath(site: site))/files/\(encodedPath(path))", body: nil, sessionToken: sessionToken, transport: transport)
        guard (200..<300).contains(response.statusCode) else {
            _ = try decodeObject(data, response: response)
            throw DocPublishingError.malformedResponse
        }
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
        return (data, type)
    }

    /// Change who may open a Site without republishing its files. Team roster
    /// refresh uses this so removing a participant rotates the live Site
    /// sessions immediately.
    static func updateAccess(
        site: String,
        access: SitePublishingAccess,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> PublishedSiteStatus {
        let body = try JSONSerialization.data(withJSONObject: ["access": access.payload])
        let (data, response) = try await send(method: "PATCH", path: endpointPath(site: site), body: body, sessionToken: sessionToken, transport: transport)
        return try parseStatus(try decodeObject(data, response: response), fallbackSiteID: site)
    }

    /// Take the site down. A site that was not published is not an error.
    static func unpublish(
        site: String,
        sessionToken: String? = ManagedAI.requestSessionToken,
        transport: Transport = DocPublishing.urlSessionTransport
    ) async throws -> Bool {
        let (data, response) = try await send(method: "DELETE", path: endpointPath(site: site), body: nil, sessionToken: sessionToken, transport: transport)
        let payload = try decodeObject(data, response: response)
        return payload["was_published"] as? Bool ?? false
    }

    // MARK: - Wire

    static func endpointPath(site: String) -> String {
        "api/publish/sites/\(site.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? site)"
    }

    static func encodedPath(_ path: String) -> String {
        path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
    }

    private static func send(
        method: String,
        path: String,
        body: Data?,
        sessionToken: String?,
        transport: Transport,
        contentType: String = "application/json",
        timeout: TimeInterval = 60
    ) async throws -> (Data, HTTPURLResponse) {
        guard let sessionToken, !sessionToken.isEmpty else { throw DocPublishingError.signedOut }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw DocPublishingError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return try await transport(request)
    }

    private static func decodeObject(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            let code = object?["error"] as? String ?? "http_\(response.statusCode)"
            if response.statusCode == 401 { throw DocPublishingError.signedOut }
            let message = object?["error_description"] as? String
                ?? "foreverlm.com answered \(response.statusCode) while publishing the site."
            throw DocPublishingError.server(status: response.statusCode, code: code, message: message)
        }
        guard let object else { throw DocPublishingError.malformedResponse }
        return object
    }

    private static func parseStatus(_ payload: [String: Any], fallbackSiteID: String? = nil) throws -> PublishedSiteStatus {
        guard let urlString = payload["url"] as? String, let url = URL(string: urlString),
              let slug = payload["slug"] as? String,
              let publishedAt = date(payload["published_at"]),
              let updatedAt = date(payload["updated_at"]),
              let siteID = (payload["site_id"] as? String) ?? fallbackSiteID,
              !siteID.isEmpty else {
            throw DocPublishingError.malformedResponse
        }
        return PublishedSiteStatus(
            siteID: siteID,
            url: url,
            slug: slug,
            title: payload["title"] as? String ?? "",
            publishedAt: publishedAt,
            updatedAt: updatedAt,
            bytes: payload["bytes"] as? Int ?? 0,
            filePaths: payload["file_paths"] as? [String] ?? [],
            isCustomSlug: payload["custom_slug"] as? Bool ?? false,
            source: SitePublishingSource(payload: payload["source"]),
            access: SitePublishingAccess(
                teamID: payload["team_id"] as? String,
                readers: payload["readers"] as? [String] ?? [],
                visibility: (payload["visibility"] as? String).flatMap(SitePublishingAccess.Visibility.init(rawValue:)) ?? .privateSite
            )
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: - The text copy

    /// The visible text of an HTML page, as the text copy a linked site keeps
    /// for chat: scripts, styles and tags dropped, entities decoded, block
    /// boundaries kept as line breaks. Good enough for a chat to know what a
    /// page says; the app refreshes it from the rendered page when the site is
    /// next opened.
    static func visibleText(ofHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "template", "svg", "head"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</?(p|div|h[1-6]|li|ul|ol|tr|td|th|section|article|header|footer|nav|main|aside|blockquote|pre|table|figure|figcaption|dt|dd|hr)\\b[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        return LinkedPage.normalizedText(lines.joined(separator: "\n"))
    }

    /// The named entities a page's text is likely to carry, decoded. The
    /// numeric forms (`&#8217;`, `&#x2019;`) are decoded by rule.
    static let namedEntities: [String: Character] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "copy": "\u{00A9}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "middot": "\u{00B7}", "bull": "\u{2022}", "times": "\u{00D7}", "deg": "\u{00B0}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var index = 0
        while index < chars.count {
            if chars[index] == "&", let (char, length) = decodeEntity(in: chars, at: index) {
                out.append(char)
                index += length
            } else {
                out.append(chars[index])
                index += 1
            }
        }
        return out
    }

    /// The character an entity at `index` stands for and how many source
    /// characters it spans, or nil when the `&` there begins no entity.
    static func decodeEntity(in chars: [Character], at index: Int) -> (Character, Int)? {
        guard index < chars.count, chars[index] == "&" else { return nil }
        var end = index + 1
        let limit = min(chars.count, index + 12)
        while end < limit, chars[end] != ";" {
            let char = chars[end]
            guard char.isLetter || char.isNumber || char == "#" else { return nil }
            end += 1
        }
        guard end < limit, chars[end] == ";", end > index + 1 else { return nil }
        let body = String(chars[(index + 1)..<end])
        let length = end - index + 1
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (Character(scalar), length)
        }
        guard let char = namedEntities[body] else { return nil }
        return (char, length)
    }

    /// The stored file a page address names: the path after the slug, the
    /// entry page for the site's root, and — for an address without an
    /// extension, which the host answers with `<path>/index.html` or
    /// `<path>.html` — whichever of those the site holds, the folder form
    /// first. `filePaths` is what the service lists for the site; with none
    /// known, the first candidate is the answer. Nil for an address that is
    /// not a page of this site.
    static func storedPath(forPage url: URL?, slug: String, filePaths: [String]) -> String? {
        guard let url, url.host?.lowercased() == sitesHost else { return nil }
        var segments = url.pathComponents.filter { $0 != "/" }
        guard segments.first?.lowercased() == slug.lowercased() else { return nil }
        segments.removeFirst()
        guard let path = normalizePath(segments.joined(separator: "/")) else { return entryFile }
        var candidates = [path]
        if !(segments.last ?? "").contains(".") {
            candidates = ["\(path)/\(entryFile)", "\(path).html", path]
        }
        guard !filePaths.isEmpty else { return candidates[0] }
        for candidate in candidates {
            if let stored = filePaths.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return stored }
        }
        return nil
    }
}

// MARK: - Changing a passage in place

/// Finds the words a learner selected on a rendered site page in the page's
/// HTML source and replaces exactly them, so the app's **Change** action and
/// `replace_site_text` never rewrite a page to change one line of it.
///
/// The selection arrives as the browser gave it — one line per block it
/// crossed, entities decoded, whitespace as rendered — and the source is the
/// author's file, with its indentation, entities and inline markup. The two
/// meet on the text runs between tags. Each run's text is entity-decoded and
/// whitespace-collapsed; runs separated only by inline tags (`em`, `a`,
/// `span`…) join into one *visible line*, and a block tag, a `br`, or a
/// script or style ends the line, as it ends a line on the screen. A
/// one-line selection matches anywhere inside one visible line, so a word in
/// a paragraph is found and only that word changes. A selection of several
/// lines — the kicker and the heading under it, in two sibling elements —
/// matches the same number of consecutive visible lines: the first as their
/// tail (a drag may start mid-line), the last as their head, the ones between
/// whole. Runs inside `script`, `style`, `title`, `noscript` and `template`,
/// comments and attribute values never match; none of them is text the
/// learner could have selected.
///
/// Exactly one match is required. None means the passage is not in this
/// file's source (drawn by a script, or changed since the page was opened);
/// several mean the selection is too short to name one place. Neither is
/// guessed at.
///
/// The replacement follows the selection's shape: with as many lines as the
/// selection, each visible line's matched text takes its line; otherwise the
/// first matched run takes the whole new text and the other matched runs are
/// emptied, their tags kept. `&`, `<` and `>` in the new text are encoded.
enum SiteTextEdit {
    enum Failure: Error, Equatable, LocalizedError {
        case emptySelection
        case notFound
        case ambiguous(Int)

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Select the text to change first."
            case .notFound:
                return "That passage was not found in the page's source."
            case .ambiguous(let count):
                return "That text appears \(count) times on the page; select a longer passage."
            }
        }
    }

    struct Change: Equatable {
        /// The file with the passage replaced.
        let html: String
        /// The passage as it was matched, lines joined by newlines.
        let found: String
        /// The new text as written into the file, before encoding.
        let replacement: String
    }

    /// Tags whose contents are not the page's text.
    static let rawTextTags: Set<String> = ["script", "style", "title", "noscript", "template", "textarea"]

    /// Tags that end a visible line, as they end one on the screen.
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "caption", "dd", "details", "dialog", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "legend", "li", "main", "nav", "ol", "option", "p", "pre", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "ul",
    ]

    /// The selection as lines: entities decoded, whitespace collapsed, each
    /// line trimmed, blank lines dropped.
    static func lines(of text: String) -> [String] {
        SitePublishing.decodeEntities(text)
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .map { collapsed(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Whitespace runs to one space, trimmed.
    static func collapsed(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for char in text {
            if char.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(char)
            }
        }
        return out
    }

    /// The new text as it goes into the file: the three characters that would
    /// start markup encoded, nothing else touched.
    static func encoded(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            default: out.append(char)
            }
        }
        return out
    }

    static func apply(find: String, replace: String, toHTML html: String) throws -> Change {
        let selection = lines(of: find)
        guard !selection.isEmpty else { throw Failure.emptySelection }
        let chars = Array(html)
        let visible = visibleLines(of: chars)
        let matches = matches(for: selection, in: visible)
        guard !matches.isEmpty else { throw Failure.notFound }
        guard matches.count == 1 else { throw Failure.ambiguous(matches.count) }
        let match = matches[0]

        let newLines = lines(of: replace)
        let perLine: [String]
        if newLines.count == selection.count {
            perLine = newLines
        } else {
            perLine = [newLines.joined(separator: "\n")] + Array(repeating: "", count: selection.count - 1)
        }

        // Each selection line's cells, grouped by the run they came from: the
        // first group takes the line's new text, the rest are emptied.
        var edits: [(range: Range<Int>, text: String)] = []
        for (lineIndex, span) in match.enumerated() {
            let cells = visible[span.line].cells[span.range]
            var groups: [(run: Int, range: Range<Int>)] = []
            for cell in cells {
                if let last = groups.last, last.run == cell.run {
                    groups[groups.count - 1].range = last.range.lowerBound..<cell.source.upperBound
                } else {
                    groups.append((cell.run, cell.source))
                }
            }
            for (groupIndex, group) in groups.enumerated() {
                edits.append((group.range, groupIndex == 0 ? encoded(perLine[lineIndex]) : ""))
            }
        }
        var output = chars
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(edit.range, with: Array(edit.text))
        }
        return Change(
            html: String(output),
            found: selection.joined(separator: "\n"),
            replacement: perLine.filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    // MARK: The source, as visible lines

    /// One character of a visible line: what it reads as, the run it came
    /// from and the source characters it stands for — an entity's whole
    /// spelling, a whitespace run's every character.
    struct Cell: Equatable {
        let char: Character
        let run: Int
        let source: Range<Int>
    }

    struct VisibleLine: Equatable {
        var cells: [Cell] = []
        var text: String { String(cells.map(\.char)) }
        /// The cells between the first and the last that are not spaces.
        var trimmedRange: Range<Int> {
            guard let first = cells.firstIndex(where: { $0.char != " " }),
                  let last = cells.lastIndex(where: { $0.char != " " }) else { return 0..<0 }
            return first..<(last + 1)
        }
    }

    /// The text of the page as the lines it draws, each remembering where its
    /// characters live in the source.
    static func visibleLines(of chars: [Character]) -> [VisibleLine] {
        var lines: [VisibleLine] = []
        var current = VisibleLine()
        var runCount = 0
        func closeLine() {
            if current.cells.contains(where: { $0.char != " " }) { lines.append(current) }
            current = VisibleLine()
        }
        func startsTag(at index: Int) -> Bool {
            guard index + 1 < chars.count, chars[index] == "<" else { return false }
            let next = chars[index + 1]
            return next.isLetter || next == "/" || next == "!" || next == "?"
        }
        func matches(_ word: String, at index: Int) -> Bool {
            let needle = Array(word)
            guard index + needle.count <= chars.count else { return false }
            for (offset, char) in needle.enumerated() where chars[index + offset].lowercased() != String(char) { return false }
            return true
        }
        func tagEnd(from index: Int) -> Int {
            var i = index
            var quote: Character? = nil
            while i < chars.count {
                let char = chars[i]
                if let open = quote {
                    if char == open { quote = nil }
                } else if char == "\"" || char == "'" {
                    quote = char
                } else if char == ">" {
                    return i
                }
                i += 1
            }
            return chars.count - 1
        }

        var index = 0
        while index < chars.count {
            if startsTag(at: index) {
                if matches("<!--", at: index) {
                    var end = index + 4
                    while end < chars.count, !matches("-->", at: end) { end += 1 }
                    index = min(chars.count, end + 3)
                    continue
                }
                if chars[index + 1] == "!" || chars[index + 1] == "?" {
                    index = tagEnd(from: index) + 1
                    continue
                }
                var nameStart = index + 1
                let closing = chars[nameStart] == "/"
                if closing { nameStart += 1 }
                var nameEnd = nameStart
                while nameEnd < chars.count, chars[nameEnd].isLetter || chars[nameEnd].isNumber || chars[nameEnd] == "-" || chars[nameEnd] == ":" {
                    nameEnd += 1
                }
                let name = String(chars[nameStart..<nameEnd]).lowercased()
                let end = tagEnd(from: index)
                if !closing, rawTextTags.contains(name), !(end > index && chars[end - 1] == "/") {
                    // Skip to the matching close tag; its contents are not text.
                    var close = end + 1
                    while close < chars.count {
                        if matches("</\(name)", at: close) {
                            let after = close + name.count + 2
                            if after >= chars.count || chars[after] == ">" || chars[after].isWhitespace { break }
                        }
                        close += 1
                    }
                    closeLine()
                    index = close < chars.count ? tagEnd(from: close) + 1 : chars.count
                    continue
                }
                if blockTags.contains(name) { closeLine() }
                index = end + 1
                continue
            }

            // A text run, up to the next tag.
            var end = index
            while end < chars.count, !startsTag(at: end) { end += 1 }
            let run = runCount
            runCount += 1
            var i = index
            while i < end {
                let char = chars[i]
                if char.isWhitespace {
                    var j = i
                    while j < end, chars[j].isWhitespace { j += 1 }
                    // One space, unless the line already ends in one or is
                    // empty; the source characters then stay as they are.
                    if let last = current.cells.last, last.char != " " {
                        current.cells.append(Cell(char: " ", run: run, source: i..<j))
                    }
                    i = j
                    continue
                }
                if char == "&", let (decoded, length) = SitePublishing.decodeEntity(in: chars, at: i) {
                    if decoded.isWhitespace {
                        if let last = current.cells.last, last.char != " " {
                            current.cells.append(Cell(char: " ", run: run, source: i..<(i + length)))
                        }
                    } else {
                        current.cells.append(Cell(char: decoded, run: run, source: i..<(i + length)))
                    }
                    i += length
                    continue
                }
                current.cells.append(Cell(char: char, run: run, source: i..<(i + 1)))
                i += 1
            }
            index = end
        }
        closeLine()
        return lines
    }

    // MARK: Matching

    /// Where a selection line's text sits in a visible line.
    struct Span: Equatable {
        let line: Int
        let range: Range<Int>
    }

    /// Every place the selection reads in the page: one span per selection
    /// line, on consecutive visible lines.
    static func matches(for selection: [String], in lines: [VisibleLine]) -> [[Span]] {
        var found: [[Span]] = []
        if selection.count == 1 {
            let needle = Array(selection[0])
            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmedRange
                let hay = Array(line.cells[trimmed].map(\.char))
                for start in occurrences(of: needle, in: hay) {
                    let from = trimmed.lowerBound + start
                    found.append([Span(line: lineIndex, range: from..<(from + needle.count))])
                }
            }
            return found
        }
        guard lines.count >= selection.count else { return [] }
        for start in 0...(lines.count - selection.count) {
            var spans: [Span] = []
            for (offset, wanted) in selection.enumerated() {
                let line = lines[start + offset]
                let trimmed = line.trimmedRange
                let text = Array(line.cells[trimmed].map(\.char))
                let needle = Array(wanted)
                let range: Range<Int>?
                if offset == 0 {
                    range = text.count >= needle.count && Array(text.suffix(needle.count)) == needle
                        ? (trimmed.upperBound - needle.count)..<trimmed.upperBound : nil
                } else if offset == selection.count - 1 {
                    range = text.count >= needle.count && Array(text.prefix(needle.count)) == needle
                        ? trimmed.lowerBound..<(trimmed.lowerBound + needle.count) : nil
                } else {
                    range = text == needle ? trimmed : nil
                }
                guard let range else { break }
                spans.append(Span(line: start + offset, range: range))
            }
            if spans.count == selection.count { found.append(spans) }
        }
        return found
    }

    /// Every start of `needle` in `hay`, overlapping ones included.
    static func occurrences(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var starts: [Int] = []
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            var matched = true
            for offset in 1..<needle.count where hay[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { starts.append(start) }
        }
        return starts
    }
}

// MARK: - Bringing hosted sites home

/// Until 2026-09-22 a ForeverLM site or animation lived only on
/// sites.foreverlm.com: the library kept a link, and the files were the
/// hosted copy. The product owner: "data should stay in the user's icloud in general"
/// — and hosting costs money per site. Now a site's files live in the library
/// (`StorageService.saveLocalSite`) and publishing is an explicit copy.
///
/// This brings one of the old records home: every file the service holds is
/// read back, saved into the library under the same record, the team copies
/// take the files too, and only then is the hosted copy taken down ("copy,
/// then take down"). The published PDFs under `foreverlm/sources/` are the
/// library's own papers, attached at publish time, and are not copied. A
/// failure anywhere before the take-down leaves the hosted copy standing and
/// the record as it was, so the next pass tries again.
enum HostedSiteAdoption {
    typealias StatusReader = @Sendable (String) async throws -> PublishedSiteStatus?
    typealias FileReader = @Sendable (String, String) async throws -> (data: Data, contentType: String)
    typealias Unpublisher = @Sendable (String) async throws -> Bool

    enum Outcome: Equatable {
        /// Brought home; the hosted copy was taken down (never in Dev).
        case adopted(ArtifactRecord)
        /// The service holds nothing under the record's address for this
        /// account: nothing to read back. The record is left alone.
        case notHosted
    }

    static let defaultsKey = "HostedSiteAdoption.completed.v1"

    /// Only the production app takes a hosted copy down. ForeverLM Dev signs
    /// in as the same account over a cloned library, so a Dev pass that took
    /// the copy down would leave the production library's record pointing at
    /// nothing; Dev copies the files and leaves the host alone.
    static var takesDownHostedCopy: Bool { !ForeverLMRuntimeIdentity.isDevelopment }

    /// The hosted slug of a record still pointing at sites.foreverlm.com.
    static func hostedSlug(of artifact: ArtifactRecord) -> String? {
        artifact.linkedURL.flatMap(URL.init(string:)).flatMap(LinkedPage.foreverlmSiteSlug(from:))
    }

    /// Whether the launch pass brings the record home. Team rows are left to
    /// the site tools, which bring one home when its owner changes it
    /// (`MCPDataStore.bringSiteHomeIfHosted`): a background pass should not
    /// take down a page the whole team reads.
    static func needsAdoption(_ artifact: ArtifactRecord) -> Bool {
        artifact.teamID == nil && hostedSlug(of: artifact) != nil
    }

    static func bringHome(
        _ artifact: ArtifactRecord,
        storage: StorageService,
        status: StatusReader = { try await SitePublishing.status(site: $0) },
        readFile: FileReader = { try await SitePublishing.readFile(site: $0, path: $1) },
        unpublish: Unpublisher = { try await SitePublishing.unpublish(site: $0) }
    ) async throws -> Outcome {
        guard let slug = hostedSlug(of: artifact) else { return .notHosted }
        guard let current = try await status(slug) else { return .notHosted }
        // A link to the published copy of a site this library already keeps
        // is not a hosted site to bring home: taking it down would unpublish
        // the other record.
        if current.siteID != artifact.id,
           let other = try? await storage.loadArtifact(current.siteID),
           LinkedPage.localSiteID(fromURLString: other.linkedURL) != nil {
            return .notHosted
        }
        // A team row (made before build 114) is brought home in place, into
        // the team's zone, so the files reach every member with the record.
        // The hosted copy answering under this account says we published it;
        // writing the team's record still needs a team we can edit.
        if let teamID = artifact.teamID {
            guard let team = try await storage.loadTeam(teamID), team.canEdit else {
                throw KnowledgeStoreError.invalidData("‘\(artifact.title)’ belongs to a team that is read-only for you, so its files cannot be brought into the team's library from here; the hosted copy stays up.")
            }
        }
        var files: [SiteFile] = []
        for path in current.filePaths where !path.hasPrefix(SiteSourceCards.sourceFolder + "/") {
            let stored = try await readFile(slug, path)
            files.append(SiteFile(path: path, data: stored.data))
        }
        guard files.contains(where: { $0.path == SitePublishing.entryFile }) else {
            throw KnowledgeStoreError.invalidData("\(current.url.absoluteString) has no \(SitePublishing.entryFile) to bring home.")
        }
        // The copy chat already reads, or — for a record whose copy was never
        // made — the entry page's visible text.
        let existingCopy = (try? await storage.artifactMarkdown(artifact.id).markdown) ?? ""
        let textCopy = existingCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SitePublishing.visibleText(
                ofHTML: files.first { $0.path == SitePublishing.entryFile }.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            )
            : existingCopy
        let saved = try await storage.saveLocalSite(
            artifactID: artifact.id,
            title: artifact.title,
            files: files,
            textCopy: textCopy
        )
        // Verify what landed before the only copy elsewhere goes away.
        let landed = try await storage.localSiteFiles(artifactID: saved.id) ?? []
        guard Set(landed.map(\.path)) == Set(files.map(\.path)),
              landed.reduce(0, { $0 + $1.data.count }) == files.reduce(0, { $0 + $1.data.count }) else {
            throw KnowledgeStoreError.invalidData("\(artifact.title)'s files did not all land in the library; the hosted copy stays up.")
        }
        for team in try await storage.teamsHoldingArtifact(saved.id) {
            _ = try await storage.shareArtifact(saved.id, withTeam: team.id)
        }
        if takesDownHostedCopy {
            _ = try await unpublish(slug)
        }
        return .adopted(saved)
    }

    /// One pass over the library, once per account: every own record still
    /// pointing at sites.foreverlm.com is brought home. Runs on the Mac that
    /// published the sites (only its account can read them back); every other
    /// device receives the files through CloudKit. The marker is written only
    /// after a pass that leaves nothing behind, so an offline or failed pass
    /// tries again next time.
    /// Returns whether any record was brought home, so the caller can reload.
    @discardableResult
    static func runIfNeeded(storage: StorageService, defaults: UserDefaults = .standard) async -> Bool {
        guard ManagedAI.isSignedIn, !defaults.bool(forKey: defaultsKey) else { return false }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SitePublishing")
        guard let artifacts = try? await storage.loadArtifacts(notebookID: nil) else { return false }
        var remaining = 0
        var adoptedAny = false
        for artifact in artifacts where needsAdoption(artifact) {
            do {
                switch try await bringHome(artifact, storage: storage) {
                case .adopted:
                    adoptedAny = true
                    logger.info("Brought site \(artifact.id, privacy: .public) home from sites.foreverlm.com")
                case .notHosted:
                    logger.info("Site \(artifact.id, privacy: .public) is not hosted under this account; left as a link")
                }
            } catch {
                remaining += 1
                logger.error("Site \(artifact.id, privacy: .public) stays hosted for now: \(error.localizedDescription, privacy: .public)")
            }
        }
        if remaining == 0 { defaults.set(true, forKey: defaultsKey) }
        return adoptedAny
    }
}
