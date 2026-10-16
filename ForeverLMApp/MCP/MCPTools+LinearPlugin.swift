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

    /// The optional `workspace` every read takes: a workspace's id, URL key or
    /// name. Omitted, the gateway reads every connected workspace and tags each
    /// result with the workspace it came from.
    private static func linearWorkspaceQuery(_ workspace: String?) -> [URLQueryItem] {
        guard let workspace = trimmedLinearArgument(workspace) else { return [] }
        return [URLQueryItem(name: "workspace", value: workspace)]
    }

    func getLinearIssue(issue rawIssue: String, workspace: String? = nil) async throws -> String {
        guard let issue = Self.trimmedLinearArgument(rawIssue) else {
            throw MCPError.invalidInput("issue is required: an identifier such as ENG-123, or the issue's id.")
        }
        guard Self.linearMatches(Self.linearIssuePattern, issue) else {
            throw MCPError.invalidInput("issue must be an identifier such as ENG-123 or an issue id.")
        }
        let payload = try await Self.linearGatewayJSON(path: "/linear/issues/\(issue)", query: Self.linearWorkspaceQuery(workspace))
        return try jsonString(payload)
    }

    func searchLinearIssues(term rawTerm: String, teamKey: String?, limit: Int?, workspace: String? = nil) async throws -> String {
        guard let term = Self.trimmedLinearArgument(rawTerm) else {
            throw MCPError.invalidInput("term is required: words from the issue's title or description, an identifier, or a name.")
        }
        var query = [URLQueryItem(name: "term", value: term)] + Self.linearWorkspaceQuery(workspace)
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
        limit: Int?,
        workspace: String? = nil
    ) async throws -> String {
        var query = Self.linearWorkspaceQuery(workspace)
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

    func listLinearTeams(workspace: String? = nil) async throws -> String {
        let payload = try await Self.linearGatewayJSON(path: "/linear/teams", query: Self.linearWorkspaceQuery(workspace))
        return try jsonString(payload)
    }

    func listLinearProjects(teamKey: String?, statusType: String?, limit: Int?, workspace: String? = nil) async throws -> String {
        var query = Self.linearWorkspaceQuery(workspace)
        if let key = try Self.validatedLinearTeamKey(teamKey) { query.append(URLQueryItem(name: "team_key", value: key)) }
        if let statusType = Self.trimmedLinearArgument(statusType) { query.append(URLQueryItem(name: "status_type", value: statusType.lowercased())) }
        if let limit, limit > 0 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.linearGatewayJSON(path: "/linear/projects", query: query)
        return try jsonString(payload)
    }

    func getLinearProject(project rawProject: String, workspace: String? = nil) async throws -> String {
        guard let project = Self.trimmedLinearArgument(rawProject) else {
            throw MCPError.invalidInput("project is required: the project's id, or its slug_id from list_linear_projects or the project's URL.")
        }
        guard Self.linearMatches(Self.linearProjectPattern, project) else {
            throw MCPError.invalidInput("project must be a project id or slug.")
        }
        let payload = try await Self.linearGatewayJSON(path: "/linear/projects/\(project)", query: Self.linearWorkspaceQuery(workspace))
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
    private static func linearGatewayJSON(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
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
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

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

    /// Whether this Mac can read Linear right now, as the Plugins place's
    /// list reports it beside Slack.
    ///
    /// Linear is connected through the gateway (the Plugins page or the web
    /// page), so there is no local credential to inspect: the gateway holds one
    /// grant per workspace, and `/linear/status` lists them. The Mac's own part
    /// is the managed sign-in — without a session there is nothing to ask
    /// with, which is its own state rather than a failure.
    enum LinearConnection: Equatable {
        /// One or more Linear workspaces are connected to this ForeverLM
        /// account, oldest first. Each is its own grant, read as the learner.
        case connected(workspaces: [LinearWorkspace])
        /// The account is signed in, but no workspace has been connected yet.
        case notConnected
        /// This Mac is not signed in with Apple, so it cannot read Linear.
        case signedOut

        /// Whether any workspace is connected, for callers that need one flag.
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// The connected workspaces; empty when none is.
        var workspaces: [LinearWorkspace] {
            if case .connected(let workspaces) = self { return workspaces }
            return []
        }
    }

    /// One connected Linear workspace as the Plugins pages name it.
    struct LinearWorkspace: Equatable, Identifiable {
        /// Linear's organization id, which the management routes take.
        let id: String
        /// The workspace's name, nil on a gateway that did not report it.
        let name: String?
        let urlKey: String?
        /// The Linear user the reads are made as.
        let user: String?

        /// What the pages call the workspace: its name, else its URL key.
        var label: String { name ?? urlKey ?? "Linear workspace" }
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
    /// `connected: true` with a `workspaces` list otherwise; a payload without
    /// the field is unknown. A gateway from before workspaces were listed
    /// describes its one workspace in `organization` and `user`, which is read
    /// as a list of one.
    static func linearConnection(in payload: [String: Any]) -> LinearConnection? {
        guard let connected = payload["connected"] as? Bool else { return nil }
        guard connected else { return .notConnected }
        let legacyRow = (payload["organization"] as? [String: Any]).map { organization -> [String: Any] in
            var row = organization
            row["user"] = payload["user"]
            return row
        }
        let rows = payload["workspaces"] as? [[String: Any]] ?? legacyRow.map { [$0] } ?? []
        let workspaces = rows.compactMap { row -> LinearWorkspace? in
            guard let id = nonEmptyString(row["id"]) else { return nil }
            return LinearWorkspace(
                id: id,
                name: nonEmptyString(row["name"]),
                urlKey: nonEmptyString(row["url_key"]),
                user: nonEmptyString((row["user"] as? [String: Any])?["name"])
            )
        }
        return .connected(workspaces: workspaces)
    }

    // MARK: Managing the connection from the page

    /// Where Linear sends the learner back after consent; registered with
    /// Linear, so it is the same address whichever surface started the connect.
    static let linearInstallRedirectURL = URL(string: "https://app.foreverlm.com/linear-connect.html")!

    /// Linear's consent page for this account, carrying a state the gateway
    /// will recognise when the code comes back.
    static func linearAuthorizationURL() async throws -> URL {
        let payload = try await linearGatewayJSON(path: "/linear/install")
        guard let string = payload["authorization_url"] as? String, let url = URL(string: string) else {
            throw MCPError.invalidInput("The gateway did not return Linear's authorization address.")
        }
        return url
    }

    /// Finishes a connect with the code and state Linear sent back. Adds the
    /// workspace, or refreshes it when it is already connected.
    static func completeLinearInstall(code: String, state: String) async throws {
        _ = try await linearGatewayJSON(path: "/linear/install", method: "POST", body: ["code": code, "state": state])
    }

    /// Revokes one workspace's grant at Linear and forgets it on the gateway.
    /// Returns whether any workspace is still connected afterwards.
    static func disconnectLinearWorkspace(id: String) async throws -> Bool {
        let payload = try await linearGatewayJSON(path: "/linear/disconnect", method: "POST", body: ["organization_id": id])
        return payload["connected"] as? Bool ?? false
    }

    /// A JSON string with something in it, or nil for a missing, null, blank
    /// or non-string value.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
