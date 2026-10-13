import Foundation

// MARK: - Slack plugin: the live read

/// `list_slack_channels`, `read_slack_channel`, `read_slack_thread` and
/// `search_slack_messages` as the Mac answers them.
///
/// Over MCP these tools are executed by the gateway, because only the
/// gateway holds the learner's Slack token. That left the in-app chat out: the
/// Mac is an MCP *host*, so its chat sees the local catalog and never the
/// gateway's additions, and "look in Slack" could only search threads someone
/// had saved into the library earlier — a snapshot that went stale the moment
/// the channel moved on. On 2026-09-02 a primer posted at 17:22 was invisible
/// to a chat at 17:28 for exactly this reason.
///
/// Here the Mac asks the gateway for the same read over two REST routes,
/// authenticated with the managed Sign in with Apple session, and the gateway
/// applies the same channel-preference boundary the MCP path does. Nothing is
/// stored: the channel is read, returned to the chat, and forgotten.
///
/// Library matching happens on this side, against `knowledge.db`, because the
/// learner's own library is the authority on what they already have; the
/// hosted mirror the MCP path consults may be a change behind it.
extension MCPDataStore {

    /// The gateway that reads Slack as the learner.
    static var slackGatewayBaseURL: URL {
        URL(string: "https://plugin.\(MCPBrandDomains.current)")!
    }

    /// Slack channel ids are uppercase alphanumerics; the route rejects anything else.
    private static let slackChannelIDPattern = try! NSRegularExpression(pattern: "^[A-Z0-9]{1,32}$")
    /// A Slack message timestamp: seconds, a dot, and a sub-second sequence.
    private static let slackThreadTSPattern = try! NSRegularExpression(pattern: "^[0-9]{6,12}\\.[0-9]{1,6}$")

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// The channel id a Slack tool named, validated before any network call.
    private static func validatedSlackChannelID(_ raw: String, missing: String) throws -> String {
        let channelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelID.isEmpty else { throw MCPError.invalidInput(missing) }
        guard matches(slackChannelIDPattern, channelID) else {
            throw MCPError.invalidInput("channel_id must be a Slack channel id such as C0123ABCD45. Call list_slack_channels for the enabled channels.")
        }
        return channelID
    }

    /// How the session gets to Slack, in one line the learner can act on.
    private static let signedOutMessage = "Sign in with Apple in ForeverLM to read Slack. ForeverLM reads Slack as you, through your own ForeverLM account, so a signed-out Mac has nothing to read with."

    func listSlackChannels() async throws -> String {
        let payload = try await Self.slackGatewayJSON(path: "/slack/channels")
        return try jsonString(payload)
    }

    func readSlackChannel(channelID rawChannelID: String, sinceDays: Int?) async throws -> String {
        let channelID = try Self.validatedSlackChannelID(rawChannelID, missing: "channel_id is required. Call list_slack_channels first.")

        var query: [URLQueryItem] = []
        if let sinceDays, sinceDays > 0 {
            query.append(URLQueryItem(name: "since_days", value: String(sinceDays)))
        }
        var payload = try await Self.slackGatewayJSON(path: "/slack/channels/\(channelID)/history", query: query)

        // Exact identity matching only — a DOI or canonical URL may select a
        // source, while a reading named in prose still goes through search.
        let threads = payload["threads"] as? [[String: Any]] ?? []
        try await attachSlackLibraryMatches(to: &payload, references: threads.flatMap { $0["links"] as? [String] ?? [] })
        return try jsonString(payload)
    }

    /// One thread in full, from a search hit or a channel read's omitted thread.
    func readSlackThread(channelID rawChannelID: String, threadTS rawThreadTS: String) async throws -> String {
        let channelID = try Self.validatedSlackChannelID(rawChannelID, missing: "channel_id is required. It is the channel_id on a search hit or a channel read.")
        let threadTS = rawThreadTS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.matches(Self.slackThreadTSPattern, threadTS) else {
            throw MCPError.invalidInput("thread_ts is required and must be a Slack message timestamp such as 1788740520.000100, from a search hit or a channel read.")
        }
        var payload = try await Self.slackGatewayJSON(path: "/slack/channels/\(channelID)/threads/\(threadTS)")
        try await attachSlackLibraryMatches(to: &payload, references: payload["links"] as? [String] ?? [])
        return try jsonString(payload)
    }

    /// Messages and files across every enabled channel. The gateway runs
    /// Slack's own search as the learner and drops hits from channels the
    /// learner has not enabled; this side matches the hits' links against the
    /// library, as a channel read does.
    func searchSlackMessages(query rawQuery: String, limit: Int?, channelID rawChannelID: String?, sinceDays: Int?, sort: String?) async throws -> String {
        let text = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MCPError.invalidInput("query is required: words from the message, the article's title, an author, a URL or DOI fragment, or a file name.")
        }
        var query: [URLQueryItem] = [URLQueryItem(name: "query", value: text)]
        if let limit, limit > 0 { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let rawChannelID, !rawChannelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let channelID = try Self.validatedSlackChannelID(rawChannelID, missing: "")
            query.append(URLQueryItem(name: "channel_id", value: channelID))
        }
        if let sinceDays, sinceDays > 0 { query.append(URLQueryItem(name: "since_days", value: String(sinceDays))) }
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), sort == "newest" || sort == "relevance" {
            query.append(URLQueryItem(name: "sort", value: sort))
        }
        var payload = try await Self.slackGatewayJSON(path: "/slack/search", query: query)
        let hits = payload["messages"] as? [[String: Any]] ?? []
        try await attachSlackLibraryMatches(to: &payload, references: hits.flatMap { $0["links"] as? [String] ?? [] })
        return try jsonString(payload)
    }

    /// Fills `library_matches` and its note on a Slack payload from the links it
    /// carries, matched against `knowledge.db` rather than the hosted mirror.
    private func attachSlackLibraryMatches(to payload: inout [String: Any], references: [String]) async throws {
        let matches = try await resolveSlackLibraryReferences(references)
        payload["library_matches"] = matches
        payload["library_resolution_note"] = matches.isEmpty
            ? "No posted link matched a library source by exact URL or DOI. Before describing a referenced reading as external, search the library by its exact DOI or title with search_sources_semantic."
            : "IMPORTANT: Every item in library_matches is ALREADY IN THE FOREVERLM LIBRARY. It is not merely an external link or Slack attachment. When the learner asks to read or discuss one, call get_source_content with its source_id before answering. Search the library by exact DOI or title for referenced readings without a URL match."
    }

    // MARK: Gateway transport

    /// One authenticated request against the gateway, decoded as a JSON object.
    ///
    /// The gateway's refusals arrive as `{error, error_description}` with a
    /// status that says which kind they were; the description is written for
    /// the learner and is passed through as the tool error verbatim.
    ///
    /// Static because it touches no store state: the Settings pane asks the
    /// same question without opening `knowledge.db` for it.
    private static func slackGatewayJSON(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let token = ManagedAI.requestSessionToken else {
            throw MCPError.invalidInput(Self.signedOutMessage)
        }
        guard var components = URLComponents(url: Self.slackGatewayBaseURL, resolvingAgainstBaseURL: false) else {
            throw MCPError.invalidInput("The Slack gateway address is invalid.")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MCPError.invalidInput("The Slack gateway address is invalid.")
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
            throw MCPError.invalidInput("Slack could not be reached through ForeverLM: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidInput("The Slack gateway returned an invalid response.")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw MCPError.invalidInput(Self.signedOutMessage)
            }
            let description = (object?["error_description"] as? String)
                ?? (object?["error"] as? String)
                ?? "The Slack gateway answered HTTP \(http.statusCode)."
            throw MCPError.invalidInput(description)
        }
        guard let object else {
            throw MCPError.invalidInput("The Slack gateway returned something other than JSON.")
        }
        return object
    }

    // MARK: Connection state

    /// Whether this Mac can read Slack right now, as the Plugins place's
    /// list reports it beside X, YouTube and Google Drive.
    ///
    /// Slack is connected on the web, not in the app, so there is no local
    /// credential to inspect: the gateway holds the workspace token, and the
    /// account's channel list says in one field whether a workspace is behind
    /// it. The Mac's own part is the managed sign-in — without a session there
    /// is nothing to ask with, which is its own state rather than a failure.
    enum SlackWorkspaceConnection: Equatable {
        /// One or more Slack workspaces are connected to this ForeverLM
        /// account, in the order they were connected.
        case connected(workspaces: [SlackWorkspace])
        /// The account is signed in, but no workspace has been connected yet.
        case notConnected
        /// This Mac is not signed in with Apple, so it cannot read Slack.
        case signedOut

        /// Whether any workspace is connected, for callers that need one flag.
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// One connected workspace as the plugins list names it: the workspace
    /// name (or its team id, when the gateway does not know the name yet) and
    /// how many of its channels the learner has let ForeverLM read. The count
    /// is nil on a gateway from before channel counts were reported.
    struct SlackWorkspace: Equatable {
        let name: String
        let channelCount: Int?
        /// Slack's team id, which the management routes take. Nil only for a
        /// payload that named a workspace without identifying it.
        let teamID: String?

        init(name: String, channelCount: Int?, teamID: String? = nil) {
            self.name = name
            self.channelCount = channelCount
            self.teamID = teamID
        }
    }

    /// Asks the gateway once. `nil` means the answer is unknown — the gateway
    /// could not be reached or answered something other than its workspace
    /// list — and the caller should say nothing rather than guess.
    ///
    /// `/slack/workspaces` is answered from the gateway's own records: no call
    /// to Slack is made for it. The channel list (`/slack/channels`) asks Slack
    /// about every enabled channel in turn, which made the Connected chip
    /// arrive seconds after the rest of the Plugins list.
    static func slackWorkspaceConnection() async -> SlackWorkspaceConnection? {
        guard ManagedAI.requestSessionToken != nil else { return .signedOut }
        guard let payload = try? await slackGatewayJSON(path: "/slack/workspaces") else { return nil }
        return slackWorkspaceConnection(in: payload)
    }

    /// Pure: the connection state a `/slack/workspaces` payload reports. The
    /// gateway answers `connected: false` for an account with no workspace and
    /// `connected: true` with a `workspaces` list otherwise; a payload without
    /// the field is unknown. A gateway from before workspaces were listed
    /// answers `connected: true` alone, which is a connection with no names.
    /// Each workspace carries `channel_count`, the channels enabled in it, and
    /// is named as `team_name`; the older `/slack/channels` payload names it
    /// as `workspace` and is read the same way.
    static func slackWorkspaceConnection(in payload: [String: Any]) -> SlackWorkspaceConnection? {
        guard let connected = payload["connected"] as? Bool else { return nil }
        guard connected else { return .notConnected }
        let workspaces = (payload["workspaces"] as? [[String: Any]] ?? []).compactMap { workspace -> SlackWorkspace? in
            let candidates = [workspace["workspace"], workspace["team_name"], workspace["team_id"]]
            guard let name = candidates.lazy.compactMap({ value -> String? in
                guard let string = value as? String else { return nil }
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }).first else { return nil }
            let teamID = (workspace["team_id"] as? String)?.trimmingCharacters(in: .whitespaces)
            return SlackWorkspace(
                name: name,
                channelCount: workspace["channel_count"] as? Int,
                teamID: teamID?.isEmpty == false ? teamID : nil
            )
        }
        return .connected(workspaces: workspaces)
    }

    // MARK: Managing the connection from Settings

    /// Where Slack sends the learner back after consent. Registered with Slack
    /// as the app's redirect URI, so it is the same address whichever surface
    /// started the install: the web page reads the code from its own query
    /// string, and the in-app sheet is told to stop at this address and hand
    /// the same query to the app.
    static let slackInstallRedirectURL = URL(string: "https://app.foreverlm.com/slack-connect.html")!

    /// One channel as the picker shows it: Slack's id and name, whether it is
    /// private, whether the learner is a member (which only matters for a
    /// workspace read through the bot), and whether ForeverLM may read it.
    struct SlackChannelChoice: Equatable, Identifiable {
        let id: String
        let name: String
        let isPrivate: Bool
        let isMember: Bool
        var enabled: Bool
    }

    /// A connected workspace's channel picker: everything the learner's token
    /// can see, with the current choice on each.
    struct SlackWorkspaceChannels: Equatable {
        let teamID: String
        let teamName: String?
        /// True when the read is made as the learner; false when it goes
        /// through the bot, which has to be invited to a channel first.
        let readsWithoutJoining: Bool
        var channels: [SlackChannelChoice]
    }

    /// The picker for one workspace. One `conversations.list` at Slack, so it
    /// is the one management call worth showing a spinner for.
    static func slackWorkspaceChannels(teamID: String) async throws -> SlackWorkspaceChannels {
        let payload = try await slackGatewayJSON(
            path: "/slack/conversations",
            query: [URLQueryItem(name: "team_id", value: teamID)]
        )
        guard let channels = slackWorkspaceChannels(in: payload, teamID: teamID) else {
            throw MCPError.invalidInput("Slack did not return the channel list.")
        }
        return channels
    }

    /// Pure: the picker a `/slack/conversations` payload describes, or nil for
    /// a payload without a channel list.
    static func slackWorkspaceChannels(in payload: [String: Any], teamID: String) -> SlackWorkspaceChannels? {
        guard let rows = payload["channels"] as? [[String: Any]] else { return nil }
        let channels = rows.compactMap { row -> SlackChannelChoice? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return SlackChannelChoice(
                id: id,
                name: name,
                isPrivate: row["is_private"] as? Bool ?? false,
                isMember: row["is_member"] as? Bool ?? false,
                enabled: (row["mode"] as? String ?? "off") != "off"
            )
        }
        let name = (payload["team_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        return SlackWorkspaceChannels(
            teamID: (payload["team_id"] as? String) ?? teamID,
            teamName: name?.isEmpty == false ? name : nil,
            readsWithoutJoining: payload["reads_without_joining"] as? Bool ?? false,
            channels: channels
        )
    }

    /// Lets ForeverLM read a channel, or stops it. The web page writes the same
    /// two modes: `suggest` for on, `off` for off.
    static func setSlackChannel(teamID: String, channelID: String, enabled: Bool) async throws {
        _ = try await slackGatewayJSON(
            path: "/slack/channels",
            method: "POST",
            body: ["team_id": teamID, "channel_id": channelID, "mode": enabled ? "suggest" : "off"]
        )
    }

    /// Revokes the workspace's tokens at Slack and forgets it on the gateway.
    /// Returns whether any workspace is still connected afterwards.
    static func disconnectSlackWorkspace(teamID: String) async throws -> Bool {
        let payload = try await slackGatewayJSON(path: "/slack/disconnect", method: "POST", body: ["team_id": teamID])
        return payload["connected"] as? Bool ?? false
    }

    /// Slack's consent page for this account, carrying a state the gateway
    /// will recognise when the code comes back.
    static func slackAuthorizationURL() async throws -> URL {
        let payload = try await slackGatewayJSON(path: "/slack/install")
        guard let string = payload["authorization_url"] as? String, let url = URL(string: string) else {
            throw MCPError.invalidInput("The gateway did not return Slack's authorization address.")
        }
        return url
    }

    /// Finishes an install with the code and state Slack sent back. Returns the
    /// connected workspace's team id when the gateway reports one.
    static func completeSlackInstall(code: String, state: String) async throws -> String? {
        let payload = try await slackGatewayJSON(path: "/slack/install", method: "POST", body: ["code": code, "state": state])
        return payload["team_id"] as? String
    }

    // MARK: Library matching

    /// A library row as the matcher sees it: the identities a Slack link can
    /// equal, and what to say about the source when one does.
    struct SlackLibraryCandidate {
        let id: String
        let title: String?
        let sourceType: String?
        let url: String?
        let normalizedURL: String?
        let doi: String?
        let publishedDOI: String?
    }

    /// Resolves the links a channel posted against the library, holding the
    /// store's operation gate only for the query itself. The network read that
    /// produced the links ran outside the gate, so a slow Slack never blocks
    /// another tool's SQLite access.
    private func resolveSlackLibraryReferences(_ references: [String]) async throws -> [[String: Any]] {
        let cleaned = Array(Set(references
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(2_048)) }))
            .prefix(100)
        guard !cleaned.isEmpty else { return [] }

        let normalizedURLs = Set(cleaned.map(URLNormalizer.normalize))
        let dois = Set(cleaned.compactMap(Self.slackReferenceDOI))

        await acquireToolOperation()
        let rows: [[String: Any]]
        do {
            rows = try withDB { db in
                var clauses: [String] = []
                var params: [Any] = []
                if !normalizedURLs.isEmpty {
                    clauses.append("normalized_url IN (\(Array(repeating: "?", count: normalizedURLs.count).joined(separator: ",")))")
                    params.append(contentsOf: normalizedURLs.sorted())
                }
                if !dois.isEmpty {
                    let placeholders = Array(repeating: "?", count: dois.count).joined(separator: ",")
                    clauses.append("lower(doi) IN (\(placeholders))")
                    clauses.append("lower(published_doi) IN (\(placeholders))")
                    params.append(contentsOf: dois.sorted())
                    params.append(contentsOf: dois.sorted())
                }
                return try query(db, """
                    SELECT id, title, source_type, url, normalized_url, doi, published_doi
                    FROM source_projection
                    WHERE \(clauses.joined(separator: " OR "))
                    LIMIT 200
                    """, params: params)
            }
        } catch {
            await releaseToolOperation()
            throw error
        }
        await releaseToolOperation()

        let candidates = rows.compactMap { row -> SlackLibraryCandidate? in
            guard let id = row["id"] as? String else { return nil }
            return SlackLibraryCandidate(
                id: id,
                title: row["title"] as? String,
                sourceType: row["source_type"] as? String,
                url: row["url"] as? String,
                normalizedURL: row["normalized_url"] as? String,
                doi: row["doi"] as? String,
                publishedDOI: row["published_doi"] as? String
            )
        }
        return Self.matchSlackReferences(Array(cleaned), against: candidates)
    }

    /// Pure: which posted links name which library sources, by DOI first and
    /// canonical URL second. Mirrors the gateway's `matchSourceReferences` so a
    /// chat gets the same shape from either path.
    static func matchSlackReferences(
        _ references: [String],
        against candidates: [SlackLibraryCandidate]
    ) -> [[String: Any]] {
        var matches: [[String: Any]] = []
        var emitted = Set<String>()
        for reference in references {
            let referenceDOI = slackReferenceDOI(reference)
            let referenceURL = URLNormalizer.normalize(reference)
            for candidate in candidates {
                let candidateDOIs = Set([candidate.doi, candidate.publishedDOI, candidate.url, candidate.normalizedURL]
                    .compactMap { $0 }
                    .compactMap(slackReferenceDOI))
                let candidateURLs = Set([candidate.url, candidate.normalizedURL]
                    .compactMap { $0 }
                    .map(URLNormalizer.normalize))
                let basis: String?
                if let referenceDOI, candidateDOIs.contains(referenceDOI) {
                    basis = "doi"
                } else if candidateURLs.contains(referenceURL) {
                    basis = "url"
                } else {
                    basis = nil
                }
                guard let basis else { continue }
                let key = "\(reference)\u{0}\(candidate.id)"
                guard !emitted.contains(key) else { continue }
                emitted.insert(key)
                let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                matches.append([
                    "reference": reference,
                    "source_id": candidate.id,
                    "title": title.isEmpty ? "Untitled source" : title,
                    "source_type": candidate.sourceType ?? "unclassified",
                    "match_basis": basis,
                    "availability": "already_in_foreverlm_library",
                    "next_tool": "get_source_content",
                ])
            }
        }
        return matches
    }

    /// The DOI a link or identifier carries, lowercased, or nil when it has none.
    /// Accepts doi.org links, `doi:` prefixes, bare DOIs, and publisher URLs the
    /// paper importer already knows how to read.
    static func slackReferenceDOI(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if let url = URL(string: trimmed), let host = url.host?.lowercased(),
           host == "doi.org" || host == "dx.doi.org" {
            candidate = url.path.drop(while: { $0 == "/" }).description
        } else if trimmed.lowercased().hasPrefix("http"),
                  let fromURL = PaperService.extractDOI(from: trimmed) {
            candidate = fromURL
        }
        candidate = candidate.removingPercentEncoding ?? candidate
        let pattern = #"(?:doi:\s*)?(10\.\d{4,9}/[^\s<>"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: candidate) else { return nil }
        var doi = String(candidate[range])
        while let last = doi.last, ")],.;:}".contains(last) {
            doi.removeLast()
        }
        return doi.lowercased()
    }
}

// MARK: - Fetching from the gateway as the learner

extension ManagedAI {
    /// Whether `url` addresses the MCP gateway — the host that serves a Slack
    /// file's `download_url`. Scheme and exact host, so a look-alike host or a
    /// downgraded scheme never earns the session.
    static func isForeverLMGatewayURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              let gatewayHost = MCPDataStore.slackGatewayBaseURL.host?.lowercased() else { return false }
        return host == gatewayHost
    }

    /// Carries the managed session on a request bound for the gateway.
    ///
    /// A Slack file is served by ForeverLM's own gateway as the learner, so the
    /// importer's download of a `download_url` is authorised the way the Slack
    /// reads are, rather than dressed up as a browser. Returns false when this
    /// Mac is signed out, in which case the request must not be sent: the
    /// gateway would answer 401 and the importer would read that as a paywall.
    @discardableResult
    static func authorizeIfForeverLMGateway(_ request: inout URLRequest) -> Bool {
        guard let url = request.url, isForeverLMGatewayURL(url) else { return true }
        guard let token = sessionToken else { return false }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/pdf, */*", forHTTPHeaderField: "Accept")
        return true
    }
}
