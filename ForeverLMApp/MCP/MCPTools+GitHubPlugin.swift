import Foundation

// MARK: - GitHub plugin: the live read

/// `list_github_repositories`, `get_github_repository`, `list_github_files`,
/// `read_github_file`, `search_github_code`, `list_github_issues`,
/// `get_github_issue`, `list_github_pull_requests`, `get_github_pull_request`
/// and `list_github_commits` as the Mac answers them.
///
/// Over MCP these tools are executed by the gateway, because only the gateway
/// holds the learner's GitHub grant. The Mac is an MCP *host*, so its in-app
/// chat sees the local catalog and never the gateway's additions; without these
/// twins a chat could not read GitHub at all (Slack and Linear carry twins for
/// exactly this reason, `MCPTools+SlackPlugin.swift` and
/// `MCPTools+LinearPlugin.swift`).
///
/// Each twin asks the gateway for the same read over a `GET /github/…` route,
/// authenticated with the managed Sign in with Apple session, and the gateway
/// reads GitHub as the learner with the same read-only grant the MCP path uses.
/// Nothing is stored: the file or issue is read, returned to the chat, and
/// forgotten. There is no write here and none on the gateway: ForeverLM cannot
/// comment, push, or merge.
extension MCPDataStore {

    /// The gateway that reads GitHub as the learner.
    static var githubGatewayBaseURL: URL {
        URL(string: "https://plugin.\(MCPBrandDomains.current)")!
    }

    /// A GitHub login: alphanumerics and single hyphens, at most 39 characters.
    private static let githubOwnerPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
    /// A repository name.
    private static let githubRepoPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,100}$")

    private static func githubMatches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// How the session gets to GitHub, in one line the learner can act on.
    private static let githubSignedOutMessage = "Sign in with Apple in ForeverLM to read GitHub. ForeverLM reads GitHub as you, through your own ForeverLM account, so a signed-out Mac has nothing to read with."

    private static func trimmedGitHubArgument(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Repository argument

    /// The owner and name in a `repository` argument: `owner/repo`, or a
    /// github.com URL such as `https://github.com/owner/repo/tree/main/src`.
    /// A trailing `.git` on the name is dropped. `nil` when the text is
    /// neither, or names an owner or repository GitHub could not have.
    static func parseGitHubRepository(_ raw: String) -> (owner: String, repo: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var components: [String]
        if text.contains("://") {
            guard let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com"
            else { return nil }
            components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { return nil }
            components = Array(components.prefix(2))
        } else {
            components = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count == 2 else { return nil }
        }

        let owner = components[0]
        var repo = components[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard githubMatches(githubOwnerPattern, owner), githubMatches(githubRepoPattern, repo) else { return nil }
        return (owner, repo)
    }

    static func validatedGitHubRepository(_ raw: String) throws -> (owner: String, repo: String) {
        guard let repository = parseGitHubRepository(raw) else {
            throw MCPError.invalidInput("repository must be owner/repo, or a github.com URL such as https://github.com/owner/repo; call list_github_repositories for the names ForeverLM can read.")
        }
        return repository
    }

    /// `/github/repos/{owner}/{repo}` with each component percent-encoded.
    static func githubRepoPath(_ repository: (owner: String, repo: String), _ suffix: String = "") -> String {
        let owner = repository.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository.owner
        let repo = repository.repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository.repo
        return "/github/repos/\(owner)/\(repo)\(suffix)"
    }

    private static func validatedGitHubNumber(_ number: Int?, what: String) throws -> Int {
        guard let number, number > 0 else {
            throw MCPError.invalidInput("number must be the \(what)'s number, a positive integer such as the 42 in #42 or at the end of its URL.")
        }
        return number
    }

    private static func validatedGitHubState(_ raw: String?) throws -> String? {
        guard let state = trimmedGitHubArgument(raw)?.lowercased() else { return nil }
        guard ["open", "closed", "all"].contains(state) else {
            throw MCPError.invalidInput("state must be open, closed, or all.")
        }
        return state
    }

    // MARK: The reads

    func listGitHubRepositories(query: String?, limit: Int?) async throws -> String {
        var items: [URLQueryItem] = []
        if let query = Self.trimmedGitHubArgument(query) { items.append(URLQueryItem(name: "query", value: query)) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.githubGatewayJSON(path: "/github/repositories", query: items)
        return try jsonString(payload)
    }

    func getGitHubRepository(repository rawRepository: String, ref: String?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        var items: [URLQueryItem] = []
        if let ref = Self.trimmedGitHubArgument(ref) { items.append(URLQueryItem(name: "ref", value: ref)) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository), query: items)
        return try jsonString(payload)
    }

    func listGitHubFiles(repository rawRepository: String, path: String?, ref: String?, recursive: Bool?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        var items: [URLQueryItem] = []
        if let path = Self.trimmedGitHubArgument(path) { items.append(URLQueryItem(name: "path", value: path)) }
        if let ref = Self.trimmedGitHubArgument(ref) { items.append(URLQueryItem(name: "ref", value: ref)) }
        if recursive == true { items.append(URLQueryItem(name: "recursive", value: "true")) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/files"), query: items)
        return try jsonString(payload)
    }

    func readGitHubFile(repository rawRepository: String, path rawPath: String, ref: String?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        guard let path = Self.trimmedGitHubArgument(rawPath) else {
            throw MCPError.invalidInput("path is required: the file's path within the repository, such as src/main.swift, from list_github_files.")
        }
        var items = [URLQueryItem(name: "path", value: path)]
        if let ref = Self.trimmedGitHubArgument(ref) { items.append(URLQueryItem(name: "ref", value: ref)) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/file"), query: items)
        return try jsonString(payload)
    }

    func searchGitHubCode(repository rawRepository: String, query rawQuery: String, limit: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        guard let query = Self.trimmedGitHubArgument(rawQuery) else {
            throw MCPError.invalidInput("query is required: words, an identifier, or a phrase to find in the repository's code.")
        }
        var items = [URLQueryItem(name: "query", value: query)]
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/search"), query: items)
        return try jsonString(payload)
    }

    func listGitHubIssues(repository rawRepository: String, state: String?, labels: String?, sinceDays: Int?, limit: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        var items: [URLQueryItem] = []
        if let state = try Self.validatedGitHubState(state) { items.append(URLQueryItem(name: "state", value: state)) }
        if let labels = Self.trimmedGitHubArgument(labels) { items.append(URLQueryItem(name: "labels", value: labels)) }
        if let sinceDays, sinceDays > 0 { items.append(URLQueryItem(name: "since_days", value: String(sinceDays))) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/issues"), query: items)
        return try jsonString(payload)
    }

    func getGitHubIssue(repository rawRepository: String, number: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        let number = try Self.validatedGitHubNumber(number, what: "issue")
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/issues/\(number)"))
        return try jsonString(payload)
    }

    func listGitHubPullRequests(repository rawRepository: String, state: String?, limit: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        var items: [URLQueryItem] = []
        if let state = try Self.validatedGitHubState(state) { items.append(URLQueryItem(name: "state", value: state)) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/pulls"), query: items)
        return try jsonString(payload)
    }

    func getGitHubPullRequest(repository rawRepository: String, number: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        let number = try Self.validatedGitHubNumber(number, what: "pull request")
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/pulls/\(number)"))
        return try jsonString(payload)
    }

    func listGitHubCommits(repository rawRepository: String, ref: String?, path: String?, sinceDays: Int?, limit: Int?) async throws -> String {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        var items: [URLQueryItem] = []
        if let ref = Self.trimmedGitHubArgument(ref) { items.append(URLQueryItem(name: "ref", value: ref)) }
        if let path = Self.trimmedGitHubArgument(path) { items.append(URLQueryItem(name: "path", value: path)) }
        if let sinceDays, sinceDays > 0 { items.append(URLQueryItem(name: "since_days", value: String(sinceDays))) }
        if let limit, limit > 0 { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        let payload = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/commits"), query: items)
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
    static func githubGatewayJSON(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let token = ManagedAI.requestSessionToken else {
            throw MCPError.invalidInput(Self.githubSignedOutMessage)
        }
        guard var components = URLComponents(url: Self.githubGatewayBaseURL, resolvingAgainstBaseURL: false) else {
            throw MCPError.invalidInput("The GitHub gateway address is invalid.")
        }
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MCPError.invalidInput("The GitHub gateway address is invalid.")
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
            throw MCPError.invalidInput("GitHub could not be reached through ForeverLM: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidInput("The GitHub gateway returned an invalid response.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MCPError.invalidInput(Self.githubSignedOutMessage)
            }
            let description = (object?["error_description"] as? String)
                ?? (object?["error"] as? String)
                ?? "The GitHub gateway answered HTTP \(http.statusCode)."
            throw MCPError.invalidInput(description)
        }
        guard let object else {
            throw MCPError.invalidInput("The GitHub gateway returned something other than JSON.")
        }
        return object
    }

    // MARK: Connection state

    /// One place the ForeverLM GitHub App is installed: a personal account or
    /// an organisation. Repositories come from these and nowhere else, so the
    /// Settings pane draws one card per installation.
    struct GitHubInstallation: Equatable, Hashable, Sendable, Identifiable {
        /// GitHub's installation id; nil on a gateway that did not report it.
        var installationID: Int?
        /// The account's login: `ForeverLM-HQ`, `alanyoung`.
        var account: String
        /// `Organization` or `User`, as GitHub types the account; nil when unknown.
        var accountType: String?

        var id: String { account.lowercased() }

        var isOrganization: Bool {
            accountType?.caseInsensitiveCompare("Organization") == .orderedSame
        }

        /// "organisation" or "personal account", or nil when GitHub did not say.
        var kindLabel: String? {
            guard let accountType, !accountType.isEmpty else { return nil }
            return isOrganization ? "organisation" : "personal account"
        }

        /// The account's page on GitHub.
        var url: URL? { URL(string: "https://github.com/\(account)") }
    }

    /// The connected GitHub account as `/github/status` describes it.
    struct GitHubAccount: Equatable, Sendable {
        /// The login the reads are made as; nil on a gateway that did not report it.
        var login: String?
        /// The account's display name, when GitHub knows one.
        var name: String?
        /// The accounts and organisations the App is installed on, as GitHub
        /// lists them live. Empty when nothing has installed the App yet or
        /// GitHub did not answer.
        var installations: [GitHubInstallation] = []
        /// Why the installations could not be listed, when they could not.
        var installationsError: String?
        /// The grant no longer works and the account should reconnect.
        var reconnectRequired: Bool = false
        /// GitHub's page for installing the App on another organisation.
        var installURL: URL?

        init(
            login: String? = nil,
            name: String? = nil,
            installations: [GitHubInstallation] = [],
            installationsError: String? = nil,
            reconnectRequired: Bool = false,
            installURL: URL? = nil
        ) {
            self.login = login
            self.name = name
            self.installations = installations
            self.installationsError = installationsError
            self.reconnectRequired = reconnectRequired
            self.installURL = installURL
        }

        /// The installation account names, for copy that lists them.
        var installationNames: [String] { installations.map(\.account) }
    }

    /// Whether this Mac can read GitHub right now, as the Plugins place's
    /// list reports it beside Slack and Linear.
    ///
    /// GitHub is connected on the web, not in the app, so there is no local
    /// credential to inspect: the gateway holds the grant, and `/github/status`
    /// says in one field whether an account is behind it. The Mac's own part
    /// is the managed sign-in — without a session there is nothing to ask
    /// with, which is its own state rather than a failure.
    enum GitHubConnection: Equatable {
        /// A GitHub account is connected to this ForeverLM account.
        case connected(GitHubAccount)
        /// The account is signed in, but no GitHub account has been connected yet.
        case notConnected
        /// This Mac is not signed in with Apple, so it cannot read GitHub.
        case signedOut

        /// Whether an account is connected, for callers that need one flag.
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// The connected account, or nil in the other two states.
        var account: GitHubAccount? {
            if case .connected(let account) = self { return account }
            return nil
        }
    }

    /// Asks the gateway once. `nil` means the answer is unknown — the gateway
    /// could not be reached or answered something other than its status — and
    /// the caller should say nothing rather than guess.
    static func githubConnection() async -> GitHubConnection? {
        guard ManagedAI.requestSessionToken != nil else { return .signedOut }
        guard let payload = try? await githubGatewayJSON(path: "/github/status") else { return nil }
        return githubConnection(in: payload)
    }

    /// Pure: the connection state a `/github/status` payload reports. The
    /// gateway answers `connected: false` for an account with no GitHub
    /// account and `connected: true` with `user` and `installations`
    /// otherwise; a payload without the field is unknown.
    static func githubConnection(in payload: [String: Any]) -> GitHubConnection? {
        guard let connected = payload["connected"] as? Bool else { return nil }
        guard connected else { return .notConnected }
        let user = payload["user"] as? [String: Any]
        return .connected(GitHubAccount(
            login: nonEmptyString(user?["login"]),
            name: nonEmptyString(user?["name"]),
            installations: githubInstallations(in: payload["installations"]),
            installationsError: nonEmptyString(payload["installations_error"]),
            reconnectRequired: payload["reconnect_required"] as? Bool ?? false,
            installURL: nonEmptyString(payload["install_url"]).flatMap(URL.init(string:))
        ))
    }

    /// The installations in a status or repositories payload. One GitHub did
    /// not name is left out rather than shown blank.
    static func githubInstallations(in value: Any?) -> [GitHubInstallation] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let account = nonEmptyString(entry["account"]) else { return nil }
            return GitHubInstallation(
                installationID: (entry["id"] as? NSNumber)?.intValue,
                account: account,
                accountType: nonEmptyString(entry["account_type"])
            )
        }
    }

    // MARK: Repositories

    /// One repository the App can reach, as `/github/repositories` lists it.
    struct GitHubRepositorySummary: Equatable, Hashable, Sendable, Identifiable {
        /// `owner/name`.
        var fullName: String
        var isPrivate: Bool?
        var description: String?
        var defaultBranch: String?
        var url: URL?
        /// The last push, from GitHub's ISO 8601 `pushed_at`.
        var pushedAt: Date?
        var language: String?
        var isArchived: Bool = false
        var isFork: Bool = false

        var id: String { fullName.lowercased() }

        /// The account before the slash.
        var owner: String {
            fullName.split(separator: "/", maxSplits: 1).first.map(String.init) ?? fullName
        }

        /// The name after the slash.
        var name: String {
            let parts = fullName.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : fullName
        }
    }

    /// Every repository the App can reach for this account, newest push first.
    struct GitHubRepositoryListing: Equatable, Sendable {
        var repositories: [GitHubRepositorySummary] = []
        /// GitHub or the gateway listed more than it returned.
        var truncated: Bool = false
        /// How many matched before the cut, when the gateway said.
        var totalMatched: Int?

        /// The repositories owned by an installation's account, newest push
        /// first. Installation repositories are owned by the account the App
        /// is installed on, so the owner half of the full name is the join.
        func repositories(ownedBy account: String) -> [GitHubRepositorySummary] {
            repositories.filter { $0.owner.caseInsensitiveCompare(account) == .orderedSame }
        }

        /// The repositories whose owner is none of the given installations —
        /// a repository shared into the grant some other way.
        func repositories(notOwnedByAny accounts: [String]) -> [GitHubRepositorySummary] {
            let owned = Set(accounts.map { $0.lowercased() })
            return repositories.filter { !owned.contains($0.owner.lowercased()) }
        }
    }

    /// The most the gateway hands back in one answer.
    static let githubRepositoriesPageLimit = 100

    /// Every repository the App can reach, from the gateway, newest push first.
    static func githubRepositories() async throws -> GitHubRepositoryListing {
        let payload = try await githubGatewayJSON(
            path: "/github/repositories",
            query: [URLQueryItem(name: "limit", value: String(githubRepositoriesPageLimit))]
        )
        return githubRepositoryListing(in: payload)
    }

    /// Pure: the repositories a `/github/repositories` payload lists. A row
    /// without a `full_name` is left out; every other field is optional.
    static func githubRepositoryListing(in payload: [String: Any]) -> GitHubRepositoryListing {
        let iso = KnowledgeStore.iso8601Formatter
        let repositories = (payload["repositories"] as? [[String: Any]] ?? []).compactMap { raw -> GitHubRepositorySummary? in
            guard let fullName = nonEmptyString(raw["full_name"]) else { return nil }
            return GitHubRepositorySummary(
                fullName: fullName,
                isPrivate: raw["private"] as? Bool,
                description: nonEmptyString(raw["description"]),
                defaultBranch: nonEmptyString(raw["default_branch"]),
                url: nonEmptyString(raw["url"]).flatMap(URL.init(string:)),
                pushedAt: nonEmptyString(raw["pushed_at"]).flatMap { iso.date(from: $0) },
                language: nonEmptyString(raw["language"]),
                isArchived: raw["archived"] as? Bool ?? false,
                isFork: raw["fork"] as? Bool ?? false
            )
        }
        return GitHubRepositoryListing(
            repositories: repositories,
            truncated: payload["truncated"] as? Bool ?? false,
            totalMatched: (payload["total_matched"] as? NSNumber)?.intValue
        )
    }

    // MARK: Disconnect

    /// Ends the connection: the gateway revokes the token at GitHub and forgets
    /// it, so no read can use it again. Returns whether an account is still
    /// connected afterwards — false on success.
    static func disconnectGitHub() async throws -> Bool {
        let payload = try await githubGatewayJSON(path: "/github/disconnect", method: "POST", body: [:])
        return payload["connected"] as? Bool ?? false
    }
}
