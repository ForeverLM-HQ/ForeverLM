import Foundation
import OSLog

/// Gemini Notebook (called NotebookLM until July 2026): reading one of the
/// learner's notebooks as the signed-in learner, so its sources, its chats
/// and its notes can come into the library (`StudioViewModel+GeminiNotebook`).
///
/// Google publishes no API a consumer account can use; the documented one is
/// Gemini Enterprise's. The notebook page talks to its server through
/// Google's `batchexecute` endpoint instead: each call names an RPC id and a
/// positional JSON array of parameters, and is answered with positional
/// arrays. That is a protocol of its own rather than a web page, so it gets
/// its own reader here and not a branch in the article pipeline (AGENTS.md,
/// "Fix root causes"). Everything read is structure — ids, positions, type
/// codes, timestamps — never meaning parsed out of prose.
///
/// Access is the learner's own, as Teachable's is: requests carry the cookies
/// of the Google sign-in made inside ForeverLM (the Browser pane's Library
/// profile, or the sign-in a linked Google Doc asked for), and nothing else. A
/// notebook page that comes back as Google's sign-in is `signInRequired`.
///
/// The RPC ids and positions are the ones the page's own script sends, as
/// the MIT-licensed community client `jacob-bd/gemini-notebook-mcp-cli`
/// documents them. Google can change them without notice,
/// so an answer that no longer carries the call ForeverLM made is reported as
/// `changed`, naming the call, and nothing is filed from a notebook that was
/// only half read.
enum GeminiNotebookService {
    private static let logger = Logger(subsystem: "ForeverLM", category: "GeminiNotebook")

    /// Where notebooks live since the rename.
    static let host = "notebook.google.com"
    /// The address before the rename, which still redirects.
    static let formerHost = "notebooklm.google.com"
    static let batchExecutePath = "/_/LabsTailwindUi/data/batchexecute"
    /// What the chat, the byline and the result call the product.
    static let productName = "Gemini Notebook"

    enum GeminiNotebookError: LocalizedError, Equatable {
        case notANotebookLink
        case signInRequired
        case unreadablePage
        case notFound
        case changed(call: String)
        case refused(call: String, code: Int)
        case chatTooLong(messagesRead: Int)

        var errorDescription: String? {
            switch self {
            case .notANotebookLink:
                return "That is not a Gemini Notebook link. Open the notebook and copy its address (notebook.google.com/notebook/…)."
            case .signInRequired:
                return "Sign in to Google in ForeverLM’s browser (Library profile), then try again. ForeverLM reads Gemini Notebook with the sign-in made inside the app, not your web browser’s."
            case .unreadablePage:
                return "Gemini Notebook’s page did not carry what ForeverLM needs to read the notebook."
            case .notFound:
                return "Gemini Notebook has no notebook at that address that this Google account can open."
            case .changed(let call):
                return "Gemini Notebook no longer answers the way ForeverLM reads it (\(call)), so nothing was imported."
            case .refused(let call, let code):
                if code == 7 { return "This Google account may not open that notebook (\(call))." }
                return "Gemini Notebook refused to \(call) (error \(code))."
            case .chatTooLong(let read):
                return "A chat in this notebook is longer than ForeverLM can read from Gemini Notebook (it stopped after \(read) messages), so nothing was imported rather than part of the chat."
            }
        }
    }

    // MARK: - What a notebook holds

    /// How a notebook source reaches the library.
    enum SourceRoute: Equatable, Sendable {
        /// A web page or a YouTube video with its own address: added through
        /// the source bar's route, so the app fetches and types it itself and
        /// a paper's address becomes a paper with its PDF.
        case address(String)
        /// A Google Doc: linked in Docs, as a pasted Google Doc link is.
        case googleDoc(documentID: String)
        /// Anything the notebook holds only as text — pasted text, an
        /// uploaded file, a PDF, Slides or Sheets, an audio file's
        /// transcript — kept as the notebook's text, word for word.
        case text(String)
        /// A source the notebook holds no text for (an image, a file still
        /// processing): nothing to bring.
        case empty
    }

    struct NotebookSource: Equatable, Sendable {
        let id: String
        let title: String
        /// Gemini Notebook's source type code (`SourceKind`).
        let kindCode: Int?
        let url: String?
        let driveDocumentID: String?
        var route: SourceRoute
    }

    /// Gemini Notebook's source type codes.
    enum SourceKind {
        static let googleDocs = 1
        static let pdf = 3
        static let pastedText = 4
        static let webPage = 5
        static let youtube = 9
    }

    struct NotebookChat: Sendable {
        let conversationID: String
        /// The learner's questions and Gemini's answers, oldest first.
        let messages: [ReviewTranscriptMessage]

        var startedAt: Date? { messages.compactMap(\.timestamp).min() }
        var endedAt: Date? { messages.compactMap(\.timestamp).max() }
        var hasLearnerMessage: Bool { messages.contains { $0.role == .learner } }
    }

    /// A saved note, or a written report from Studio: both become Docs.
    struct NotebookNote: Equatable, Sendable {
        let id: String
        let title: String
        let markdown: String
    }

    /// A Studio item ForeverLM does not bring in (an audio or video overview,
    /// flashcards, a quiz, a mind map, an app), named in the import's result
    /// so nothing leaves the notebook silently.
    struct StudioItem: Equatable, Sendable {
        let title: String
        let kind: String
    }

    struct NotebookExport: Sendable {
        let notebookID: String
        let title: String
        let sources: [NotebookSource]
        let chats: [NotebookChat]
        let notes: [NotebookNote]
        let leftBehind: [StudioItem]
    }

    // MARK: - Recognising a notebook address

    /// The notebook's id in its address, `/notebook/<uuid>` on either host,
    /// lowercased as Google writes it; nil for anything else. Takes what the
    /// source bar takes: a bare host without a scheme is read as https.
    nonisolated static func notebookID(in string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              url.scheme?.lowercased().hasPrefix("http") == true,
              let host = url.host?.lowercased(),
              host == Self.host || host == Self.formerHost else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "notebook",
              UUID(uuidString: parts[1]) != nil else { return nil }
        return parts[1].lowercased()
    }

    nonisolated static func isNotebookURL(_ string: String) -> Bool {
        notebookID(in: string) != nil
    }

    nonisolated static func notebookURL(id: String) -> URL {
        URL(string: "https://\(host)/notebook/\(id)")!
    }

    /// The address a text-only source is stored under: the notebook's, naming
    /// the source. It is the source's identity, so importing the notebook
    /// again finds the row it made the first time. The query is `source_id`,
    /// not `source`: `URLNormalizer` strips `source` as a tracking parameter,
    /// which made every text source of a notebook one row.
    nonisolated static func sourceAddress(notebookID: String, sourceID: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/notebook/\(notebookID)"
        components.queryItems = [URLQueryItem(name: "source_id", value: sourceID)]
        return components.string ?? "https://\(host)/notebook/\(notebookID)?source_id=\(sourceID)"
    }

    /// The route a source takes, from its type code and what the notebook
    /// records for it. `text` is filled in once the source's text is read.
    nonisolated static func route(kindCode: Int?, url: String?, driveDocumentID: String?) -> SourceRoute {
        let address = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWebAddress = address.lowercased().hasPrefix("https://") || address.lowercased().hasPrefix("http://")
        guard let kindCode else { return .text("") }
        switch kindCode {
        case SourceKind.webPage, SourceKind.youtube:
            // A web source that is itself a notebook's address is read as the
            // text this notebook holds: the source bar would import that
            // whole other notebook.
            if hasWebAddress, !isNotebookURL(address) { return .address(address) }
        case SourceKind.googleDocs:
            if let driveDocumentID, !driveDocumentID.isEmpty { return .googleDoc(documentID: driveDocumentID) }
        default:
            break
        }
        return .text("")
    }

    // MARK: - The page's own tokens

    /// What a notebook page carries for the calls it makes: the request
    /// token (`SNlM0e`, sent as `at`), the session (`FdrFJe`, `f.sid`) and
    /// the build (`cfb2h`, `bl`), all in the page's `WIZ_global_data`.
    struct PageTokens: Equatable, Sendable {
        let requestToken: String
        let sessionID: String?
        let buildLabel: String?
    }

    nonisolated static func pageTokens(inPage html: String) -> PageTokens? {
        guard let token = wizValue("SNlM0e", in: html), !token.isEmpty else { return nil }
        return PageTokens(
            requestToken: token,
            sessionID: wizValue("FdrFJe", in: html),
            buildLabel: wizValue("cfb2h", in: html)
        )
    }

    /// One `"KEY":"value"` pair of the page's configuration object, its value
    /// decoded as the JSON string it is.
    nonisolated static func wizValue(_ key: String, in html: String) -> String? {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + #"":"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let literal = "\"" + html[range] + "\""
        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
    }

    // MARK: - Calls

    /// The form one call is posted as: `f.req` holds `[[[rpc, params, null,
    /// "generic"]]]` with the parameters as JSON text inside it, and `at` the
    /// page's request token.
    nonisolated static func batchExecuteRequest(
        rpcID: String,
        parameters: [Any],
        notebookID: String,
        tokens: PageTokens
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = batchExecutePath
        var query = [
            URLQueryItem(name: "rpcids", value: rpcID),
            URLQueryItem(name: "source-path", value: "/notebook/\(notebookID)"),
        ]
        if let buildLabel = tokens.buildLabel, !buildLabel.isEmpty {
            query.append(URLQueryItem(name: "bl", value: buildLabel))
        }
        if let sessionID = tokens.sessionID, !sessionID.isEmpty {
            query.append(URLQueryItem(name: "f.sid", value: sessionID))
        }
        query.append(URLQueryItem(name: "hl", value: "en"))
        query.append(URLQueryItem(name: "rt", value: "c"))
        components.queryItems = query
        guard let url = components.url else { throw GeminiNotebookError.notANotebookLink }

        let parametersJSON = try compactJSON(parameters)
        let call: [Any] = [rpcID, parametersJSON, NSNull(), "generic"]
        let envelope = try compactJSON([[call]])
        let body = "f.req=\(formEncoded(envelope))&at=\(formEncoded(tokens.requestToken))&"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func compactJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Percent-encoding of everything but the unreserved characters, which is
    /// how the page encodes a form value.
    nonisolated static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The answer to one call in a `batchexecute` response. The response is
    /// `)]}'`, then chunks, each a length line and one JSON array; the call's
    /// answer is its `["wrb.fr", rpc, "<json>", …]` entry, whose third element
    /// is itself JSON text. An entry carrying an error code in its sixth
    /// element is the server refusing the call; 16 means signed out.
    nonisolated static func rpcResult(inResponse text: String, rpcID: String, call: String) throws -> Any? {
        var body = Substring(text)
        if body.hasPrefix(")]}'") { body = body.dropFirst(4) }
        var sawAnyEntry = false
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["),
                  let chunk = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] else { continue }
            for case let entry as [Any] in chunk {
                guard entry.count >= 3, entry[0] as? String == "wrb.fr" else { continue }
                sawAnyEntry = true
                guard entry[1] as? String == rpcID else { continue }
                if entry.count > 5, let error = entry[5] as? [Any], let code = error.first as? Int {
                    if code == 16 { throw GeminiNotebookError.signInRequired }
                    throw GeminiNotebookError.refused(call: call, code: code)
                }
                guard let payload = entry[2] as? String else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: .fragmentsAllowed)
            }
        }
        logger.error("batchexecute answer without \(rpcID, privacy: .public) (other entries: \(sawAnyEntry, privacy: .public))")
        throw GeminiNotebookError.changed(call: call)
    }

    // MARK: - Reading the answers

    /// `rLM1Ne`: the notebook's title at `[0]` and its sources at `[1]`, each
    /// `[[id], title, metadata, [null, status]]`. In a source's metadata the
    /// type code is at `[4]`, the address at `[7][0]` and a Google Doc's
    /// Drive id at `[0][0]`.
    nonisolated static func notebook(fromResult result: Any?) -> (title: String, sources: [NotebookSource])? {
        guard let outer = result as? [Any], !outer.isEmpty else { return nil }
        let data = (outer.first as? [Any]).flatMap { $0.first is String || $0.first is NSNull ? $0 : nil } ?? outer
        let title = (element(data, 0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var sources: [NotebookSource] = []
        for case let entry as [Any] in (element(data, 1) as? [Any]) ?? [] {
            guard let id = firstString(element(entry, 0)), !id.isEmpty else { continue }
            let sourceTitle = (element(entry, 1) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let metadata = element(entry, 2) as? [Any] ?? []
            let kindCode = element(metadata, 4) as? Int
            let url = firstString(element(metadata, 7))
            let driveID = kindCode == SourceKind.googleDocs ? firstString(element(metadata, 0)) : nil
            sources.append(NotebookSource(
                id: id,
                title: sourceTitle,
                kindCode: kindCode,
                url: url,
                driveDocumentID: driveID,
                route: route(kindCode: kindCode, url: url, driveDocumentID: driveID)
            ))
        }
        return (title, sources)
    }

    /// `hizoJc`: a source's indexed text, in content blocks at `[3][0]`, each
    /// `[start, end, content]` with its text somewhere inside `content`.
    /// Every piece of text is kept as the notebook holds it, a blank line
    /// between pieces, which is how the community client reads it.
    nonisolated static func sourceText(fromResult result: Any?) -> String {
        guard let blocks = element(element(result, 3), 0) as? [Any] else { return "" }
        var parts: [String] = []
        for case let block as [Any] in blocks {
            parts.append(contentsOf: strings(in: block).filter { !$0.isEmpty })
        }
        return parts.joined(separator: "\n\n")
    }

    /// `hPTbtc`: the notebook's conversation at `[0]`, as
    /// `[id, null, count]` or `[id]`; a list of such entries is read the same
    /// way, one conversation each.
    nonisolated static func conversationIDs(fromResult result: Any?) -> [String] {
        guard let list = element(result, 0) as? [Any] else { return [] }
        if let id = list.first as? String {
            return id.isEmpty ? [] : [id]
        }
        var ids: [String] = []
        for entry in list {
            if let id = firstString(entry), !id.isEmpty, !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    struct TurnPage: Equatable, Sendable {
        /// `(turn id, message)`, newest first as the server sends them.
        let turns: [(id: String, message: ReviewTranscriptMessage)]
        let continuation: String?

        static func == (lhs: TurnPage, rhs: TurnPage) -> Bool {
            lhs.continuation == rhs.continuation
                && lhs.turns.map(\.id) == rhs.turns.map(\.id)
                && lhs.turns.map(\.message.text) == rhs.turns.map(\.message.text)
        }
    }

    /// `khqZz`: one page of a conversation, `[turns, continuation]`, newest
    /// first. A question is `[id, [seconds, nanos], 1, text]`; an answer is
    /// `[id, [seconds, nanos], 2, null, [[text, …], …]]`.
    nonisolated static func turnPage(fromResult result: Any?) -> TurnPage {
        var turns: [(id: String, message: ReviewTranscriptMessage)] = []
        for case let entry as [Any] in (element(result, 0) as? [Any]) ?? [] {
            guard entry.count >= 3, let kind = entry[2] as? Int else { continue }
            let id = (entry[0] as? String) ?? firstString(entry[0]) ?? ""
            let timestamp = date(fromTimestamp: element(entry, 1))
            let text: String?
            let role: ReviewTranscriptRole
            switch kind {
            case 1:
                role = .learner
                text = element(entry, 3) as? String
            case 2:
                role = .assistant
                text = element(element(element(entry, 4), 0), 0) as? String
            default:
                continue
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            turns.append((id, ReviewTranscriptMessage(role: role, text: text, timestamp: timestamp)))
        }
        let continuation = (element(result, 1) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TurnPage(turns: turns, continuation: continuation)
    }

    /// `cFji9`: notes at `[0]`, each `[id, [id, content, metadata, null,
    /// title], status]`. A deleted note carries status 2 or no body; a mind
    /// map is a note whose body is JSON, and is not a note to read.
    nonisolated static func notes(fromResult result: Any?) -> (notes: [NotebookNote], mindMaps: [StudioItem]) {
        var notes: [NotebookNote] = []
        var mindMaps: [StudioItem] = []
        for case let entry as [Any] in (element(result, 0) as? [Any]) ?? [] {
            guard let id = entry.first as? String else { continue }
            if element(entry, 2) as? Int == 2 { continue }
            guard let body = element(entry, 1) as? [Any] else { continue }
            let content = element(body, 1) as? String ?? ""
            let title = (element(body, 4) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isJSONObject(content) {
                mindMaps.append(StudioItem(title: title, kind: "mind map"))
                continue
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            notes.append(NotebookNote(id: id, title: title, markdown: content))
        }
        return (notes, mindMaps)
    }

    /// Studio's item kinds, by type code.
    enum StudioKind {
        static let report = 2
        static let names: [Int: String] = [
            1: "audio overview",
            2: "report",
            3: "video overview",
            4: "flashcards or quiz",
            7: "infographic",
            8: "slide deck",
            9: "data table",
            10: "spreadsheet",
            11: "interactive report",
        ]
    }

    /// `gArtLc`: Studio's items at `[0]`, each `[id, title, type, …]`. A
    /// written report keeps its Markdown at `[7][1][0]` and becomes a Doc;
    /// every other item is named as left in the notebook.
    nonisolated static func studio(fromResult result: Any?) -> (reports: [NotebookNote], leftBehind: [StudioItem]) {
        var reports: [NotebookNote] = []
        var leftBehind: [StudioItem] = []
        for case let entry as [Any] in (element(result, 0) as? [Any]) ?? [] {
            guard entry.count >= 3, let id = entry[0] as? String else { continue }
            let title = (element(entry, 1) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = element(entry, 2) as? Int
            if kind == StudioKind.report,
               let markdown = element(element(element(entry, 7), 1), 0) as? String,
               !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reports.append(NotebookNote(id: id, title: title, markdown: markdown))
                continue
            }
            leftBehind.append(StudioItem(title: title, kind: kind.flatMap { StudioKind.names[$0] } ?? "Studio item"))
        }
        return (reports, leftBehind)
    }

    // MARK: - Reading a notebook

    /// A signed-in reading of one notebook: the page's tokens, then each call
    /// posted with the learner's in-app cookies.
    struct Session: Sendable {
        let notebookID: String
        let tokens: PageTokens

        func call(_ rpcID: String, _ parameters: [Any], named call: String) async throws -> Any? {
            var request = try GeminiNotebookService.batchExecuteRequest(
                rpcID: rpcID,
                parameters: parameters,
                notebookID: notebookID,
                tokens: tokens
            )
            if let url = request.url {
                InAppWebSession.apply(await InAppWebSession.cookies(for: url), to: &request)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 401 || status == 403 { throw GeminiNotebookError.signInRequired }
            if status == 404 { throw GeminiNotebookError.notFound }
            guard (200..<300).contains(status) else { throw GeminiNotebookError.refused(call: call, code: status) }
            return try GeminiNotebookService.rpcResult(
                inResponse: String(decoding: data, as: UTF8.self),
                rpcID: rpcID,
                call: call
            )
        }
    }

    /// Open the notebook's page as the learner and read its tokens.
    static func openSession(notebookID: String) async throws -> Session {
        let url = notebookURL(id: notebookID)
        let request = await SourceService.authenticatedBrowserRequest(for: url, timeout: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, status == 401 || status == 403 { throw GeminiNotebookError.signInRequired }
        if let finalHost = http?.url?.host?.lowercased(), finalHost == "accounts.google.com" || finalHost.hasSuffix(".accounts.google.com") {
            throw GeminiNotebookError.signInRequired
        }
        if http?.statusCode == 404 { throw GeminiNotebookError.notFound }
        let html = String(decoding: data, as: UTF8.self)
        guard let tokens = pageTokens(inPage: html) else {
            if html.contains("accounts.google.com/ServiceLogin") || html.contains("accounts.google.com/v3/signin") {
                throw GeminiNotebookError.signInRequired
            }
            throw GeminiNotebookError.unreadablePage
        }
        return Session(notebookID: notebookID, tokens: tokens)
    }

    /// How many turns one page of a conversation asks for. The page itself
    /// asks for 20 and fetches more as the learner scrolls; asking for many
    /// at once keeps a whole chat to one page wherever the server allows it.
    static let turnPageSize = 1000
    /// A conversation is read page by page while each page brings turns not
    /// seen before; this many pages is a stop against a server that never
    /// runs out.
    static let maximumTurnPages = 50

    /// Everything the import brings, read before anything is filed: the
    /// notebook and its sources (with the text of each source it holds only
    /// as text), every chat whole, the notes, and Studio's reports.
    static func readNotebook(id notebookID: String) async throws -> NotebookExport {
        let session = try await openSession(notebookID: notebookID)

        let notebookResult = try await session.call(
            "rLM1Ne", [notebookID, NSNull(), [2], NSNull(), 0], named: "read the notebook"
        )
        guard let listing = Self.notebook(fromResult: notebookResult) else {
            throw GeminiNotebookError.notFound
        }

        var sources: [NotebookSource] = []
        for var source in listing.sources {
            if case .text = source.route {
                let result = try await session.call(
                    "hizoJc", [[source.id], [2], [2]], named: "read the source “\(source.title)”"
                )
                let text = sourceText(fromResult: result)
                source.route = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .text(text)
            }
            sources.append(source)
        }

        let conversationsResult = try await session.call(
            "hPTbtc", [[] as [Any], NSNull(), notebookID, 20], named: "list the notebook’s chats"
        )
        var chats: [NotebookChat] = []
        for conversationID in conversationIDs(fromResult: conversationsResult) {
            let messages = try await readConversation(conversationID, session: session)
            guard !messages.isEmpty else { continue }
            chats.append(NotebookChat(conversationID: conversationID, messages: messages))
        }

        let notesResult = try await session.call("cFji9", [notebookID], named: "read the notebook’s notes")
        let noteRead = Self.notes(fromResult: notesResult)

        let studioResult = try await session.call(
            "gArtLc",
            [[2], notebookID, #"NOT artifact.status = "ARTIFACT_STATUS_SUGGESTED""#],
            named: "read the notebook’s Studio"
        )
        let studioRead = Self.studio(fromResult: studioResult)

        logger.info("Read notebook \(notebookID, privacy: .public): \(sources.count) sources, \(chats.count) chats, \(noteRead.notes.count + studioRead.reports.count) notes")
        return NotebookExport(
            notebookID: notebookID,
            title: listing.title,
            sources: sources,
            chats: chats,
            notes: noteRead.notes + studioRead.reports,
            leftBehind: noteRead.mindMaps + studioRead.leftBehind
        )
    }

    /// The first element of a `khqZz` request: the same client descriptor
    /// the page sends with it.
    nonisolated static var turnRequestDescriptor: [Any] {
        let options: [Any] = [1, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), [1, 3]]
        return [2, NSNull(), [1], options]
    }

    /// A whole conversation, oldest message first.
    ///
    /// The answer carries a continuation beside its turns, and where the
    /// page puts it back when it asks for older turns is not documented; it
    /// is sent in the request's third place, the one the page leaves null on
    /// its first ask. Pages are read while each brings turns not seen before,
    /// so a server that ignores it, or hands back a continuation with the
    /// last page, ends the reading instead of repeating it. A follow-up page
    /// the server refuses ends it too, and the log says how many messages
    /// were read in how many pages, so a chat that came in short can be told
    /// from one that was whole. Running out of pages while turns still come
    /// refuses the chat rather than importing part of it.
    static func readConversation(_ conversationID: String, session: Session) async throws -> [ReviewTranscriptMessage] {
        var seen = Set<String>()
        var newestFirst: [ReviewTranscriptMessage] = []
        var continuation: String?
        for pageNumber in 1...maximumTurnPages {
            let result: Any?
            do {
                result = try await session.call(
                    "khqZz",
                    [
                        Self.turnRequestDescriptor,
                        NSNull(),
                        continuation.map { $0 as Any } ?? NSNull(),
                        conversationID,
                        turnPageSize,
                    ],
                    named: "read a chat"
                )
            } catch GeminiNotebookError.refused(_, let code) where continuation != nil {
                logger.warning("Chat \(conversationID, privacy: .public): page \(pageNumber) refused (error \(code)) after \(newestFirst.count) messages")
                return newestFirst.reversed()
            }
            let page = turnPage(fromResult: result)
            let fresh = page.turns.filter { $0.id.isEmpty || seen.insert($0.id).inserted }
            newestFirst.append(contentsOf: fresh.map(\.message))
            guard let next = page.continuation, !fresh.isEmpty, next != continuation else {
                logger.info("Chat \(conversationID, privacy: .public): \(newestFirst.count) messages in \(pageNumber) page(s), continuation \(page.continuation == nil ? "none" : "present", privacy: .public)")
                return newestFirst.reversed()
            }
            continuation = next
        }
        throw GeminiNotebookError.chatTooLong(messagesRead: newestFirst.count)
    }

    // MARK: - Array helpers

    private nonisolated static func element(_ value: Any?, _ index: Int) -> Any? {
        guard let array = value as? [Any], array.indices.contains(index) else { return nil }
        let item = array[index]
        return item is NSNull ? nil : item
    }

    /// A string, or the first string of an array led by one (`[id]`).
    private nonisolated static func firstString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.first as? String }
        return nil
    }

    /// Every string inside a nested array, in order.
    private nonisolated static func strings(in value: [Any]) -> [String] {
        var found: [String] = []
        for item in value {
            if let string = item as? String {
                found.append(string)
            } else if let array = item as? [Any] {
                found.append(contentsOf: strings(in: array))
            }
        }
        return found
    }

    /// `[seconds, nanos]` since 1970.
    private nonisolated static func date(fromTimestamp value: Any?) -> Date? {
        guard let parts = value as? [Any], let seconds = parts.first as? NSNumber else { return nil }
        let nanos = (parts.count > 1 ? parts[1] as? NSNumber : nil)?.doubleValue ?? 0
        return Date(timeIntervalSince1970: seconds.doubleValue + nanos / 1_000_000_000)
    }

    private nonisolated static func isJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) is [String: Any]
    }
}
