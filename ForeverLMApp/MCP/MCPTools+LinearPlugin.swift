import Foundation

// MARK: - Linear plugin: the live read

/// `get_linear_issue`, `search_linear_issues`, `list_linear_issues`,
/// `list_linear_teams`, `list_linear_projects` and `get_linear_project` as the
/// Mac answers them.
///
/// Over MCP these tools are executed by the gateway, because only the gateway
/// holds the learner's Linear grant. The Mac is an MCP *host*, so its in-app
/// chat sees the local catalog and never the gateway's additions; without these
/// twins a chat could not read Linear at all (the Slack tools were added for
/// exactly this reason on 2026-09-02, `MCPTools+SlackPlugin.swift`).
///
/// Each twin asks the gateway for the same read over a `GET /linear/…` route,
/// authenticated with the managed Sign in with Apple session, and the gateway
/// reads Linear as the learner with the same read-only grant the MCP path uses.
/// Nothing is stored: the issue is read, returned to the chat, and forgotten.
/// There is no write here and none on the gateway; the grant is `read` only.
extension MCPDataStore {

    /// The gateway that reads Linear as the learner.
    static var linearGatewayBaseURL: URL {
        URL(string: "https://plugin.\(MCPBrandDomains.current)")!
    }

    /// An issue identifier such as ENG-123, or an issue id.
    private static let linearIssuePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
    /// A project id or URL slug.
    private static let linearProjectPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
    /// A team key: the prefix of the team's identifiers.
    private static let linearTeamKeyPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9]{1,10}$")

    private static func linearMatches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// How the session gets to Linear, in one line the learner can act on.
    private static let linearSignedOutMessage = "Sign in with Apple in ForeverLM to read Linear. ForeverLM reads Linear as you, through your own ForeverLM account, so a signed-out Mac has nothing to read with."

    private static func trimmedLinearArgument(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validatedLinearTeamKey(_ raw: String?) throws -> String? {
        guard let key = trimmedLinearArgument(raw) else { return nil }
        guard linearMatches(linearTeamKeyPattern, key) else {
            throw MCPError.invalidInput("team_key must be a Linear team key such as ENG, the prefix of the team's issue identifiers. Call list_linear_teams for the keys.")
        }
        return key.uppercased()
    }

    func getLinearIssue(issue rawIssue: String) async throws -> String {
        guard let issue = Self.trimmedLinearArgument(rawIssue) else {
            throw MCPError.invalidInput("issue is required: an identifier such as ENG-123, or the issue's id.")
        }
        guard Self.linearMatches(Self.linearIssuePattern, issue) else {
            throw MCPError.invalidInput("issue must be an identifier such as ENG-123 or an issue id.")
        }
        let payload = try await Self.linearGatewayJSON(path: "/linear/issues/\(issue)")
        return try jsonString(payload)
    }

    func searchLinearIssues(term rawTerm: String, teamKey: String?, limit: Int?) async throws -> String {
        guard let term = Self.trimmedLinearArgument(rawTerm) else {
            throw MCPError.invalidInput("term is required: words from the issue's title or description, an identifier, or a name.")
        }
        var query = [URLQueryItem(name: "term", value: term)]
        if let key = try Self.validatedLinearTeamKey(teamKey) { query.append(URLQueryItem(name: "team_key", value: key)) }
        if let limit, limit > 0 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.linearGatewayJSON(path: "/linear/search", query: query)
        return try jsonString(payload)
    }

    func listLinearIssues(
        teamKey: String?,
        stateType: String?,
        assignedToMe: Bool?,
        updatedSinceDays: Int?,
        project: String?,
        limit: Int?
    ) async throws -> String {
        var query: [URLQueryItem] = []
        if let key = try Self.validatedLinearTeamKey(teamKey) { query.append(URLQueryItem(name: "team_key", value: key)) }
        if let stateType = Self.trimmedLinearArgument(stateType) { query.append(URLQueryItem(name: "state_type", value: stateType.lowercased())) }
        if assignedToMe == true { query.append(URLQueryItem(name: "assigned_to_me", value: "true")) }
        if let updatedSinceDays, updatedSinceDays > 0 { query.append(URLQueryItem(name: "updated_since_days", value: String(updatedSinceDays))) }
        if let project = Self.trimmedLinearArgument(project) {
            guard Self.linearMatches(Self.linearProjectPattern, project) else {
                throw MCPError.invalidInput("project must be a project id or slug from list_linear_projects.")
            }
            query.append(URLQueryItem(name: "project", value: project))
        }
        if let limit, limit > 0 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.linearGatewayJSON(path: "/linear/issues", query: query)
        return try jsonString(payload)
    }

    func listLinearTeams() async throws -> String {
        let payload = try await Self.linearGatewayJSON(path: "/linear/teams")
        return try jsonString(payload)
    }

    func listLinearProjects(teamKey: String?, statusType: String?, limit: Int?) async throws -> String {
        var query: [URLQueryItem] = []
        if let key = try Self.validatedLinearTeamKey(teamKey) { query.append(URLQueryItem(name: "team_key", value: key)) }
        if let statusType = Self.trimmedLinearArgument(statusType) { query.append(URLQueryItem(name: "status_type", value: statusType.lowercased())) }
        if let limit, limit > 0 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.linearGatewayJSON(path: "/linear/projects", query: query)
        return try jsonString(payload)
    }

    func getLinearProject(project rawProject: String) async throws -> String {
        guard let project = Self.trimmedLinearArgument(rawProject) else {
            throw MCPError.invalidInput("project is required: the project's id, or its slug_id from list_linear_projects or the project's URL.")
        }
        guard Self.linearMatches(Self.linearProjectPattern, project) else {
            throw MCPError.invalidInput("project must be a project id or slug.")
        }
        let payload = try await Self.linearGatewayJSON(path: "/linear/projects/\(project)")
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
    private static func linearGatewayJSON(path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let token = ManagedAI.requestSessionToken else {
            throw MCPError.invalidInput(Self.linearSignedOutMessage)
        }
        guard var components = URLComponents(url: Self.linearGatewayBaseURL, resolvingAgainstBaseURL: false) else {
            throw MCPError.invalidInput("The Linear gateway address is invalid.")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MCPError.invalidInput("The Linear gateway address is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MCPError.invalidInput("Linear could not be reached through ForeverLM: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidInput("The Linear gateway returned an invalid response.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MCPError.invalidInput(Self.linearSignedOutMessage)
            }
            let description = (object?["error_description"] as? String)
                ?? (object?["error"] as? String)
                ?? "The Linear gateway answered HTTP \(http.statusCode)."
            throw MCPError.invalidInput(description)
        }
        guard let object else {
            throw MCPError.invalidInput("The Linear gateway returned something other than JSON.")
        }
        return object
    }

    // MARK: Connection state

    /// Whether this Mac can read Linear right now, as the Settings plugins
    /// list reports it beside Slack.
    ///
    /// Linear is connected on the web, not in the app, so there is no local
    /// credential to inspect: the gateway holds the grant, and `/linear/status`
    /// says in one field whether a workspace is behind it. The Mac's own part
    /// is the managed sign-in — without a session there is nothing to ask
    /// with, which is its own state rather than a failure.
    enum LinearConnection: Equatable {
        /// A Linear workspace is connected to this ForeverLM account: the
        /// workspace's name (its URL key when the name is unknown) and the
        /// Linear user the reads are made as. Either is nil on a gateway that
        /// did not report it.
        case connected(workspace: String?, user: String?)
        /// The account is signed in, but no workspace has been connected yet.
        case notConnected
        /// This Mac is not signed in with Apple, so it cannot read Linear.
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
    static func linearConnection() async -> LinearConnection? {
        guard ManagedAI.requestSessionToken != nil else { return .signedOut }
        guard let payload = try? await linearGatewayJSON(path: "/linear/status") else { return nil }
        return linearConnection(in: payload)
    }

    /// Pure: the connection state a `/linear/status` payload reports. The
    /// gateway answers `connected: false` for an account with no workspace and
    /// `connected: true` with `organization` and `user` otherwise; a payload
    /// without the field is unknown.
    static func linearConnection(in payload: [String: Any]) -> LinearConnection? {
        guard let connected = payload["connected"] as? Bool else { return nil }
        guard connected else { return .notConnected }
        let organization = payload["organization"] as? [String: Any]
        let workspace = nonEmptyString(organization?["name"]) ?? nonEmptyString(organization?["url_key"])
        let user = nonEmptyString((payload["user"] as? [String: Any])?["name"])
        return .connected(workspace: workspace, user: user)
    }

    /// A JSON string with something in it, or nil for a missing, null, blank
    /// or non-string value.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
