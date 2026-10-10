import Foundation

// MARK: - Notion plugin: the live read

/// `search_notion`, `get_notion_page`, `list_notion_databases`,
/// `get_notion_database` and `query_notion_database` as the Mac answers them.
///
/// Over MCP these tools are executed by the gateway, because only the gateway
/// holds the learner's Notion grant. The Mac is an MCP *host*, so its in-app
/// chat sees the local catalog and never the gateway's additions; without these
/// twins a chat could not read Notion at all (Slack, Linear and GitHub carry
/// twins for exactly this reason, `MCPTools+SlackPlugin.swift`,
/// `MCPTools+LinearPlugin.swift` and `MCPTools+GitHubPlugin.swift`).
///
/// Each twin asks the gateway for the same read over a `GET /notion/…` route,
/// authenticated with the managed Sign in with Apple session, and the gateway
/// reads Notion as the learner with the same read-only connection the MCP
/// path uses. Nothing is stored: the page is read, returned to the chat, and
/// forgotten. There is no write here and none on the gateway: ForeverLM cannot
/// create, edit, move or comment on a page.
extension MCPDataStore {

    /// The gateway that reads Notion as the learner.
    static var notionGatewayBaseURL: URL {
        URL(string: "https://plugin.\(MCPBrandDomains.current)")!
    }

    /// How the session gets to Notion, in one line the learner can act on.
    private static let notionSignedOutMessage = "Sign in with Apple in ForeverLM to read Notion. ForeverLM reads Notion as you, through your own ForeverLM account, so a signed-out Mac has nothing to read with."

    private static func trimmedNotionArgument(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Page and database arguments

    /// A Notion id as the gateway's routes take it: the dashed UUID Notion
    /// writes in API paths. Accepts the id in either spelling (32 hex digits,
    /// dashed or not) or a Notion URL of the page or database, whose last path
    /// segment ends in the id (`?p=` names a peeked page). Notion moved its app
    /// from notion.so to notion.com, so a pasted link carries either domain,
    /// and notion.site serves published pages.
    /// `nil` when the text is none of these.
    static func parseNotionID(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = notionDashedID(text) { return id }

        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              isNotionHost(host)
        else { return nil }
        if let peeked = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "p" })?.value,
           let id = notionDashedID(peeked) {
            return id
        }
        guard let last = url.pathComponents.filter({ $0 != "/" }).last else { return nil }
        // The id is the trailing 32 hex digits (or dashed UUID) of the last
        // segment, after the title Notion prefixes it with.
        if last.count >= 32, let id = notionDashedID(String(last.suffix(32))) { return id }
        if last.count >= 36, let id = notionDashedID(String(last.suffix(36))) { return id }
        return nil
    }

    /// Whether a URL's host is one Notion serves pages from: notion.com (the
    /// app since Notion's move off notion.so), notion.so (still redirected),
    /// or notion.site (published pages), with or without a subdomain such as
    /// `www.` or `app.` or a workspace's own.
    private static func isNotionHost(_ host: String) -> Bool {
        ["notion.com", "notion.so", "notion.site"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// The dashed lowercase form of an id given as 32 hex digits or a UUID.
    private static func notionDashedID(_ value: String) -> String? {
        let lowered = value.lowercased()
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
        if lowered.count == 32, lowered.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) {
            let s = Array(lowered)
            return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
        }
        if lowered.count == 36, UUID(uuidString: lowered) != nil {
            return lowered
        }
        return nil
    }

    static func validatedNotionID(_ raw: String, what: String) throws -> String {
        guard let id = parseNotionID(raw) else {
            throw MCPError.invalidInput("\(what) must be a Notion id (32 hex digits, dashed or not) or a Notion URL of the \(what); call search_notion for the ids ForeverLM can read.")
        }
        return id
    }

    private static func validatedNotionKind(_ raw: String?) throws -> String? {
        guard let kind = trimmedNotionArgument(raw)?.lowercased() else { return nil }
        switch kind {
        case "page", "pages": return "page"
        case "database", "databases", "data_source": return "database"
        default: throw MCPError.invalidInput("kind must be page or database.")
        }
    }

    /// A filter or sorts argument, as the JSON text the gateway's query string
    /// carries. Accepts the object or array itself (a chat passes one) or JSON
    /// text; refuses anything else with a sentence before the round trip.
    private static func notionJSONArgument(_ value: Any?, name: String, array: Bool) throws -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  array ? parsed is [Any] : parsed is [String: Any]
            else {
                throw MCPError.invalidInput("\(name) must be \(array ? "an array" : "an object") in Notion's \(name) format.")
            }
            return trimmed
        }
        guard array ? value is [Any] : value is [String: Any],
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            throw MCPError.invalidInput("\(name) must be \(array ? "an array" : "an object") in Notion's \(name) format.")
        }
        return text
    }

    // MARK: The reads

    func searchNotion(query: String?, kind: String?, limit: Int?) async throws -> String {
        var items: [URLQueryItem] = []
        if let query = Self.trimmedNotionArgument(query) { items.append(URLQueryItem(name: "query", value: query)) }
        if let kind = try Self.validatedNotionKind(kind) { items.append(URLQueryItem(name: "kind", value: kind)) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.notionGatewayJSON(path: "/notion/search", query: items)
        return try jsonString(payload)
    }

    func getNotionPage(page rawPage: String, includeContent: Bool?) async throws -> String {
        let id = try Self.validatedNotionID(rawPage, what: "page")
        var items: [URLQueryItem] = []
        if includeContent == false { items.append(URLQueryItem(name: "include_content", value: "false")) }
        let payload = try await Self.notionGatewayJSON(path: "/notion/pages/\(id)", query: items)
        return try jsonString(payload)
    }

    func listNotionDatabases(query: String?, limit: Int?) async throws -> String {
        var items: [URLQueryItem] = []
        if let query = Self.trimmedNotionArgument(query) { items.append(URLQueryItem(name: "query", value: query)) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.notionGatewayJSON(path: "/notion/databases", query: items)
        return try jsonString(payload)
    }

    func getNotionDatabase(database rawDatabase: String) async throws -> String {
        let id = try Self.validatedNotionID(rawDatabase, what: "database")
        let payload = try await Self.notionGatewayJSON(path: "/notion/databases/\(id)")
        return try jsonString(payload)
    }

    func queryNotionDatabase(database rawDatabase: String, filter: Any?, sorts: Any?, limit: Int?, cursor: String?) async throws -> String {
        let id = try Self.validatedNotionID(rawDatabase, what: "database")
        var items: [URLQueryItem] = []
        if let filter = try Self.notionJSONArgument(filter, name: "filter", array: false) { items.append(URLQueryItem(name: "filter", value: filter)) }
        if let sorts = try Self.notionJSONArgument(sorts, name: "sorts", array: true) { items.append(URLQueryItem(name: "sorts", value: sorts)) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor = Self.trimmedNotionArgument(cursor) { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let payload = try await Self.notionGatewayJSON(path: "/notion/databases/\(id)/query", query: items)
        return try jsonString(payload)
    }

    // MARK: Gateway transport

    /// One authenticated GET against the gateway, decoded as a JSON object.
    ///
    /// The gateway's refusals arrive as `{error, error_description}` with a
    /// status that says which kind they were; the description is written for
    /// the learner and is passed through as the tool error verbatim.
    ///
    /// Static because it touches no store state: the Settings pane asks the
    /// same question without opening `knowledge.db` for it.
    static func notionGatewayJSON(path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let token = ManagedAI.requestSessionToken else {
            throw MCPError.invalidInput(Self.notionSignedOutMessage)
        }
        guard var components = URLComponents(url: Self.notionGatewayBaseURL, resolvingAgainstBaseURL: false) else {
            throw MCPError.invalidInput("The Notion gateway address is invalid.")
        }
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MCPError.invalidInput("The Notion gateway address is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MCPError.invalidInput("Notion could not be reached through ForeverLM: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidInput("The Notion gateway returned an invalid response.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MCPError.invalidInput(Self.notionSignedOutMessage)
            }
            let description = (object?["error_description"] as? String)
                ?? (object?["error"] as? String)
                ?? "The Notion gateway answered HTTP \(http.statusCode)."
            throw MCPError.invalidInput(description)
        }
        guard let object else {
            throw MCPError.invalidInput("The Notion gateway returned something other than JSON.")
        }
        return object
    }

    // MARK: Connection state

    /// Whether this Mac can read Notion right now, as the Settings plugins
    /// list reports it beside Slack, Linear and GitHub.
    ///
    /// Notion is connected on the web, not in the app, so there is no local
    /// credential to inspect: the gateway holds the grant, and `/notion/status`
    /// says in one field whether a workspace is behind it. The Mac's own part
    /// is the managed sign-in — without a session there is nothing to ask
    /// with, which is its own state rather than a failure.
    enum NotionConnection: Equatable {
        /// A Notion workspace is connected to this ForeverLM account: its name
        /// and the learner the reads are made as, each nil when the gateway
        /// did not report it.
        case connected(workspace: String?, user: String?)
        /// The account is signed in, but no Notion workspace has been connected yet.
        case notConnected
        /// This Mac is not signed in with Apple, so it cannot read Notion.
        case signedOut

        /// Whether a workspace is connected, for callers that need one flag.
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// Asks the gateway once. `nil` means the answer is unknown — the gateway
    /// could not be reached or answered something other than its status — and
    /// the caller should say nothing rather than guess.
    static func notionConnection() async -> NotionConnection? {
        guard ManagedAI.requestSessionToken != nil else { return .signedOut }
        guard let payload = try? await notionGatewayJSON(path: "/notion/status") else { return nil }
        return notionConnection(in: payload)
    }

    /// Pure: the connection state a `/notion/status` payload reports. The
    /// gateway answers `connected: false` for an account with no workspace and
    /// `connected: true` with `workspace` and `user` otherwise; a payload
    /// without the field is unknown.
    static func notionConnection(in payload: [String: Any]) -> NotionConnection? {
        guard let connected = payload["connected"] as? Bool else { return nil }
        guard connected else { return .notConnected }
        let workspace = nonEmptyString((payload["workspace"] as? [String: Any])?["name"])
        let user = nonEmptyString((payload["user"] as? [String: Any])?["name"])
        return .connected(workspace: workspace, user: user)
    }
}
