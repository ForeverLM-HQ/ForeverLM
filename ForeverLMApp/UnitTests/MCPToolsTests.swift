import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

/// An explainer writer that answers with a canned draft, so `generate_explainer`
/// can be driven without a model route.
private struct CannedMCPExplainerBackend: ExplainerModelBackend {
    var draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        draft
    }
}

/// An explainer writer that waits in its model call until released, so a test
/// can hold a paid writer open and see what else runs meanwhile.
private struct HeldMCPExplainerBackend: ExplainerModelBackend {
    let entered: MCPTestSignal
    let release: MCPTestSignal
    let draft: ExplainerDraft

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        await entered.signal()
        await release.wait()
        return draft
    }
}

/// The value of an answer's own `key: value` line, where a tool result hands
/// back a new id instead of writing it beside a name (Prompts.hiddenIDs).
func mcpAnswerValue(_ key: String, in text: String) -> String? {
    text.split(separator: "\n").lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(key + ": ") }
        .map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
}

/// The Notebook create_notebook made: its `notebook_id:` line when it filed
/// the calling chat, else the id its next-call line names
/// ("Pass notebook_id X explicitly …").
func createdNotebookID(in text: String) -> String? {
    if let line = mcpAnswerValue("notebook_id", in: text) { return line }
    guard let range = text.range(of: "Pass notebook_id ") else { return nil }
    return text[range.upperBound...].split(separator: " ").first.map(String.init)
}

private actor MCPTestSignal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSet else { return }
        isSet = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var hasSignaled: Bool { isSet }
}

@Suite("MCP OAuth consent labels")
struct MCPOAuthConsentLabelTests {
    @Test("Claude dynamic clients use a friendly name")
    func claudeDynamicClientName() {
        #expect(MCPOAuthProvider.clientDisplayName(
            clientID: "dyn_0123456789abcdef0123456789abcdef",
            redirectURI: "https://claude.ai/api/mcp/auth_callback"
        ) == "Claude")
    }

    @Test("Unknown dynamic clients do not expose machine identifiers")
    func unknownDynamicClientName() {
        #expect(MCPOAuthProvider.clientDisplayName(
            clientID: "dyn_123456",
            redirectURI: "https://example.com/oauth/callback"
        ) == "An AI assistant")
    }
}

/// A plugin is known by the client_name it registered, and an authorization
/// request does not carry it. On 2026-10-10 the move to Apple team XXXXXXXXXX
/// emptied the store of registrations; a plugin that came back with its old id
/// was recreated with no name, so its sources would have filed under the raw
/// `dyn_…` id instead of "Read AI Meetings".
@Suite("MCP OAuth forgotten clients")
struct MCPOAuthForgottenClientTests {
    private let loopback = "http://127.0.0.1:53682/callback"
    private let forgottenID = "dyn_0123456789abcdef"

    @Test("A forgotten plugin client is refused, so it registers again under its name")
    func forgottenPluginClientIsRefused() {
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:ingest"))
    }

    @Test("A forgotten local assistant asking for full access is still recovered")
    func forgottenFullAccessClientIsRecovered() {
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: nil))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:tools"))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: loopback, requestedScope: "mcp:ingest mcp:tools"))
        #expect(MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: "http://localhost:8080/callback", requestedScope: nil))
    }

    @Test("Only loopback dynamic clients are ever recovered")
    func onlyLoopbackDynamicClientsRecover() {
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: forgottenID, redirectURI: "https://example.com/callback", requestedScope: nil))
        #expect(!MCPOAuthProvider.mayRecoverDynamicClient(
            clientID: "foreverlm-provisioned", redirectURI: loopback, requestedScope: nil))
    }

    @Test("Refusing a forgotten client says to register again")
    func refusalSaysToRegisterAgain() throws {
        let response = MCPOAuthProvider.unknownClientResponse(clientID: forgottenID, status: 401)
        #expect(response.status == 401)
        let body = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(body["error"] == "invalid_client")
        #expect(body["error_description"]?.contains("/oauth/register") == true)
        #expect(body["error_description"]?.contains("same client_name") == true)

        let other = MCPOAuthProvider.unknownClientResponse(clientID: "someone-else", status: 400)
        #expect(other.status == 400)
        #expect(try JSONSerialization.jsonObject(with: other.body) as? [String: String] == ["error": "invalid_client"])
    }
}

@Suite("MCP auth scopes")
struct MCPAuthScopeTests {
    @Test("Absent or full scope requests grant full access")
    func absentOrFullScopeGrantsFull() {
        #expect(MCPAuthScope.effective(fromRequested: nil) == .full)
        #expect(MCPAuthScope.effective(fromRequested: "") == .full)
        #expect(MCPAuthScope.effective(fromRequested: "mcp:tools") == .full)
        // A request carrying both scopes is a full-access request; ingest only
        // narrows when requested exclusively.
        #expect(MCPAuthScope.effective(fromRequested: "mcp:ingest mcp:tools") == .full)
    }

    @Test("Exclusive ingest scope narrows the grant")
    func exclusiveIngestNarrows() {
        #expect(MCPAuthScope.effective(fromRequested: "mcp:ingest") == .ingest)
    }

    @Test("Unknown scope tokens are detected for loud rejection")
    func unknownScopeTokensDetected() {
        #expect(MCPAuthScope.allTokensKnown(inRequested: "mcp:tools"))
        #expect(MCPAuthScope.allTokensKnown(inRequested: "mcp:ingest mcp:tools"))
        #expect(!MCPAuthScope.allTokensKnown(inRequested: "mcp:admin"))
        #expect(!MCPAuthScope.allTokensKnown(inRequested: "mcp:ingest mcp:admin"))
    }

    @Test("OAuth query scopes decode form-encoded spaces")
    func oauthQueryScopesDecodeFormEncodedSpaces() {
        let request = HTTPRequest(
            method: "GET",
            path: "/oauth/authorize",
            queryString: "scope=mcp%3Atools+mcp%3Aingest&state=literal%2Bplus",
            headers: [:],
            body: Data()
        )

        #expect(request.queryParams["scope"] == "mcp:tools mcp:ingest")
        #expect(request.queryParams["state"] == "literal+plus")
        #expect(MCPAuthScope.allTokensKnown(inRequested: request.queryParams["scope"] ?? ""))
        #expect(MCPAuthScope.effective(fromRequested: request.queryParams["scope"]) == .full)
    }

    @Test("Plugin labels are sanitized for storage and display")
    func connectorLabelsSanitized() {
        #expect(MCPOAuthProvider.sanitizedPluginLabel("Readwise Sync") == "Readwise Sync")
        #expect(MCPOAuthProvider.sanitizedPluginLabel("  My\nReadwise\tSync  ") == "My Readwise Sync")
        #expect(MCPOAuthProvider.sanitizedPluginLabel("") == "Plugin")
        #expect(MCPOAuthProvider.sanitizedPluginLabel("   \n\t ") == "Plugin")
        #expect(MCPOAuthProvider.sanitizedPluginLabel(String(repeating: "x", count: 200)).count == 64)
    }

    @Test("Ingest allowlist gates the tool registry")
    func ingestAllowlistGatesRegistry() {
        #expect(MCPToolRegistry.isToolAllowed("add_source", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("add_sources", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("update_source_content", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("get_mcp_status", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("report_connector_status", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("get_connector_inbox", scope: .ingest))
        #expect(MCPToolRegistry.isToolAllowed("import_connector_paper", scope: .ingest))

        #expect(!MCPToolRegistry.isToolAllowed("list_sources", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("get_source_content", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("get_notebook_context", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("delete_source", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("create_x_post", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("import_local_pdf_as_paper", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("import_local_file", scope: .ingest))
        #expect(!MCPToolRegistry.isToolAllowed("import_paper_from_url", scope: .ingest))
        // Bulk removal is a full-scope cleanup tool, never a plugin's own.
        #expect(!MCPToolRegistry.isToolAllowed("remove_connector_sources", scope: .ingest))
        // Legacy aliases resolve before the check, so an old name can't slip past.
        #expect(!MCPToolRegistry.isToolAllowed("start_review_session", scope: .ingest))

        #expect(MCPToolRegistry.isToolAllowed("delete_source", scope: .full))
        #expect(MCPToolRegistry.isToolAllowed("remove_connector_sources", scope: .full))
    }

    /// The in-app chat sees the Mac's catalog, not the gateway's additions, so
    /// Slack has to be in the catalog or a chat has no way into Slack at all.
    /// Registered here, read-only, and off the store gate — the read is a
    /// network round trip that must not queue every other tool behind it.
    @Test("The live Slack read is a registered, read-only, gate-exempt tool")
    func slackReadIsRegisteredForChat() {
        let tools = MCPToolRegistry.shared.tools
        let names = Set(tools.map(\.name))
        #expect(names.contains("list_slack_channels"))
        #expect(names.contains("read_slack_channel"))
        #expect(names.contains("read_slack_thread"))
        #expect(names.contains("search_slack_messages"))
        #expect(MCPToolRegistry.storeGateExemptToolNames == [
            "get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map",
            "place_on_canvas", "take_off_canvas",
            "create_canvas_region", "update_canvas_region", "delete_canvas_region",
            "draw_canvas_arrow", "update_canvas_arrow", "delete_canvas_arrow",
            "undo_canvas", "keep_map_lens", "set_canvas_display",
            "update_canvas_card", "arrange_on_canvas", "lint_canvas", "screenshot_canvas",
            "list_canvases", "create_canvas", "open_canvas", "update_canvas", "delete_canvas",
            "list_canvas_versions", "save_canvas_version", "restore_canvas_version",
            "list_space_lists", "create_space_list", "update_space_list", "delete_space_list",
            "ask_canvas",
            "make_atlas", "get_atlas", "list_atlases", "delete_atlas",
            "inspect_paper_figure",
            "list_running_ai_work", "cancel_ai_work", "cancel_source_audio_generation",
            "list_images", "get_image", "generate_image", "save_image", "rename_image", "delete_image",
            "list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages",
            "get_linear_issue", "search_linear_issues", "list_linear_issues",
            "list_linear_teams", "list_linear_projects", "get_linear_project",
            "list_github_repositories", "get_github_repository", "list_github_files",
            "read_github_file", "search_github_code", "list_github_issues",
            "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
            "list_github_commits",
            "search_notion", "get_notion_page", "list_notion_databases",
            "get_notion_database", "query_notion_database",
            "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video", "close_day",
            "find_podcast_on_youtube", "import_podcast_youtube_transcript",
            "get_linked_references", "get_block", "get_daily_note", "append_to_daily_note",
        ])

        // Search is the call that replaces the channel sweep; the description
        // has to say so, and point a hit at the thread read.
        let search = tools.first { $0.name == "search_slack_messages" }
        let searchProperties = search?.inputSchema["properties"] as? [String: Any]
        #expect(searchProperties?["query"] != nil)
        #expect(search?.inputSchema["required"] as? [String] == ["query"])
        #expect(search?.description.contains("read_slack_thread") == true)
        #expect(search?.description.contains("download_url") == true)
        let thread = tools.first { $0.name == "read_slack_thread" }
        #expect(thread?.inputSchema["required"] as? [String] == ["channel_id", "thread_ts"])

        let read = tools.first { $0.name == "read_slack_channel" }
        let properties = read?.inputSchema["properties"] as? [String: Any]
        #expect(properties?["channel_id"] != nil)
        #expect(properties?["since_days"] != nil)
        #expect(read?.inputSchema["required"] as? [String] == ["channel_id"])
        // The description has to carry the one fact the model cannot infer:
        // nothing from Slack is stored, so this tool is the only way to Slack.
        #expect(read?.description.contains("live") == true)
        #expect(read?.description.contains("only way into Slack") == true)
        // A PDF dropped into the channel is the paper as often as a link is;
        // the description names the two tools that consume its download_url.
        #expect(read?.description.contains("download_url") == true)
        #expect(read?.description.contains("attach_pdf_to_paper") == true)
        #expect(read?.description.contains("import_paper_from_url") == true)

        let attach = tools.first { $0.name == "attach_pdf_to_paper" }
        #expect(attach?.description.contains("download_url") == true)
        let importPaper = tools.first { $0.name == "import_paper_from_url" }
        let importProperties = importPaper?.inputSchema["properties"] as? [String: Any]
        #expect(importProperties?["source_url"] != nil)
        #expect(importPaper?.inputSchema["required"] as? [String] == ["url"])
    }

    /// The in-app chat's two picture tools, over MCP: a model on the other end
    /// asks for a figure and receives the figure, not a caption list and not a
    /// hunt for the PDF on disk (2026-09-19). Both read the library and change
    /// nothing; the figure tool explains with a vision call, so it is off the
    /// store gate the way the connector reads are.
    @Test("The picture tools are registered, read-only, and answer with image content parts")
    func pictureToolsAreRegisteredWithImageParts() {
        let tools = MCPToolRegistry.shared.tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in ["inspect_paper_figure", "show_source_image"] {
            #expect(byName[name] != nil, "\(name) is missing from the Mac catalog")
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full))
            #expect(!MCPToolRegistry.isToolAllowed(name, scope: .ingest), "a read is not an ingest tool")
        }
        #expect(MCPToolRegistry.storeGateExemptToolNames.contains("inspect_paper_figure"))
        #expect(!MCPToolRegistry.storeGateExemptToolNames.contains("show_source_image"))

        let inspect = byName["inspect_paper_figure"]
        #expect(inspect?.inputSchema["required"] as? [String] == ["source_id", "figure_label"])
        let inspectProperties = inspect?.inputSchema["properties"] as? [String: Any]
        #expect(inspectProperties?["panel_label"] != nil)
        // The model has to be told the picture is attached, that it is cropped
        // to a panel on request, and that the paper's own PDF is where it comes from.
        #expect(inspect?.description.contains("as an image") == true)
        #expect(inspect?.description.contains("panel_label") == true)
        #expect(inspect?.description.contains("never search the web") == true)
        #expect(inspect?.description.contains("Needs the learner's Mac") == true)

        let show = byName["show_source_image"]
        #expect(show?.inputSchema["required"] as? [String] == ["source_id"])
        let showProperties = show?.inputSchema["properties"] as? [String: Any]
        for key in ["query", "page", "slide", "at", "crop"] {
            #expect(showProperties?[key] != nil, "show_source_image takes \(key)")
        }
        #expect(show?.description.contains("extract_video_slides") == true)
        #expect(show?.description.contains("inspect_paper_figure") == true)

        // The protocol layer emits the text first and one image part per
        // picture, base64 with its media type, as the MCP specification has it.
        let picture = MCPToolImage(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
        let outcome = MCPToolRegistry.ToolCallOutcome(text: "Figure 2 (PDF page 3)", isError: false, images: [picture])
        let parts = MCPProtocolHandler.contentParts(for: outcome)
        #expect(parts.count == 2)
        #expect(parts.first?["type"] as? String == "text")
        #expect(parts.first?["text"] as? String == "Figure 2 (PDF page 3)")
        #expect(parts.last?["type"] as? String == "image")
        #expect(parts.last?["mimeType"] as? String == "image/jpeg")
        #expect(parts.last?["data"] as? String == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        let plain = MCPProtocolHandler.contentParts(for: MCPToolRegistry.ToolCallOutcome(text: "ok", isError: false))
        #expect(plain.count == 1)
    }

    /// Linear is read the same way Slack is: on the gateway, with a grant only
    /// it holds, so the Mac carries twins or an in-app chat cannot read Linear.
    /// Every twin is read-only and off the store gate.
    @Test("The live Linear reads are registered, read-only, gate-exempt tools")
    func linearReadsAreRegisteredForChat() {
        let tools = MCPToolRegistry.shared.tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let linear = ["get_linear_issue", "search_linear_issues", "list_linear_issues", "list_linear_teams", "list_linear_projects", "get_linear_project"]
        for name in linear {
            #expect(byName[name] != nil, "\(name) is missing from the Mac catalog")
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full))
        }
        #expect(byName["get_linear_issue"]?.inputSchema["required"] as? [String] == ["issue"])
        #expect(byName["search_linear_issues"]?.inputSchema["required"] as? [String] == ["term"])
        #expect(byName["get_linear_project"]?.inputSchema["required"] as? [String] == ["project"])
        let listProperties = byName["list_linear_issues"]?.inputSchema["properties"] as? [String: Any]
        for key in ["team_key", "state_type", "assigned_to_me", "updated_since_days", "project", "limit"] {
            #expect(listProperties?[key] != nil, "list_linear_issues lacks \(key)")
        }
        let stateType = listProperties?["state_type"] as? [String: Any]
        #expect(stateType?["enum"] as? [String] == ["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate"])
        // The one fact the model cannot infer from a schema: nothing here writes.
        for name in linear {
            #expect(byName[name]?.description.lowercased().contains("read-only") == true
                || byName[name]?.description.contains("read-only grant") == true, "\(name) does not say it is read-only")
        }
        #expect(byName["get_linear_issue"]?.description.contains("only way into Linear") == true)

        // The connection state is read off the gateway's status payload, and a
        // payload without the field is unknown rather than a guess.
        #expect(MCPDataStore.linearConnection(in: ["connected": true]) == .connected(workspace: nil, user: nil))
        #expect(MCPDataStore.linearConnection(in: ["connected": false, "configured": true]) == .notConnected)
        #expect(MCPDataStore.linearConnection(in: ["error": "x"]) == nil)
        // The workspace and user the gateway reports travel with the state, so
        // the plugins list can say which workspace is read and as whom. A
        // workspace without a name falls back to its URL key.
        #expect(MCPDataStore.linearConnection(in: [
            "connected": true,
            "organization": ["id": "org_1", "name": "Bench Lab", "url_key": "benchlab"],
            "user": ["name": "Robin Vale"],
        ]) == .connected(workspace: "Bench Lab", user: "Robin Vale"))
        #expect(MCPDataStore.linearConnection(in: [
            "connected": true,
            "organization": ["id": "org_1", "name": NSNull(), "url_key": "benchlab"],
            "user": ["name": " "],
        ]) == .connected(workspace: "benchlab", user: nil))
        #expect(MCPDataStore.linearConnection(in: ["connected": true])?.isConnected == true)
        #expect(MCPDataStore.linearConnection(in: ["connected": false])?.isConnected == false)
        #expect(MCPDataStore.linearGatewayBaseURL.absoluteString == "https://plugin.foreverlm.com")
    }

    /// GitHub is read the way Linear is: on the gateway, with an installation
    /// only it holds, so the Mac carries twins or an in-app chat cannot read a
    /// repository. Every twin is read-only and off the store gate.
    @Test("The live GitHub reads are registered, read-only, gate-exempt tools")
    func githubReadsAreRegisteredForChat() {
        let tools = MCPToolRegistry.shared.tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let github = [
            "list_github_repositories", "get_github_repository", "list_github_files",
            "read_github_file", "search_github_code", "list_github_issues",
            "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
            "list_github_commits",
        ]
        for name in github {
            #expect(byName[name] != nil, "\(name) is missing from the Mac catalog")
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full))
        }
        // Nine tools name a repository; the list of repositories is how one is found.
        #expect(byName["list_github_repositories"]?.inputSchema["required"] as? [String] == [])
        for name in github where name != "list_github_repositories" {
            let required = byName[name]?.inputSchema["required"] as? [String]
            #expect(required?.first == "repository", "\(name) does not require repository")
        }
        #expect(byName["read_github_file"]?.inputSchema["required"] as? [String] == ["repository", "path"])
        #expect(byName["search_github_code"]?.inputSchema["required"] as? [String] == ["repository", "query"])
        #expect(byName["get_github_issue"]?.inputSchema["required"] as? [String] == ["repository", "number"])
        #expect(byName["get_github_pull_request"]?.inputSchema["required"] as? [String] == ["repository", "number"])
        let issueProperties = byName["list_github_issues"]?.inputSchema["properties"] as? [String: Any]
        for key in ["repository", "state", "labels", "since_days", "limit"] {
            #expect(issueProperties?[key] != nil, "list_github_issues lacks \(key)")
        }
        let state = issueProperties?["state"] as? [String: Any]
        #expect(state?["enum"] as? [String] == ["open", "closed", "all"])
        let fileProperties = byName["list_github_files"]?.inputSchema["properties"] as? [String: Any]
        #expect((fileProperties?["recursive"] as? [String: Any])?["type"] as? String == "boolean")
        // The one fact the model cannot infer from a schema: nothing here writes.
        for name in github {
            #expect(byName[name]?.description.lowercased().contains("read-only") == true, "\(name) does not say it is read-only")
        }
        #expect(byName["list_github_repositories"]?.description.contains("only way into GitHub") == true)

        // The connection state is read off the gateway's status payload, and a
        // payload without the field is unknown rather than a guess.
        #expect(MCPDataStore.githubConnection(in: ["connected": true]) == .connected(.init()))
        #expect(MCPDataStore.githubConnection(in: ["connected": false, "configured": true]) == .notConnected)
        #expect(MCPDataStore.githubConnection(in: ["error": "x"]) == nil)
        // The login and the accounts the App is installed on travel with the
        // state, so the plugins list can name the organisations it reads
        // and the pane can draw one card per installation, typed. An
        // installation GitHub did not name is left out rather than blank.
        #expect(MCPDataStore.githubConnection(in: [
            "connected": true,
            "user": ["login": "robinvale", "name": "Robin"],
            "installations": [
                ["id": 1, "account": "ForeverLM-HQ", "account_type": "Organization"],
                ["id": 2, "account": "robinvale", "account_type": "User"],
                ["id": 3, "account": NSNull(), "account_type": NSNull()],
            ],
            "install_url": "https://github.com/apps/foreverlm/installations/new",
        ]) == .connected(.init(
            login: "robinvale",
            name: "Robin",
            installations: [
                .init(installationID: 1, account: "ForeverLM-HQ", accountType: "Organization"),
                .init(installationID: 2, account: "robinvale", accountType: "User"),
            ],
            installURL: URL(string: "https://github.com/apps/foreverlm/installations/new")
        )))
        let account = MCPDataStore.githubConnection(in: [
            "connected": true, "installations_error": "GitHub answered HTTP 502", "reconnect_required": true,
        ])?.account
        #expect(account?.installations.isEmpty == true)
        #expect(account?.installationsError == "GitHub answered HTTP 502")
        #expect(account?.reconnectRequired == true)
        #expect(MCPDataStore.GitHubInstallation(installationID: 1, account: "ForeverLM-HQ", accountType: "Organization").isOrganization)
        #expect(MCPDataStore.GitHubInstallation(installationID: 1, account: "ForeverLM-HQ", accountType: "Organization").kindLabel == "organisation")
        #expect(MCPDataStore.GitHubInstallation(installationID: 2, account: "robinvale", accountType: "User").kindLabel == "personal account")
        #expect(MCPDataStore.GitHubInstallation(installationID: nil, account: "x", accountType: nil).kindLabel == nil)
        #expect(MCPDataStore.githubConnection(in: ["connected": true])?.isConnected == true)
        #expect(MCPDataStore.githubConnection(in: ["connected": false])?.isConnected == false)

        // The repositories listing keeps every field the pane draws, drops a
        // row without a name, and joins repositories to installations by owner.
        let listing = MCPDataStore.githubRepositoryListing(in: [
            "connected": true,
            "repositories": [
                ["full_name": "ForeverLM-HQ/ForeverLM", "private": true, "description": "The app", "default_branch": "main",
                 "url": "https://github.com/ForeverLM-HQ/ForeverLM", "pushed_at": "2026-09-11T10:00:00Z", "language": "Swift"],
                ["full_name": "robinvale/dotfiles", "private": false, "archived": true, "fork": true],
                ["private": true],
            ],
            "truncated": true,
            "total_matched": 3,
        ])
        #expect(listing.repositories.map(\.fullName) == ["ForeverLM-HQ/ForeverLM", "robinvale/dotfiles"])
        #expect(listing.truncated && listing.totalMatched == 3)
        let app = listing.repositories[0]
        #expect(app.owner == "ForeverLM-HQ" && app.name == "ForeverLM" && app.isPrivate == true && app.language == "Swift")
        #expect(app.pushedAt == ISO8601DateFormatter().date(from: "2026-09-11T10:00:00Z"))
        #expect(app.url == URL(string: "https://github.com/ForeverLM-HQ/ForeverLM"))
        #expect(listing.repositories[1].isArchived && listing.repositories[1].isFork && listing.repositories[1].isPrivate == false)
        #expect(listing.repositories(ownedBy: "foreverlm-hq").map(\.name) == ["ForeverLM"])
        #expect(listing.repositories(notOwnedByAny: ["ForeverLM-HQ"]).map(\.fullName) == ["robinvale/dotfiles"])
        #expect(listing.repositories(notOwnedByAny: ["ForeverLM-HQ", "robinvale"]).isEmpty)
        #expect(MCPDataStore.githubGatewayBaseURL.absoluteString == "https://plugin.foreverlm.com")

        // The repository argument is owner/repo or a github.com URL, parsed on
        // the Mac so a bad one is refused with a sentence before any round trip.
        let plain = MCPDataStore.parseGitHubRepository("owner/repo")
        #expect(plain?.owner == "owner" && plain?.repo == "repo")
        let fromURL = MCPDataStore.parseGitHubRepository("https://github.com/owner/repo/tree/main/x")
        #expect(fromURL?.owner == "owner" && fromURL?.repo == "repo")
        let dotGit = MCPDataStore.parseGitHubRepository("OWNER/repo.git")
        #expect(dotGit?.owner == "OWNER" && dotGit?.repo == "repo")
        #expect(MCPDataStore.parseGitHubRepository("owner") == nil)
        #expect(MCPDataStore.parseGitHubRepository("a/b/c") == nil)
        #expect(MCPDataStore.parseGitHubRepository("https://gitlab.com/a/b") == nil)
    }

    /// Notion is read the way GitHub is: on the gateway, with a grant only it
    /// holds, so the Mac carries twins or an in-app chat cannot read a page.
    /// Every twin is read-only and off the store gate.
    @Test("The live Notion reads are registered, read-only, gate-exempt tools")
    func notionReadsAreRegisteredForChat() {
        let tools = MCPToolRegistry.shared.tools
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let notion = [
            "search_notion", "get_notion_page", "list_notion_databases",
            "get_notion_database", "query_notion_database",
        ]
        for name in notion {
            #expect(byName[name] != nil, "\(name) is missing from the Mac catalog")
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full))
            #expect(byName[name]?.description.lowercased().contains("read-only") == true, "\(name) does not say it is read-only")
        }
        #expect(byName["search_notion"]?.inputSchema["required"] as? [String] == [])
        #expect(byName["list_notion_databases"]?.inputSchema["required"] as? [String] == [])
        #expect(byName["get_notion_page"]?.inputSchema["required"] as? [String] == ["page"])
        #expect(byName["get_notion_database"]?.inputSchema["required"] as? [String] == ["database"])
        #expect(byName["query_notion_database"]?.inputSchema["required"] as? [String] == ["database"])
        let searchProperties = byName["search_notion"]?.inputSchema["properties"] as? [String: Any]
        #expect((searchProperties?["kind"] as? [String: Any])?["enum"] as? [String] == ["page", "database"])
        let queryProperties = byName["query_notion_database"]?.inputSchema["properties"] as? [String: Any]
        for key in ["database", "filter", "sorts", "limit", "cursor"] {
            #expect(queryProperties?[key] != nil, "query_notion_database lacks \(key)")
        }
        #expect((queryProperties?["filter"] as? [String: Any])?["type"] as? String == "object")
        #expect((queryProperties?["sorts"] as? [String: Any])?["type"] as? String == "array")
        #expect(byName["search_notion"]?.description.contains("only way into Notion") == true)

        // The connection state is read off the gateway's status payload, and a
        // payload without the field is unknown rather than a guess.
        #expect(MCPDataStore.notionConnection(in: ["connected": true]) == .connected(workspace: nil, user: nil))
        #expect(MCPDataStore.notionConnection(in: ["connected": false, "configured": true]) == .notConnected)
        #expect(MCPDataStore.notionConnection(in: ["error": "x"]) == nil)
        #expect(MCPDataStore.notionConnection(in: [
            "connected": true,
            "workspace": ["id": "ws", "name": "Bench Lab", "icon": NSNull()],
            "user": ["id": "u", "name": "Robin Vale"],
        ]) == .connected(workspace: "Bench Lab", user: "Robin Vale"))
        #expect(MCPDataStore.notionConnection(in: ["connected": true, "workspace": ["name": ""]]) == .connected(workspace: nil, user: nil))
        #expect(MCPDataStore.notionConnection(in: ["connected": true])?.isConnected == true)
        #expect(MCPDataStore.notionConnection(in: ["connected": false])?.isConnected == false)
        #expect(MCPDataStore.notionGatewayBaseURL.absoluteString == "https://plugin.foreverlm.com")

        // A page or database argument is an id in either spelling or a Notion
        // URL, parsed on the Mac so a bad one is refused with a sentence before
        // any round trip, and normalised to the dashed form the routes take.
        let dashed = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"
        let hex = "3f2a1b4c5d6e4f708192a3b4c5d6e7f8"
        #expect(MCPDataStore.parseNotionID(dashed) == dashed)
        #expect(MCPDataStore.parseNotionID(hex.uppercased()) == dashed)
        #expect(MCPDataStore.parseNotionID("https://www.notion.so/benchlab/Mitochondrial-uncouplers-\(hex)") == dashed)
        #expect(MCPDataStore.parseNotionID("notion.so/Mitochondrial-uncouplers-\(hex)?pvs=4") == dashed)
        #expect(MCPDataStore.parseNotionID("https://benchlab.notion.site/Wiki-\(hex)") == dashed)
        // Notion moved the app off notion.so, so a link copied today carries
        // notion.com — app.notion.com for the page a learner is looking at.
        #expect(MCPDataStore.parseNotionID("https://app.notion.com/p/BenchLab-\(hex)") == dashed)
        #expect(MCPDataStore.parseNotionID("https://www.notion.com/benchlab/Mitochondrial-uncouplers-\(hex)") == dashed)
        #expect(MCPDataStore.parseNotionID("notion.com/Mitochondrial-uncouplers-\(hex)?pvs=4") == dashed)
        #expect(MCPDataStore.parseNotionID("https://www.notion.so/\(hex)?v=0123456789abcdef0123456789abcdef") == dashed)
        #expect(MCPDataStore.parseNotionID("https://www.notion.so/benchlab/Reading-list-0123456789abcdef0123456789abcdef?p=\(hex)&pm=s") == dashed)
        #expect(MCPDataStore.parseNotionID("Reading list") == nil)
        #expect(MCPDataStore.parseNotionID("https://www.notion.so/benchlab/Reading-list") == nil)
        #expect(MCPDataStore.parseNotionID("https://app.notion.com/p/Reading-list") == nil)
        #expect(MCPDataStore.parseNotionID("https://github.com/o/r") == nil)
        // A lookalike domain is not Notion.
        #expect(MCPDataStore.parseNotionID("https://notion.com.example.org/o/r") == nil)
        #expect(MCPDataStore.parseNotionID("12345") == nil)
    }

    /// A Slack file's download_url is served by ForeverLM's own gateway, so the
    /// importer's download carries the managed session there and nowhere else.
    @Test("Only the gateway's own host earns the managed session on a PDF download")
    func gatewayDownloadsCarryTheSession() {
        let gateway = URL(string: "https://plugin.foreverlm.com/slack/files/F0A1B2C3D4E/aging-cohort.pdf")!
        #expect(ManagedAI.isForeverLMGatewayURL(gateway))
        #expect(!ManagedAI.isForeverLMGatewayURL(URL(string: "http://plugin.foreverlm.com/slack/files/F1/x.pdf")!))
        #expect(!ManagedAI.isForeverLMGatewayURL(URL(string: "https://files.slack.com/files-pri/T1-F1/download/x.pdf")!))
        #expect(!ManagedAI.isForeverLMGatewayURL(URL(string: "https://plugin.foreverlm.com.evil.example/x.pdf")!))
        #expect(!ManagedAI.isForeverLMGatewayURL(URL(string: "https://export.arxiv.org/pdf/2401.00001.pdf")!))

        // A publisher download is left exactly as the browser request built it.
        var publisher = URLRequest(url: URL(string: "https://www.science.org/doi/pdf/10.1126/science.abc1234")!)
        #expect(ManagedAI.authorizeIfForeverLMGateway(&publisher))
        #expect(publisher.value(forHTTPHeaderField: "Authorization") == nil)

        // The gateway's address ends in the file's name, so the importer sees a
        // direct PDF link and downloads it rather than hunting for a landing page.
        #expect(PaperService.isDirectPDFURL(gateway.absoluteString))
        #expect(PaperService.isDirectPDFURL("https://plugin.foreverlm.com/slack/files/F1/notes%20final.pdf"))
    }

    /// A gateway refusal carries the sentence the learner needs; a publisher's
    /// HTML error page carries nothing the chat should repeat.
    @Test("A gateway error body's description is what the importer reports")
    func gatewayErrorDescriptionIsSurfaced() {
        let refusal = Data(#"{"error":"slack_reconnect_required","error_description":"Reconnect Slack once at https://app.foreverlm.com/slack-connect and try again."}"#.utf8)
        #expect(SourceService.gatewayErrorDescription(from: refusal) == "Reconnect Slack once at https://app.foreverlm.com/slack-connect and try again.")
        #expect(SourceService.gatewayErrorDescription(from: Data("<html>Forbidden</html>".utf8)) == nil)
        #expect(SourceService.gatewayErrorDescription(from: Data(#"{"error":"x","error_description":"  "}"#.utf8)) == nil)
    }

    /// A paper the library lists but cannot read takes a PDF that arrives for
    /// it; one that already has its PDF on disk keeps the duplicate answer.
    @Test("A listed paper without a readable PDF takes an arriving one; one with a PDF does not")
    func existingPaperTakesArrivingPDF() throws {
        var paywalled = StudioArticle(url: "https://www.science.org/doi/10.1126/science.abc1234", title: "Aging cohort", sourceType: .paper)
        paywalled.isPaywalled = true
        #expect(MCPDataStore.existingPaperTakesArrivingPDF(paywalled))

        let gone = StudioArticle(url: "https://www.science.org/doi/10.1126/science.abc1234", title: "Aging cohort", sourceType: .paper, localFilePath: "/nonexistent/Papers/10.1126-science.abc1234.pdf")
        #expect(MCPDataStore.existingPaperTakesArrivingPDF(gone))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("10.1126-science.abc1234.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let complete = StudioArticle(url: "https://www.science.org/doi/10.1126/science.abc1234", title: "Aging cohort", sourceType: .paper, localFilePath: pdf.path)
        #expect(!MCPDataStore.existingPaperTakesArrivingPDF(complete))

        let article = StudioArticle(url: "https://example.com/post", title: "Not a paper", sourceType: .article)
        #expect(!MCPDataStore.existingPaperTakesArrivingPDF(article))
    }

    @Test("A paper imported from a download address is identified by its provenance URL")
    func importFromDownloadAddressRequiresProvenance() async {
        let store = MCPDataStore()
        await #expect(throws: MCPError.self) {
            try await store.importPaperFromDownloadURL(
                "https://plugin.foreverlm.com/slack/files/F1/x.pdf",
                sourceURL: "not a url",
                title: nil
            )
        }
        await #expect(throws: MCPError.self) {
            try await store.importPaperFromDownloadURL("", sourceURL: "https://acmelab.slack.com/files/U1/F1/x.pdf", title: nil)
        }
    }

    @Test("A Slack channel id is validated before any network call")
    func slackReadRejectsMalformedChannelIDs() async {
        let store = MCPDataStore()
        await #expect(throws: MCPError.self) {
            try await store.readSlackChannel(channelID: "", sinceDays: nil)
        }
        await #expect(throws: MCPError.self) {
            try await store.readSlackChannel(channelID: "../slack/candidates", sinceDays: nil)
        }
        await #expect(throws: MCPError.self) {
            try await store.readSlackChannel(channelID: "journal_club", sinceDays: nil)
        }
        await #expect(throws: MCPError.self) {
            try await store.readSlackThread(channelID: "C0EXAMPLE01", threadTS: "../files")
        }
        await #expect(throws: MCPError.self) {
            try await store.readSlackThread(channelID: "nexus", threadTS: "1788740520.000100")
        }
        await #expect(throws: MCPError.self) {
            try await store.searchSlackMessages(query: "   ", limit: nil, channelID: nil, sinceDays: nil, sort: nil)
        }
        await #expect(throws: MCPError.self) {
            try await store.searchSlackMessages(query: "amyloid", limit: nil, channelID: "../x", sinceDays: nil, sort: nil)
        }
    }

    @Test("The Slack plugin's state comes from the gateway's connected flag")
    func slackWorkspaceConnectionFromPayload() {
        // A gateway from before workspaces were listed: connected, no names.
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["connected": true, "channels": []]) == .connected(workspaces: []))
        // Several workspaces, named in connection order; one without a name yet is its team id.
        #expect(MCPDataStore.slackWorkspaceConnection(in: [
            "connected": true,
            "workspaces": [["team_id": "T0ACMELAB01", "workspace": "Acme Lab"], ["team_id": "T0BENCHLAB", "workspace": NSNull()]],
            "channels": [],
        ]) == .connected(workspaces: [
            .init(name: "Acme Lab", channelCount: nil, teamID: "T0ACMELAB01"),
            .init(name: "T0BENCHLAB", channelCount: nil, teamID: "T0BENCHLAB"),
        ]))
        // The channels enabled in each workspace travel with it, so the
        // plugins list can count them; `/slack/workspaces` names a
        // workspace as `team_name` and is read the same way.
        #expect(MCPDataStore.slackWorkspaceConnection(in: [
            "connected": true,
            "workspaces": [
                ["team_id": "T0ACMELAB01", "workspace": "Acme Lab", "channel_count": 4],
                ["team_id": "T0BENCHLAB", "team_name": "Bench Lab", "channel_count": 0],
            ],
        ]) == .connected(workspaces: [
            .init(name: "Acme Lab", channelCount: 4, teamID: "T0ACMELAB01"),
            .init(name: "Bench Lab", channelCount: 0, teamID: "T0BENCHLAB"),
        ]))
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["connected": true])?.isConnected == true)
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["connected": false])?.isConnected == false)
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["connected": false, "channels": []]) == .notConnected)
        // A payload that is not the channel list says nothing about the workspace.
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["error": "invalid_session"]) == nil)
        #expect(MCPDataStore.slackWorkspaceConnection(in: ["connected": "yes"]) == nil)
    }

    @Test("The Slack channel picker reads the gateway's conversation list")
    func slackWorkspaceChannelsFromPayload() {
        let picker = MCPDataStore.slackWorkspaceChannels(in: [
            "team_id": "T0ACMELAB01",
            "team_name": "Acme Lab",
            "reads_without_joining": true,
            "channels": [
                ["id": "C0EXAMPLE01", "name": "journal_club", "is_private": false, "is_member": true, "mode": "suggest"],
                ["id": "C0PRIVATE", "name": "leads", "is_private": true, "is_member": false, "mode": "off"],
                ["id": "C0NOMODE", "name": "general", "is_member": true],
                ["name": "no id, skipped"],
            ],
        ], teamID: "T0ACMELAB01")
        #expect(picker == .init(
            teamID: "T0ACMELAB01",
            teamName: "Acme Lab",
            readsWithoutJoining: true,
            channels: [
                .init(id: "C0EXAMPLE01", name: "journal_club", isPrivate: false, isMember: true, enabled: true),
                .init(id: "C0PRIVATE", name: "leads", isPrivate: true, isMember: false, enabled: false),
                .init(id: "C0NOMODE", name: "general", isPrivate: false, isMember: true, enabled: false),
            ]
        ))
        // A payload without a team name keeps the id the caller asked with, so
        // the card still knows which workspace it belongs to.
        let unnamed = MCPDataStore.slackWorkspaceChannels(in: ["team_name": "  ", "channels": []], teamID: "T0BENCHLAB")
        #expect(unnamed?.teamID == "T0BENCHLAB")
        #expect(unnamed?.teamName == nil)
        #expect(unnamed?.readsWithoutJoining == false)
        // Anything without a channel list is not a picker.
        #expect(MCPDataStore.slackWorkspaceChannels(in: ["error": "not_connected"], teamID: "T0") == nil)
    }

    @Test("The plugins list names what each connection reads")
    func pluginScopeCopy() {
        // Nothing to name keeps the plugin's own description (nil here).
        #expect(PluginScopeCopy.x(username: nil) == nil)
        #expect(PluginScopeCopy.x(username: " ") == nil)
        #expect(PluginScopeCopy.x(username: "robin") == "Imports bookmarks and saved posts from @robin.")

        #expect(PluginScopeCopy.youtube(source: nil, followedChannels: 0) == nil)
        #expect(PluginScopeCopy.youtube(source: "Liked videos", followedChannels: 0) == "Imports your Liked videos.")
        #expect(PluginScopeCopy.youtube(source: nil, followedChannels: 1) == "Follows 1 channel.")
        #expect(PluginScopeCopy.youtube(source: "ForeverLM playlist", followedChannels: 3)
            == "Imports your ForeverLM playlist and follows 3 channels.")

        #expect(PluginScopeCopy.googleDrive(folders: []) == nil)
        #expect(PluginScopeCopy.googleDrive(folders: ["Acme Nexus"]) == "Reads the folder Acme Nexus.")
        #expect(PluginScopeCopy.googleDrive(folders: ["Acme Nexus", "Team weekly"]) == "Reads the folders Acme Nexus and Team weekly.")
        // Only groups that still follow a Drive folder count: hidden and
        // merged-away groups are gone, a local folder is not Drive, and the
        // names come back in name order.
        let folders = PluginScopeCopy.googleDriveFolderNames(in: [
            "b": MeetingMetadata(title: "Team weekly", driveFolderURL: "https://drive.google.com/drive/folders/B"),
            "a": MeetingMetadata(title: "Acme Nexus", driveFolderURL: "https://drive.google.com/drive/folders/A"),
            "hidden": MeetingMetadata(title: "Old", driveFolderURL: "https://drive.google.com/drive/folders/H", isHidden: true),
            "merged": MeetingMetadata(title: "Merged", driveFolderURL: "https://drive.google.com/drive/folders/M", mergedIntoGroupID: "a"),
            "local": MeetingMetadata(title: "Local", localFolderPath: "/Users/me/Meetings"),
            "untitled": MeetingMetadata(driveFolderURL: "https://drive.google.com/drive/folders/U"),
        ])
        #expect(folders == ["Acme Nexus", "Team weekly", "untitled"])

        // The Google Drive pane draws each folder under the account that reads
        // it: the tag on the URL when there is one, the default account for an
        // untagged folder, and apart when the tagged account is gone.
        let tagged = GoogleDriveService.taggedURL("https://drive.google.com/drive/folders/B", accountID: "acct-2")
        let orphan = GoogleDriveService.taggedURL("https://drive.google.com/drive/folders/O", accountID: "acct-gone")
        let attribution = GoogleDriveFolderAttribution(
            metadata: [
                "a": MeetingMetadata(title: "Acme Nexus", driveFolderURL: "https://drive.google.com/drive/folders/A"),
                "b": MeetingMetadata(title: "Team weekly", driveFolderURL: tagged),
                "o": MeetingMetadata(title: "Orphan", driveFolderURL: orphan),
                "hidden": MeetingMetadata(title: "Old", driveFolderURL: "https://drive.google.com/drive/folders/H", isHidden: true),
                "local": MeetingMetadata(title: "Local", localFolderPath: "/Users/me/Meetings"),
            ],
            accountIDs: ["acct-1", "acct-2"],
            defaultAccountID: "acct-1"
        )
        #expect(attribution.folders(for: "acct-1").map(\.title) == ["Acme Nexus"])
        #expect(attribution.folders(for: "acct-2").map(\.title) == ["Team weekly"])
        #expect(attribution.folders(for: "acct-2").first?.url == URL(string: "https://drive.google.com/drive/folders/B"))
        #expect(attribution.folders(for: "acct-2").first?.accountID == "acct-2")
        #expect(attribution.unattributed.map(\.title) == ["Orphan"])
        // One account reads every untagged folder even without a default.
        let single = GoogleDriveFolderAttribution(
            metadata: ["a": MeetingMetadata(title: "Acme Nexus", driveFolderURL: "https://drive.google.com/drive/folders/A")],
            accountIDs: ["acct-9"],
            defaultAccountID: nil
        )
        #expect(single.folders(for: "acct-9").map(\.title) == ["Acme Nexus"])
        #expect(single.unattributed.isEmpty)

        #expect(PluginScopeCopy.slack([]) == nil)
        #expect(PluginScopeCopy.slack([.init(name: "Acme Lab", channelCount: 4), .init(name: "Bench Lab", channelCount: 1)])
            == "Reads 4 channels in Acme Lab and 1 channel in Bench Lab.")
        #expect(PluginScopeCopy.slack([.init(name: "Bench Lab", channelCount: 0)]) == "Reads no channels yet in Bench Lab.")
        // A gateway that counts nothing still names the workspaces.
        #expect(PluginScopeCopy.slack([.init(name: "Acme Lab", channelCount: 4), .init(name: "Bench Lab", channelCount: nil)])
            == "Reads channels in Acme Lab and Bench Lab.")

        #expect(PluginScopeCopy.linear(workspace: nil, user: nil) == nil)
        #expect(PluginScopeCopy.linear(workspace: "Bench Lab", user: "Robin Vale") == "Reads the Bench Lab workspace as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.linear(workspace: "Bench Lab", user: nil) == "Reads the Bench Lab workspace. Read-only.")
        #expect(PluginScopeCopy.linear(workspace: nil, user: "Robin Vale") == "Reads Linear as Robin Vale. Read-only.")

        #expect(PluginScopeCopy.github(login: nil, installations: []) == nil)
        #expect(PluginScopeCopy.github(login: "robinvale", installations: ["ForeverLM-HQ", "robinvale"])
            == "Reads ForeverLM-HQ and robinvale as @robinvale. Read-only.")
        #expect(PluginScopeCopy.github(login: "robinvale", installations: []) == "Reads GitHub as @robinvale. Read-only.")
        #expect(PluginScopeCopy.github(login: nil, installations: ["ForeverLM-HQ"]) == "Reads ForeverLM-HQ. Read-only.")

        #expect(PluginScopeCopy.notion(workspace: nil, user: nil) == nil)
        #expect(PluginScopeCopy.notion(workspace: "Bench Lab", user: "Robin Vale") == "Reads the Bench Lab workspace as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.notion(workspace: "Bench Lab", user: " ") == "Reads the Bench Lab workspace. Read-only.")
        #expect(PluginScopeCopy.notion(workspace: nil, user: "Robin Vale") == "Reads Notion as Robin Vale. Read-only.")
    }

    @Test("Slack links resolve to library sources by DOI first, canonical URL second")
    func slackReferenceMatching() {
        let paper = MCPDataStore.SlackLibraryCandidate(
            id: "paper-1", title: "Tau propagation", sourceType: "paper",
            url: "https://www.nature.com/articles/s41586-026-10493-9?utm_source=slack",
            normalizedURL: "nature.com/articles/s41586-026-10493-9",
            doi: "10.1038/s41586-026-10493-9", publishedDOI: nil
        )
        let article = MCPDataStore.SlackLibraryCandidate(
            id: "article-1", title: "  ", sourceType: "article",
            url: "https://investors.biogen.com/news-releases/news-release-details/topline-results",
            normalizedURL: "investors.biogen.com/news-releases/news-release-details/topline-results",
            doi: nil, publishedDOI: nil
        )
        let references = [
            "https://doi.org/10.1038/S41586-026-10493-9",
            "https://www.investors.biogen.com/news-releases/news-release-details/topline-results/#summary",
            "https://example.org/unrelated",
        ]

        let matches = MCPDataStore.matchSlackReferences(references, against: [paper, article])

        #expect(matches.count == 2)
        #expect(matches[0]["source_id"] as? String == "paper-1")
        #expect(matches[0]["match_basis"] as? String == "doi")
        #expect(matches[0]["title"] as? String == "Tau propagation")
        #expect(matches[0]["availability"] as? String == "already_in_foreverlm_library")
        #expect(matches[0]["next_tool"] as? String == "get_source_content")
        #expect(matches[1]["source_id"] as? String == "article-1")
        #expect(matches[1]["match_basis"] as? String == "url")
        #expect(matches[1]["title"] as? String == "Untitled source")

        #expect(MCPDataStore.slackReferenceDOI("doi: 10.1016/J.CELL.2026.01.001.") == "10.1016/j.cell.2026.01.001")
        #expect(MCPDataStore.slackReferenceDOI("https://dx.doi.org/10.1101/2026.05.11.724149v2") == "10.1101/2026.05.11.724149v2")
        #expect(MCPDataStore.slackReferenceDOI("https://www.cell.com/cell/fulltext/S0092-8674(26)00655-0") == nil)
        #expect(MCPDataStore.slackReferenceDOI("plain words") == nil)
    }

    @Test("Every ingest-allowed tool is a registered tool")
    func ingestAllowlistNamesRealTools() {
        let registered = Set(MCPToolRegistry.shared.tools.map(\.name))
        for name in MCPToolRegistry.ingestAllowedTools {
            #expect(registered.contains(name), "\(name) is allowlisted but not registered")
        }
    }

    @Test("Plugin logos are https-only and bounded")
    func pluginLogoValidation() {
        #expect(MCPOAuthProvider.validatedLogoURI("https://example.com/logo.png") == "https://example.com/logo.png")
        #expect(MCPOAuthProvider.validatedLogoURI("  https://example.com/logo.png ") == "https://example.com/logo.png")
        #expect(MCPOAuthProvider.validatedLogoURI("http://example.com/logo.png") == nil)
        #expect(MCPOAuthProvider.validatedLogoURI("data:image/png;base64,AAAA") == nil)
        #expect(MCPOAuthProvider.validatedLogoURI("javascript:alert(1)") == nil)
        #expect(MCPOAuthProvider.validatedLogoURI(nil) == nil)
        #expect(MCPOAuthProvider.validatedLogoURI("") == nil)
        #expect(MCPOAuthProvider.validatedLogoURI("https://e.com/" + String(repeating: "a", count: 2048)) == nil)
    }

    @Test("Ingest-scoped dispatch refuses out-of-scope tools in depth")
    func ingestDispatchRefusesOutOfScope() async {
        let ingest = MCPAccessContext(clientID: "dyn_test", scope: .ingest, connectorLabel: "Test Plugin")
        let outcome = await MCPToolRegistry.shared.callToolDetailed(
            name: "list_sources", arguments: [:], access: ingest
        )
        #expect(outcome.isError)
        #expect(outcome.text.contains("mcp:ingest"))
        #expect(outcome.text.contains("add_source"))
    }
}

// MARK: - MCP Tools Tests

@Suite("MCP Data Store", .cardWordingPasses)
struct MCPDataStoreTests {

    /// Create a temporary DB with the required schema and return the store + path.
    private func makeStore(syncGeneration: SyncGeneration = ForeverLMRuntimeIdentity.syncGeneration) throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath, syncGeneration: syncGeneration)

        // Install the real schema by opening the store against the fresh, empty
        // file: createSchema takes its full creation path and stamps
        // user_version, so these tests always run on exactly the schema
        // production creates. (A hand-written schema copy used to live here; it
        // drifted stale — no user_version stamp, missing newer columns — and
        // tripped the schema-version gate added in July 2026.)
        _ = try store.knowledgeStore()

        return (store, tmpDir.path)
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("A chat is filed under a Goal as well as a Notebook, and a pool of sources still refuses a Goal")
    func chatFiledUnderGoal() async throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let ks = try store.knowledgeStore()
        let now = Date()
        let notebook = try ks.createCompanionGoal(
            title: "Mitochondria", topic: "mitochondria", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let goal = try ks.createCompanionGoal(
            title: "Understand pooled in vivo screening", topic: "screens", startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        #expect(goal.isGoal && !goal.isNotebook)
        try ks.createReviewSession(id: "chat-1", topic: "The Missing Dimension in Pooled Screens", sourceIDs: [])

        // Moved onto the Goal, and back off it.
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: goal.id)
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == goal.id)
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: notebook.id)
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == notebook.id)
        _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: "")
        #expect(try ks.loadReviewSessionLinks().first { $0.id == "chat-1" }?.goalID == nil)

        // An id that names neither is refused with both lists named.
        #expect(throws: MCPError.self) {
            _ = try store.updateReviewSession(sessionID: "chat-1", title: nil, notebookID: "nothing-here")
        }
        // Where a Notebook's pool is meant, a Goal is still not one.
        #expect(throws: MCPError.self) {
            _ = try store.resolveMCPNotebookGoal(notebookID: goal.id, store: ks)
        }
        #expect(try store.resolveMCPChatHome(notebookID: goal.id, store: ks).id == goal.id)
        #expect(try store.resolveMCPChatHome(notebookID: notebook.id, store: ks).id == notebook.id)
    }

    /// Screen record mode's switches normally live in `UserDefaults.standard`,
    /// which every test in the process shares, and with a Dev build on this
    /// Mac. Runs `body` against a throwaway suite bound for this task only
    /// (`ScreenRecordMode.overrideDefaults`), so no neighbour sees the mode.
    private func withScreenRecordDefaults(_ body: () throws -> Void) throws {
        let suiteName = "MCPDataStoreTests.screenRecord.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MCPError.invalidInput("Could not open a defaults suite for the test.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ScreenRecordMode.$overrideDefaults.withValue(ScreenRecordMode.DefaultsOverride(defaults: defaults)) {
            try body()
        }
    }

    /// The product owner, 2026-09-24: a filmed "@ForeverLM" take must see only the
    /// recording Notebook's sources and what the take itself made. Everything
    /// here was made before the cutoff except the one source and the one
    /// chat stamped after it. A source added during the take shows only as a
    /// deliberate browser Reading List capture (70f8842), and older work filed
    /// under the recording Notebook stays off screen (560f8a8).
    @Test("Screen record mode narrows the connector's listings to the recording Notebook and the take's own work")
    func screenRecordModeNarrowsListings() throws {
        let (store, path) = try makeStore()
        defer { cleanup(path) }
        let ks = try store.knowledgeStore()
        let cutoff = Date().addingTimeInterval(5)
        let before = cutoff.addingTimeInterval(-3_600)
        let after = cutoff.addingTimeInterval(60)

        func seedArticle(_ id: String, title: String, addedAt: Date, origin: DiscoveryOrigin = .manual) throws {
            let url = "https://example.org/\(id)"
            var article = StudioArticle(url: url, title: title, sourceType: .article, discoveryOrigin: origin, id: id)
            article.domain = "example.org"
            article.normalizedURL = URLNormalizer.normalize(url)
            article.content = "Readable text this library holds for the test."
            article.wordCount = 8
            article.state = .ready
            article.dateAdded = addedAt
            try ks.saveSource(article)
        }
        try seedArticle("src-recording", title: "Recording Notebook paper", addedAt: before)
        try seedArticle("src-private", title: "Private older reading", addedAt: before)
        try seedArticle("src-during-take", title: "Saved during the take", addedAt: after, origin: .safari)
        try seedArticle("src-synced-during-take", title: "Arrived by sync during the take", addedAt: after)

        let recording = try ks.createCompanionGoal(
            title: "Filmed Notebook", topic: "demo", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["src-recording"]
        )
        let privateNotebook = try ks.createCompanionGoal(
            title: "Private Notebook", topic: "private", startAt: before, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["src-private"]
        )
        try ks.createReviewSession(id: "chat-recording", topic: "About the filmed paper", sourceIDs: ["src-recording"], startedAt: before)
        try ks.createReviewSession(id: "chat-filed", topic: "Filed under the filmed Notebook", sourceIDs: [], startedAt: before, goalID: recording.id)
        try ks.createReviewSession(id: "chat-private", topic: "An older private chat", sourceIDs: ["src-private"], startedAt: before)
        try ks.createReviewSession(id: "chat-during-take", topic: "Asked on camera", sourceIDs: [], startedAt: after)

        try withScreenRecordDefaults {
            ScreenRecordMode.setEnabled(true, now: cutoff)
            ScreenRecordMode.setNotebookID(recording.id)
            ScreenRecordMode.recordAdminStatus(true)
            #expect(ScreenRecordMode.isEffective)

            let sources = try store.listSources()
            #expect(sources.contains("src-recording"))
            #expect(sources.contains("src-during-take"))
            #expect(!sources.contains("src-synced-during-take"))
            #expect(!sources.contains("src-private"))

            let filtered = try store.filterSources(
                show: nil, author: nil, titleContains: nil, text: nil,
                sourceType: "article", includeArchived: false, limit: 50
            )
            #expect(filtered.contains("src-recording"))
            #expect(!filtered.contains("src-private"))

            let notebooks = try store.listNotebooks(includeCompleted: true)
            #expect(notebooks.contains(recording.id))
            #expect(!notebooks.contains(privateNotebook.id))
            #expect(throws: MCPError.self) {
                _ = try store.getNotebookDetail(notebookID: privateNotebook.id)
            }

            // A chat about a filmed source is still the learner's own, and so
            // is an older chat filed under the recording Notebook: only one
            // started on camera shows.
            let links = try store.listReviewSessionLinks()
            #expect(!links.contains("chat-filed"))
            #expect(links.contains("chat-during-take"))
            #expect(!links.contains("chat-recording"))
            #expect(!links.contains("chat-private"))
            let sessions = try store.getReviewSessions(topic: nil)
            #expect(!sessions.contains("chat-filed"))
            #expect(sessions.contains("chat-during-take"))
            #expect(!sessions.contains("chat-recording"))
            #expect(!sessions.contains("chat-private"))

            // The same stored switch on an account the proxy does not call an
            // admin is inert: every listing is whole again.
            ScreenRecordMode.recordAdminStatus(false)
            #expect(!ScreenRecordMode.isEffective)
            let allSources = try store.listSources()
            #expect(allSources.contains("src-private"))
            #expect(allSources.contains("src-recording"))
            #expect(try store.listNotebooks(includeCompleted: true).contains(privateNotebook.id))
            #expect(try store.listReviewSessionLinks().contains("chat-private"))
            #expect(try store.getReviewSessions(topic: nil).contains("chat-private"))
            _ = try store.getNotebookDetail(notebookID: privateNotebook.id)
        }
    }

    /// A source the store accepts as ready: `ready` needs durable readable text,
    /// so the row carries content the way an import leaves it.
    @discardableResult
    private static func seedReadySource(
        _ store: KnowledgeStore, id: String, url: String, title: String, sourceType: StudioSourceType,
        content: String = "Readable text this library holds for the test."
    ) throws -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: sourceType, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = content
        article.wordCount = content.split(separator: " ").count
        article.state = .ready
        try store.saveSource(article)
        return article
    }

    /// Re-importing a paper gives it a new source row and leaves the old Schedule
    /// placement behind. That placement's id is a digest of the paper's portable
    /// key (its DOI or normalized URL), so the new row lands on exactly the same
    /// id while the lookup — by source_id — finds nothing. Before 2026-09-18 the
    /// insert then failed the whole call with
    /// `UNIQUE constraint failed: scheduled_sources.id`, which is how
    /// get_source_content came to refuse to read a paper that had just been
    /// unarchived. The production store held 11 such orphaned placements.
    @Test("reads a source whose re-import left an orphaned Schedule placement behind")
    func adoptsOrphanedScheduledSourcePlacement() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore,
            id: "src-reimported",
            url: "https://doi.org/10.1038/s41586-026-10391-0",
            title: "Cell-type-targeted mitochondrial transplantation",
            sourceType: .article
        )

        let portableKey = try kstore.portableMemorySourceKey(sourceID: "src-reimported")
        let placementID = MemoryTutorIdentity.scheduledSourcePlacementID(portableSourceKey: portableKey)
        let now = Date().timeIntervalSinceReferenceDate
        // The row the earlier copy of this paper left behind: same placement id,
        // pointing at a source row that no longer exists.
        try execSQL(dbPath: "\(tmpPath)/knowledge.db", """
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES ('\(placementID)', 'src-deleted-original', \(now), \(now), NULL, \(now), \(now));
        """)

        // recordChatActivity is what get_source_content passes, and what used to
        // throw here.
        let content = try await store.getSourceContent("src-reimported", recordChatActivity: true)
        #expect(!content.isEmpty)

        // The orphan is adopted rather than duplicated: one row, now the live
        // source's, so the paper keeps the Schedule history it already had.
        // Generation 2 names a placement by its source (`pl:<source id>`, §3.5.21), so the
        // digest-named orphan is no clash to adopt: the live source gets its own row.
        let placements = try kstore.scheduledSourceID(forSource: "src-reimported")
        #expect(placements == (kstore.syncGeneration == .two ? "pl:src-reimported" : placementID))
    }


    @Test("A share request is made, listed with can_fulfil, answered with My Library's copy, and closed for everyone")
    func shareRequestTools() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let now = Date()
        try kstore.saveTeam(TeamRecord(
            id: "team-bench", name: "Bench Lab", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-bench"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        let held = try Self.seedReadySource(kstore, id: "src-held-book", url: "https://www.nature.com/articles/s41586-026-7", title: "Held book", sourceType: .book)

        // Ask, with the address spelled the way a Doc would cite it.
        let made = try await store.requestShare(teamID: "team-bench", url: "https://www.nature.com/articles/s41586-026-7?utm_source=doc", title: "Held paper", docID: nil)
        let madeJSON = try #require(try JSONSerialization.jsonObject(with: Data(made.utf8)) as? [String: Any])
        let request = try #require(madeJSON["request"] as? [String: Any])
        let requestID = try #require(request["id"] as? String)
        #expect(request["status"] as? String == "open")
        #expect(request["can_fulfil"] as? Bool == true, "this Mac holds the book, so it can answer")

        // Asking again while it stands returns the standing request.
        let again = try await store.requestShare(teamID: "team-bench", url: "https://www.nature.com/articles/s41586-026-7?utm_source=doc", title: nil, docID: nil)
        let againJSON = try #require(try JSONSerialization.jsonObject(with: Data(again.utf8)) as? [String: Any])
        #expect((againJSON["request"] as? [String: Any])?["id"] as? String == requestID)

        let listed = try await store.listShareRequests(teamID: nil, status: nil)
        let listedJSON = try #require(try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        #expect(listedJSON["count"] as? Int == 1)
        #expect(((listedJSON["requests"] as? [[String: Any]])?.first)?["team_name"] as? String == "Bench Lab")

        // Bad input is refused before anything is written.
        await #expect(throws: MCPError.self) {
            _ = try await store.requestShare(teamID: "team-bench", url: "not a url", title: nil, docID: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.listShareRequests(teamID: nil, status: "pending")
        }

        // Answering copies the source into the team and records the copy.
        let answered = try await store.fulfilShareRequest(requestID: requestID)
        let answeredJSON = try #require(try JSONSerialization.jsonObject(with: Data(answered.utf8)) as? [String: Any])
        let fulfilled = try #require(answeredJSON["request"] as? [String: Any])
        #expect(fulfilled["status"] as? String == "fulfilled")
        let copyID = try #require(fulfilled["team_copy_id"] as? String)
        #expect(kstore.activeSourceID(forReferenceURL: held.url, teamID: "team-bench") == copyID)
        #expect(try kstore.loadOpenShareRequests().isEmpty)

        // A closed request cannot be answered twice; a fresh one can be declined.
        await #expect(throws: MCPError.self) {
            _ = try await store.fulfilShareRequest(requestID: requestID)
        }
        // The team holds the source now, so a new request for it is refused.
        await #expect(throws: MCPError.self) {
            _ = try await store.requestShare(teamID: "team-bench", url: held.url, title: nil, docID: nil)
        }
        let other = try await store.requestShare(teamID: "team-bench", url: "https://example.org/not-held", title: "Not held", docID: nil)
        let otherJSON = try #require(try JSONSerialization.jsonObject(with: Data(other.utf8)) as? [String: Any])
        let otherRequest = try #require(otherJSON["request"] as? [String: Any])
        #expect(otherRequest["can_fulfil"] as? Bool == false, "nothing here to answer it with")
        let otherID = try #require(otherRequest["id"] as? String)
        await #expect(throws: MCPError.self) {
            _ = try await store.fulfilShareRequest(requestID: otherID)
        }
        let declined = try await store.declineShareRequest(requestID: otherID)
        let declinedJSON = try #require(try JSONSerialization.jsonObject(with: Data(declined.utf8)) as? [String: Any])
        #expect((declinedJSON["request"] as? [String: Any])?["status"] as? String == "declined")
        let all = try await store.listShareRequests(teamID: "team-bench", status: "all")
        let allJSON = try #require(try JSONSerialization.jsonObject(with: Data(all.utf8)) as? [String: Any])
        #expect(allJSON["count"] as? Int == 2)
    }

    @Test("Sharing a Doc carries the cited sources only this library holds by default, and reports what travelled")
    func shareDocWithCitedSources() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let now = Date()
        try kstore.saveTeam(TeamRecord(
            id: "team-bench", name: "Bench Lab", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-bench"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        let paper = try Self.seedReadySource(kstore, id: "src-closed-book", url: "https://doi.org/10.1038/s41586-026-8", title: "Closed book", sourceType: .book)
        _ = try Self.seedReadySource(kstore, id: "src-open-article", url: "https://example.org/open-article", title: "Open article", sourceType: .article)
        let markdown = """
        # Landscape

        The key result is in [the paper](https://doi.org/10.1038/s41586-026-8), summarised by [a post](https://example.org/open-article).
        A bare link https://example.org/nowhere-in-library follows.
        """
        let created = try await store.createArtifact(title: "Landscape", homeNotebookID: nil, notebookIDs: [], markdown: markdown)
        let createdJSON = try #require(try JSONSerialization.jsonObject(with: Data(created.utf8)) as? [String: Any])
        let docID = try #require((createdJSON["doc"] as? [String: Any])?["id"] as? String)

        #expect(StorageService.webReferences(in: markdown) == [
            "https://doi.org/10.1038/s41586-026-8", "https://example.org/open-article", "https://example.org/nowhere-in-library",
        ])
        let toCarry = try await store.notebookFileStorage.citedSourcesToCarry(artifactID: docID, teamID: "team-bench")
        #expect(toCarry.map(\.id) == [paper.id], "the book travels, as a paper would; the article is a fetch away and the third link is not held")

        await #expect(throws: MCPError.self) {
            _ = try await store.shareWithTeam(teamID: "team-bench", kind: "source", ids: [paper.id], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: true)
        }
        // Nothing asked: the cited source travels by default (docs/teams-design.md, decision 16).
        let shared = try await store.shareWithTeam(teamID: "team-bench", kind: "doc", ids: [docID], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: nil)
        let sharedJSON = try #require(try JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        let travelled = try #require(sharedJSON["cited_sources_shared"] as? [[String: Any]])
        #expect(travelled.count == 1)
        #expect(travelled.first?["original_id"] as? String == paper.id)
        #expect(kstore.activeSourceID(forReferenceURL: paper.url, teamID: "team-bench") == travelled.first?["team_copy_id"] as? String)
        #expect((sharedJSON["linked_sources_shared"] as? [[String: Any]])?.isEmpty == true, "the Doc links no source of its own")
        #expect((sharedJSON["sources_not_shared"] as? [[String: Any]])?.isEmpty == true)
        #expect((sharedJSON["message"] as? String)?.contains("1 source the team lacked travelled with it (0 linked, 1 cited)") == true)
        let remaining = try await store.notebookFileStorage.citedSourcesToCarry(artifactID: docID, teamID: "team-bench")
        #expect(remaining.isEmpty, "nothing left to carry once it travelled")
        let again = try await store.shareWithTeam(teamID: "team-bench", kind: "doc", ids: [docID], includeSources: nil, includeDocs: nil, includeChats: nil, includeCitedSources: nil)
        let againJSON = try #require(try JSONSerialization.jsonObject(with: Data(again.utf8)) as? [String: Any])
        #expect((againJSON["message"] as? String)?.contains("already held every source") == true)
    }

    /// Resolve the id of a source the store just reported adding, by its URL.
    private func sourceID(in store: MCPDataStore, url: String) throws -> String {
        let kstore = try store.knowledgeStore()
        let existing = kstore.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? kstore.sourceExistsByURL(url)
        return try #require(existing).id
    }

    @Test("A day accepts YYYY-MM-DD or an ISO8601 timestamp, and still refuses impossible ones")
    func scheduleDateAcceptsBothSpellings() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let plain = try store.parseScheduleDate("2026-07-26", calendar: calendar)
        #expect(calendar.dateComponents([.year, .month, .day], from: plain)
            == DateComponents(year: 2026, month: 7, day: 26))
        #expect(plain == calendar.startOfDay(for: plain))

        // What a model hands back after reading an `occurred` timestamp off a
        // source it just searched. This used to fail the whole source search,
        // one round before the tutor gave up and answered without the papers.
        #expect(try store.parseScheduleDate("2026-07-26T15:30:00Z", calendar: calendar) == plain)

        // Tolerance stops at dates that are not real: a lenient formatter would
        // roll this into August rather than say the model got it wrong.
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-07-32", calendar: calendar)
        }
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31", calendar: calendar)
        }
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("last Tuesday", calendar: calendar)
        }
    }

    @Test("A day accepts the timestamp spellings the tools themselves print back")
    func scheduleDateAcceptsPrintedTimestamps() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try store.parseScheduleDate("2026-06-10", calendar: calendar)

        // Exactly what a source search renders for a meeting — "occurred:
        // 2026-06-10 16:53 PDT". A model narrowing its next call hands the
        // string back verbatim, and refusing it meant refusing our own output.
        #expect(try store.parseScheduleDate("2026-06-10 16:53 PDT", calendar: calendar) == day)

        // Fractional seconds and a missing zone are both spellings of the same
        // day. The naive one is read in the learner's zone, not UTC: read as UTC
        // it would land on the 9th every afternoon west of Greenwich.
        #expect(try store.parseScheduleDate("2026-06-10T16:53:52.988Z", calendar: calendar) == day)
        #expect(try store.parseScheduleDate("2026-06-10T16:53:52", calendar: calendar) == day)
        #expect(try store.parseScheduleDate("2026-06-10T00:30:00", calendar: calendar) == day)

        // An offset names an instant, so it resolves to the local day that
        // instant falls on — 06:30 UTC is still the evening of the 9th in Los
        // Angeles, where the 10th does not start until 07:00 UTC.
        let ninth = try store.parseScheduleDate("2026-06-09", calendar: calendar)
        #expect(try store.parseScheduleDate("2026-06-10T06:30:00+00:00", calendar: calendar) == ninth)
        #expect(try store.parseScheduleDate("2026-06-10T07:30:00+00:00", calendar: calendar) == day)

        // Tolerance still stops where the value stops naming one day.
        for bad in ["2026", "2026-06", "06/10/2026", "last Tuesday", "2026-06-10 or so"] {
            #expect(throws: MCPError.self) {
                try store.parseScheduleDate(bad, calendar: calendar)
            }
        }
        // A day that does not exist is still refused when it arrives with a time.
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31 09:00 PST", calendar: calendar)
        }
    }

    @Test("A day accepts today, yesterday and tomorrow on the Mac's clock")
    func scheduleDateAcceptsRelativeDayWords() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-25T20:15:00-07:00"))
        let today = try store.parseScheduleDate("2026-09-25", calendar: calendar)

        // What a tutor sent for "quiz me on the videos I watched today", having
        // read "today" off the day-plan tools; refusing it failed the first call.
        #expect(try store.parseScheduleDate("today", calendar: calendar, now: now) == today)
        #expect(try store.parseScheduleDate(" Today ", calendar: calendar, now: now) == today)
        #expect(try store.parseScheduleDate("yesterday", calendar: calendar, now: now)
            == store.parseScheduleDate("2026-09-24", calendar: calendar))
        #expect(try store.parseScheduleDate("tomorrow", calendar: calendar, now: now)
            == store.parseScheduleDate("2026-09-26", calendar: calendar))
        #expect(throws: MCPError.self) {
            try store.parseScheduleDate("last Tuesday", calendar: calendar, now: now)
        }
    }

    @Test("A bare year is refused, and the refusal names the field and the value")
    func scheduleDateRefusesBareYearByName() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let calendar = Calendar(identifier: .gregorian)

        // What a model sends after reading the publication year off a book it
        // was asked about. The arguments of a failed tool call are not shown
        // anywhere, so the message is the only record of what it sent.
        for bad in ["2021", "2024-03"] {
            let error = #expect(throws: MCPError.self) {
                try store.parseScheduleDate(bad, calendar: calendar, field: "date_from")
            }
            let message = try #require(error?.localizedDescription)
            #expect(message.contains("date_from"))
            #expect(message.contains("\"\(bad)\""))
            #expect(message.contains("YYYY-MM-DD"))
        }

        let impossible = #expect(throws: MCPError.self) {
            try store.parseScheduleDate("2026-02-31", calendar: calendar, field: "date_to")
        }
        #expect(impossible?.localizedDescription.contains("date_to \"2026-02-31\"") == true)
    }

    @Test("A source search dated with a year says which axis the date is on")
    func sourceSearchDateRefusalNamesTheAddedAxis() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // The search filters on the day a source was added, not when it was
        // published. If the refusal only fixed the spelling, the retry would
        // pass "2021-01-01" and silently find nothing.
        do {
            _ = try await store.searchSourcesSemantic(queryText: "Nick Lane Transformer", addedFrom: "2021")
            Issue.record("a bare year should not have been accepted")
        } catch let error as MCPError {
            let message = error.localizedDescription
            #expect(message.contains("added_from \"2021\""))
            #expect(message.contains("added to the library"))
            #expect(message.contains("not on when it was published"))
        }
    }

    @Test("add_source refuses a Codex site, names link_page, and writes nothing")
    func addSourceRefusesLinkedPages() throws {
        // The product owner (2026-09-09): "codex sites should always obviously be ingested
        // as a 'site' not as an article". Content passed with it changes nothing:
        // the page is a site whatever the caller read off it.
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let site = "https://techbio-companies-landscape.learner-1234.chatgpt.site/"

        let refusal = #expect(throws: MCPError.self) {
            try store.addSource(
                url: site,
                title: "TechBio companies landscape",
                sourceType: "article",
                content: "Sign in required",
                parentGroup: nil,
                author: nil
            )
        }
        let message = try #require(refusal?.localizedDescription)
        #expect(message.contains("Codex Site"))
        #expect(message.contains("link_page"))
        #expect(message.contains("Sites"))
        #expect(try store.knowledgeStore().sourceExistsByURL(site) == nil)

        // The other linked kinds are refused the same way, with their own name.
        for (url, label) in [
            ("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d", "Claude Artifact"),
            ("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/edit", "Google Doc"),
        ] {
            let error = #expect(throws: MCPError.self) {
                try store.addSource(url: url, title: label, sourceType: "article", content: nil, parentGroup: nil, author: nil)
            }
            #expect(error?.localizedDescription.contains(label) == true, "\(url)")
            #expect(error?.localizedDescription.contains("link_page") == true, "\(url)")
        }

        // A plugin's batch reports the refusal per item and keeps going.
        let batch = try store.addSources([
            ["url": site, "title": "TechBio companies landscape", "source_type": "article"],
            ["url": "https://example.com/essay", "title": "Essay", "source_type": "article", "content": "Text"],
        ], connectorLabel: nil)
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 failed (of 2)"))
        #expect(batch.contains("[0] Error:"))
        #expect(batch.contains("link_page"))
        #expect(batch.contains("[1] Added source 'Essay'"))
        #expect(try store.knowledgeStore().sourceExistsByURL(site) == nil)
    }

    /// 2026-09-28: two Peter Attia episodes added through add_source were
    /// listed under the channel "www.youtube.com", out of reach of a `show`
    /// search, because the row took the URL's host for its channel and waited
    /// for the app's backfill to name it. The uploader looked up before the
    /// save is the channel from the start.
    @Test("add_source files a YouTube video under its uploader's channel, and under the host only when none was found")
    func addSourceFilesVideoUnderItsChannel() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://www.youtube.com/watch?v=EuPcbF9YVTo",
            title: "Preventing cardiovascular and Alzheimer's disease",
            sourceType: "video",
            content: "The transcript.",
            parentGroup: nil,
            author: nil,
            videoChannel: "Peter Attia MD"
        )
        _ = try store.addSource(
            url: "https://www.youtube.com/watch?v=GoNjdK-I0Bc",
            title: "Inside modern drug development",
            sourceType: "video",
            content: "The transcript.",
            parentGroup: nil,
            author: nil,
            videoChannel: nil
        )

        let shows = try store.listShows(kind: "youtube")
        #expect(shows.contains("[youtube] Peter Attia MD — 1 episode"))
        #expect(shows.contains("[youtube] www.youtube.com — 1 episode"))
        let attia = try store.filterSources(show: "Attia", author: nil, titleContains: nil, text: nil,
                                            sourceType: "video", includeArchived: false, limit: 10)
        #expect(attia.contains("Preventing cardiovascular"))
        #expect(!attia.contains("Inside modern drug development"))

        // The lookup waits on YouTube, so the tool takes the store gate only
        // for its save rather than holding it across the request.
        #expect(MCPToolRegistry.selfGatedToolNames.contains("add_source"))
    }

    @Test("A new source's domain is a video's channel when one was found, and the URL's host otherwise")
    func newSourceDomainPrefersVideoChannel() {
        let video = "https://www.youtube.com/watch?v=JuoVZkPBiKk"
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: " Stanford Online ") == "Stanford Online")
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: nil) == "www.youtube.com")
        #expect(MCPDataStore.newSourceDomain(url: video, sourceType: .video, parentGroup: nil, videoChannel: "  ") == "www.youtube.com")
        // Only a video's domain is a channel.
        #expect(MCPDataStore.newSourceDomain(url: "https://example.com/essay", sourceType: .article, parentGroup: nil, videoChannel: "Stanford Online") == "example.com")
        #expect(MCPDataStore.newSourceDomain(url: "notes", sourceType: .manual, parentGroup: "Reading notes", videoChannel: nil) == "Reading notes")
    }

    @Test("Only a YouTube video's uploader is looked up before add_source saves it")
    func uploaderLookupSkipsWhatIsNotAYouTubeVideo() async {
        // None of these reaches YouTube: each answers nil before any request.
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://www.youtube.com/watch?v=JuoVZkPBiKk", sourceType: "article") == nil)
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://vimeo.com/76979871", sourceType: "video") == nil)
        #expect(await MCPDataStore.uploaderChannelForNewVideo(url: "https://www.youtube.com/playlist?list=PLoROMvodv4rMqXOcazWaTUHhq-yembLCV", sourceType: "video") == nil)
    }

    @Test("add_source refuses a Convoke query result on every route and writes nothing")
    func addSourceRefusesConvokeResults() throws {
        // The product owner (2026-09-12): "convoke bio results should not be ingested as
        // a source in foreverlm". These are the two addresses the plugin
        // labelled "ForeverLM Convoke Bio" pushed that day; content changes
        // nothing, a query result is not a page whatever the caller read.
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let result = "https://platform.convoke.bio/mcp#foreverlm-7e5456abb77e57b4e1e45b41"
        let synced = "https://platform.convoke.bio/mcp?foreverlm_sync=fb2cc9b56d17b44f1f08d5df"

        let refusal = #expect(throws: MCPError.self) {
            try store.addSource(
                url: result,
                title: "Convoke — active mitochondrial disease programs",
                sourceType: "article",
                content: "Program list",
                parentGroup: nil,
                author: nil,
                connectorLabel: "ForeverLM Convoke Bio"
            )
        }
        let message = try #require(refusal?.localizedDescription)
        #expect(message.contains("Convoke"))
        #expect(message.contains("not sources"))
        #expect(try store.knowledgeStore().sourceExistsByURL(result) == nil)

        // A plugin's batch reports the refusal per item and keeps going.
        let batch = try store.addSources([
            ["url": synced, "title": "Convoke — Friedreich ataxia catalysts through 2027-09-12", "source_type": "article", "content": "Catalysts"],
            ["url": "https://insights.convoke.bio/unmet-needs", "title": "Unmet Needs Index", "source_type": "article", "content": "Text"],
        ], connectorLabel: "ForeverLM Convoke Bio")
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 failed (of 2)"))
        #expect(batch.contains("[0] Error:"))
        #expect(batch.contains("Convoke"))
        #expect(batch.contains("[1] Added source 'Unmet Needs Index'"))
        #expect(try store.knowledgeStore().sourceExistsByURL(synced) == nil)
        #expect(try store.knowledgeStore().sourceExistsByURL("https://insights.convoke.bio/unmet-needs") != nil)
    }

    @Test("Plugin adds stamp origin and label from the authenticated client")
    func pluginAddsStampProvenance() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let result = try store.addSource(
            url: "https://example.com/feed/1",
            title: "Feed Item",
            sourceType: "article",
            content: "Plugin-pushed content",
            parentGroup: nil,
            author: nil,
            connectorLabel: "Readwise Sync"
        )
        #expect(result.contains("Added source 'Feed Item'"))

        let id = try sourceID(in: store, url: "https://example.com/feed/1")
        let article = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(article.connectorLabel == "Readwise Sync")
        #expect(article.discoveryOrigin == .plugin)

        // A plain add (full-scope assistant or in-app) stays unlabeled manual.
        _ = try store.addSource(
            url: "https://example.com/manual/1",
            title: "Manual Item",
            sourceType: "article",
            content: "By hand",
            parentGroup: nil,
            author: nil
        )
        let manualID = try sourceID(in: store, url: "https://example.com/manual/1")
        let manual = try #require(try store.knowledgeStore().loadSourceForSync(manualID))
        #expect(manual.connectorLabel == nil)
        #expect(manual.discoveryOrigin == .manual)
    }

    @Test("A chapter added without its book is refused, not filed loose")
    func addSourceRequiresBookGroup() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let chapterPath = "Books/Radical Life Extension/Chapters/02 1) The Current Situation.xhtml"
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: chapterPath,
                title: "1) The Current Situation",
                sourceType: "book",
                content: "Chapter one",
                parentGroup: nil,
                author: nil
            )
        }
        // Nothing may be left behind by the refusal: an ungrouped chapter is a
        // row the Books tab shows as a loose path, and no later pass files it.
        #expect(try store.knowledgeStore().sourceExistsByURL(chapterPath) == nil)

        _ = try store.addSource(
            url: chapterPath,
            title: "1) The Current Situation",
            sourceType: "book",
            content: "Chapter one",
            parentGroup: "Radical Life Extension",
            author: nil
        )
        let id = try sourceID(in: store, url: chapterPath)
        let chapter = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(chapter.parentGroup == "Radical Life Extension")
    }

    @Test("A podcast host's link is filed as an episode to look up, whatever type the caller gave")
    func podcastHostLinkIsFiledAsPodcast() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // 2026-10-02: with no podcast to pick, an assistant filed an Apple
        // Podcasts episode as a video, its page standing in for a transcript.
        let episode = "https://podcasts.apple.com/us/podcast/roche-will-pay-manifold-bio/id1796836887?i=1000735033082"
        let answer = try store.addSource(
            url: episode,
            title: "Roche will pay Manifold Bio $55M up front",
            sourceType: "video",
            content: "Search Home New Top Charts Sign In BiotechTV - News 16m Episode Webpage",
            parentGroup: nil,
            author: nil
        )
        #expect(answer.contains("type: podcast"))
        #expect(answer.contains("Filed as a podcast, not video"))
        #expect(answer.contains("not kept"))
        let episodeID = try sourceID(in: store, url: episode)
        let filed = try #require(try store.knowledgeStore().loadSourceForSync(episodeID))
        #expect(filed.sourceType == .podcast)
        #expect(try store.knowledgeStore().loadSourceContent(episodeID) == nil)
        // Queued with no text, so the app's first fetch finds it on Apple Podcasts.
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(filed, alreadyAttempted: []))

        // A show's own episode page is a podcast when the caller says so.
        let showPage = "https://a16z.com/podcast/can-america-win-the-ai-biotech-race-against-china/"
        _ = try store.addSource(
            url: showPage,
            title: "Can America Win The AI Biotech Race Against China?",
            sourceType: "podcast",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let named = try #require(try store.knowledgeStore().loadSourceForSync(try sourceID(in: store, url: showPage)))
        #expect(named.sourceType == .podcast)

        // A video elsewhere keeps its type and its transcript.
        let talk = "https://vimeo.com/123456789"
        _ = try store.addSource(
            url: talk,
            title: "A talk",
            sourceType: "video",
            content: "What the speaker said",
            parentGroup: nil,
            author: nil
        )
        let talkID = try sourceID(in: store, url: talk)
        let video = try #require(try store.knowledgeStore().loadSourceForSync(talkID))
        #expect(video.sourceType == .video)
        #expect(try store.knowledgeStore().loadSourceContent(talkID) == "What the speaker said")
    }

    @Test("Branded meeting plugins preserve their provider origin")
    func meetingPluginPreservesProviderOrigin() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "meeting://Study%20Group/Weekly%20Review%20-%202026/08/31%2010:00",
            title: "Weekly Review - 2026/08/31 10:00",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "Study Group",
            author: nil,
            connectorLabel: "Read AI"
        )
        let id = try sourceID(
            in: store,
            url: "meeting://Study%20Group/Weekly%20Review%20-%202026/08/31%2010:00"
        )
        let meeting = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(meeting.connectorLabel == "Read AI")
        #expect(meeting.discoveryOrigin == .readAI)

        _ = try store.addSource(
            url: "https://example.com/read-ai-article",
            title: "Not a meeting",
            sourceType: "article",
            content: "Article",
            parentGroup: nil,
            author: nil,
            connectorLabel: "Read AI"
        )
        let articleID = try sourceID(in: store, url: "https://example.com/read-ai-article")
        let article = try #require(try store.knowledgeStore().loadSourceForSync(articleID))
        #expect(article.discoveryOrigin == .plugin)
    }

    @Test("Plugin paper inbox accepts only that plugin's staged PDFs")
    func pluginPaperInboxIsConfined() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let response = try store.getConnectorInbox(connectorLabel: "Test Paper Plugin")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        let inboxPath = try #require(payload["path"] as? String)
        let inboxURL = URL(fileURLWithPath: inboxPath, isDirectory: true)
        let stagedPDF = inboxURL.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4 staged".utf8).write(to: stagedPDF)

        let accepted = try store.validatePluginStagedPDF(
            stagedPDF.path,
            connectorLabel: "Test Paper Plugin"
        )
        #expect(accepted.path == stagedPDF.path)

        let outsidePDF = URL(fileURLWithPath: tmpPath).appendingPathComponent("outside.pdf")
        try Data("%PDF-1.4 outside".utf8).write(to: outsidePDF)
        #expect(throws: MCPError.self) {
            try store.validatePluginStagedPDF(
                outsidePDF.path,
                connectorLabel: "Test Paper Plugin"
            )
        }

        let otherInbox = try store.pluginInboxURL(connectorLabel: "Another Plugin")
        let otherPDF = otherInbox.appendingPathComponent("other.pdf")
        try Data("%PDF-1.4 other".utf8).write(to: otherPDF)
        #expect(throws: MCPError.self) {
            try store.validatePluginStagedPDF(
                otherPDF.path,
                connectorLabel: "Test Paper Plugin"
            )
        }
    }

    @Test("Plugin paper URLs reject local and private targets")
    func pluginPaperURLsRejectPrivateTargets() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        #expect(try store.validatePluginPaperURL("doi:10.1000/example") == "https://doi.org/10.1000/example")
        #expect(try store.validatePluginPaperURL("https://arxiv.org/abs/2401.00001") == "https://arxiv.org/abs/2401.00001")

        for blocked in [
            "http://localhost/paper.pdf",
            "http://127.0.0.1/paper.pdf",
            "http://10.0.0.5/paper.pdf",
            "http://192.168.1.5/paper.pdf",
            "http://[::1]/paper.pdf",
            "https://papers.local/paper.pdf",
            "https://example.com/paper.pdf",
            "https://arxiv.org:8443/abs/2401.00001",
            "http://arxiv.org/abs/2401.00001",
        ] {
            #expect(throws: MCPError.self) {
                try store.validatePluginPaperURL(blocked)
            }
        }
    }

    @Test("Ingest updates are confined to the plugin's own sources")
    func ingestUpdatesConfinedToOwnSources() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/feed/2", title: "Owned", sourceType: "article",
            content: "v1", parentGroup: nil, author: nil, connectorLabel: "Readwise Sync"
        )
        _ = try store.addSource(
            url: "https://example.com/manual/2", title: "User's Own", sourceType: "article",
            content: "precious", parentGroup: nil, author: nil
        )
        let ownedID = try sourceID(in: store, url: "https://example.com/feed/2")
        let usersID = try sourceID(in: store, url: "https://example.com/manual/2")

        // Own source: allowed, content and word count refresh.
        let ok = try store.updateSourceContent(
            sourceID: ownedID, url: nil, content: "v2 has four words",
            title: nil, author: nil, restrictToPluginLabel: "Readwise Sync"
        )
        #expect(ok.contains("Updated content"))
        let updated = try #require(try store.knowledgeStore().loadSourceForSync(ownedID))
        #expect(updated.wordCount == 4)

        // The user's own source: refused for the ingest caller.
        let refusedUsers = try store.updateSourceContent(
            sourceID: usersID, url: nil, content: "overwritten",
            title: nil, author: nil, restrictToPluginLabel: "Readwise Sync"
        )
        #expect(refusedUsers.hasPrefix("Error:"))
        #expect(refusedUsers.contains("can only update sources it added itself"))

        // Another plugin's source: refused too.
        let refusedOther = try store.updateSourceContent(
            sourceID: ownedID, url: nil, content: "hijacked",
            title: nil, author: nil, restrictToPluginLabel: "Other Plugin"
        )
        #expect(refusedOther.hasPrefix("Error:"))

        // Full scope (no restriction) may update anything.
        let fullOK = try store.updateSourceContent(
            sourceID: usersID, url: nil, content: "assistant fixed the extraction",
            title: nil, author: nil, restrictToPluginLabel: nil
        )
        #expect(fullOK.contains("Updated content"))
    }

    @Test("add_sources batches per-item results and respects the cap")
    func addSourcesBatchesPerItem() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/batch/existing", title: "Already Here", sourceType: "article",
            content: "old", parentGroup: nil, author: nil, connectorLabel: "Feed Bot"
        )

        let result = try store.addSources([
            ["url": "https://example.com/batch/a", "title": "A", "source_type": "article", "content": "aaa"],
            ["url": "https://example.com/batch/b", "title": "B", "source_type": "article"],
            ["url": "https://example.com/batch/existing", "title": "Already Here", "source_type": "article"],
            ["url": "https://example.com/batch/existing", "title": "Already Here", "source_type": "article",
             "content": "refreshed text", "update_existing": true],
            ["url": "", "title": "", "source_type": "article"],
        ], connectorLabel: "Feed Bot")

        #expect(result.contains("2 added"))
        #expect(result.contains("1 updated"))
        #expect(result.contains("1 already existed"))
        #expect(result.contains("1 failed"))

        let refreshedID = try sourceID(in: store, url: "https://example.com/batch/existing")
        let refreshed = try #require(try store.knowledgeStore().loadSourceForSync(refreshedID))
        #expect(refreshed.wordCount == 2)

        let oversized = try store.addSources(
            (0..<(MCPToolRegistry.maxBatchSourceItems + 1)).map {
                ["url": "https://example.com/over/\($0)", "title": "N\($0)", "source_type": "article"]
            },
            connectorLabel: nil
        )
        #expect(oversized.hasPrefix("Error:"))
        #expect(oversized.contains("at most \(MCPToolRegistry.maxBatchSourceItems)"))
    }

    @Test("A plugin meeting is dated by occurred_at and filed under its series by parent_group")
    func addSourceDatesMeetingByOccurredAtAndFilesItUnderItsSeries() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let occurred = try #require(MCPDataStore.parseFlexibleTimestamp("2026-08-19T16:54:00Z"))

        // What the Read AI plugin pushes: an https URL, not the app's own
        // meeting:// scheme, so nothing about the series can be read off it.
        let added = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0819",
            title: "[EF] Aging Biology Study Group - 2026/08/19 09:54",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "Aging Biology Study Group",
            author: "Robin",
            occurredAt: "2026-08-19T16:54:00Z",
            connectorLabel: "Read AI Meetings"
        )
        #expect(added.contains("meeting: Aging Biology Study Group"))
        #expect(added.contains("occurred_at: 2026-08-19T16:54:00Z"))

        let id = try sourceID(in: store, url: "https://app.read.ai/analytics/meetings/01J1AGING0819")
        let meeting = try #require(try kstore.loadSourceForSync(id))
        #expect(meeting.dateAdded == occurred)
        // The group was created from the title, and the meeting sits in it.
        let groupID = try #require(try kstore.resolvedMeetingGroupID(matching: "Aging Biology Study Group"))
        #expect(meeting.parentGroup == groupID)
        #expect(try kstore.loadMeetingGroups()[groupID]?.title == "Aging Biology Study Group")
        // The Meetings tab's own date column is the same instant.
        let storedOccurredAt = try scalarString(
            dbPath: tmpPath + "/knowledge.db",
            "SELECT occurred_at FROM meeting_sources WHERE source_id = '\(id)'"
        )
        #expect(storedOccurredAt.flatMap(Double.init).map { abs($0 - occurred.timeIntervalSinceReferenceDate) < 0.001 } == true)

        // The next week's session names the series in a different case and
        // joins the same group instead of spawning a second one.
        _ = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0902",
            title: "[EF] Aging Biology Study Group",
            sourceType: "meeting",
            content: "Transcript",
            parentGroup: "aging biology study group",
            author: nil,
            occurredAt: "2026-09-02T16:55:00Z",
            connectorLabel: "Read AI Meetings"
        )
        let secondID = try sourceID(in: store, url: "https://app.read.ai/analytics/meetings/01J1AGING0902")
        #expect(try kstore.loadSourceForSync(secondID)?.parentGroup == groupID)
        #expect(try kstore.loadMeetingGroups().count == 1)

        // Only meetings have a date of their own, and a date has to parse:
        // silently ignoring either would recreate the bug this field fixes.
        #expect(throws: MCPError.self) {
            try store.addSource(
                url: "https://example.com/dated-article", title: "Dated", sourceType: "article",
                content: "x", parentGroup: nil, author: nil, occurredAt: "2026-09-02T16:55:00Z"
            )
        }
        #expect(throws: MCPError.self) {
            try store.addSource(
                url: "https://app.read.ai/analytics/meetings/BADDATE", title: "Bad date", sourceType: "meeting",
                content: "x", parentGroup: nil, author: nil, occurredAt: "last Tuesday"
            )
        }
    }

    @Test("add_source will not bring back a source the learner removed")
    func addSourceHonoursTheLearnersRemoval() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let url = "https://examplefellowship.zoom.us/rec/share/ExampleShareAAAA0000111122223333"
        let title = "Robin <> Zara standup"

        // Filed once — the way the recordings mailbox files a Zoom notice — then
        // removed in the app: `removeSelected` dismisses the URL and archives
        // the row, and deleting the series later takes the row away altogether.
        // Both shapes have to refuse; the second used to be re-added, because
        // only the row's existence was ever asked.
        _ = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil,
            parentGroup: title, author: nil, occurredAt: "2026-09-09T17:39:09Z"
        )
        let id = try sourceID(in: store, url: url)
        try kstore.dismissSource(url: url, title: title)
        #expect(try kstore.loadSourceForSync(id)?.status == .archived)

        let archivedAnswer = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(archivedAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(archivedAnswer.contains("removed by the learner"))
        #expect(try kstore.loadSourceForSync(id)?.status == .archived)

        try kstore.deleteSource(id)
        let goneAnswer = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(goneAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(kstore.sourceExistsByURL(url)?.id == nil)

        // The batch form counts the refusal apart from an addition and a failure.
        let batch = try store.addSources([
            ["url": url, "title": title, "source_type": "meeting"],
            ["url": "https://example.com/fresh-article", "title": "Fresh", "source_type": "article", "content": "Text"],
        ], connectorLabel: nil)
        #expect(batch.contains("1 added, 0 updated, 0 already existed, 1 removed by the learner, 0 failed (of 2)"))
        #expect(kstore.sourceExistsByURL(url)?.id == nil)

        // Only the learner lifts it: an explicit re-add in the app clears the
        // tombstone, and the same call then adds.
        try kstore.undismissSource(url: url)
        let readded = try store.addSource(
            url: url, title: title, sourceType: "meeting", content: nil, parentGroup: title, author: nil
        )
        #expect(readded.hasPrefix("Added source"))
    }

    @Test("add_source will not stand a removed meeting series back up")
    func addSourceHonoursARemovedMeetingSeries() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let identityKey = StudioViewModel.removedMeetingGroupIdentitiesKey
        let titleKey = StudioViewModel.removedMeetingGroupTitlesKey
        let priorIdentities = UserDefaults.standard.stringArray(forKey: identityKey)
        let priorTitles = UserDefaults.standard.stringArray(forKey: titleKey)
        defer {
            if let priorIdentities {
                UserDefaults.standard.set(priorIdentities, forKey: identityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: identityKey)
            }
            if let priorTitles {
                UserDefaults.standard.set(priorTitles, forKey: titleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleKey)
            }
        }
        let groupID = "zoom:examplefellowship.zoom.us"
        let seriesTitle = "Robin <> Zara standup"
        let nextRecording = "https://examplefellowship.zoom.us/rec/share/ExampleShareBBBB4444555566667777"
        // What removeMeetingGroup records for a Zoom-account series.
        UserDefaults.standard.set(["group:\(groupID)"], forKey: identityKey)
        UserDefaults.standard.set([seriesTitle], forKey: titleKey)

        // The series is gone (deleted once the Undo window closed): its title,
        // in any case, must not create it again.
        let gone = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: "robin <> zara standup", author: nil, occurredAt: "2026-09-10T02:19:46Z"
        )
        #expect(gone.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(gone.contains("meeting series"))
        #expect(try kstore.loadMeetingGroups().isEmpty)
        #expect(kstore.sourceExistsByURL(nextRecording)?.id == nil)

        // While the Undo notice is up the series row is hidden and tombstoned:
        // the same answer, and nothing filed into the hidden row.
        var hidden = MeetingMetadata(title: seriesTitle)
        hidden.isHidden = true
        try kstore.saveMeetingGroup(name: groupID, metadata: hidden)
        let hiddenAnswer = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: seriesTitle, author: nil
        )
        #expect(hiddenAnswer.hasPrefix(MCPDataStore.removedByLearnerPrefix))
        #expect(try kstore.loadSources().isEmpty)

        // A series the learner has visibly back is a series to file into,
        // whatever an older title tombstone still says.
        hidden.isHidden = false
        try kstore.saveMeetingGroup(name: groupID, metadata: hidden)
        let filed = try store.addSource(
            url: nextRecording, title: seriesTitle, sourceType: "meeting", content: nil,
            parentGroup: seriesTitle, author: nil
        )
        #expect(filed.contains("group_id: \(groupID)"))
        #expect(try kstore.loadSourceForSync(try sourceID(in: store, url: nextRecording))?.parentGroup == groupID)

        // A series that was never removed is created from its title as before.
        let other = try store.addSource(
            url: "https://app.read.ai/analytics/meetings/01J1AGING0819", title: "Aging Biology", sourceType: "meeting",
            content: "Transcript", parentGroup: "Aging Biology Study Group", author: nil
        )
        #expect(other.contains("meeting: Aging Biology Study Group"))
        #expect(try kstore.resolvedMeetingGroupID(matching: "Aging Biology Study Group") != nil)
    }

    @Test("A re-push with update_existing corrects a meeting's date and series")
    func addSourcesUpdateExistingCorrectsMeetingDateAndSeries() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let url = "https://app.read.ai/analytics/meetings/01J1BIOSTASIS0806"

        // The first push, from before the plugin sent either field: the
        // meeting is dated by the push and belongs to no series.
        let first = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1"],
        ], connectorLabel: "Read AI Meetings")
        #expect(first.contains("1 added"))
        let id = try sourceID(in: store, url: url)
        let before = try #require(try kstore.loadSourceForSync(id))
        #expect(before.parentGroup == nil)
        #expect(abs(before.dateAdded.timeIntervalSinceNow) < 60)

        // `sync --force`: the same item again with update_existing and both fields.
        let occurred = try #require(MCPDataStore.parseFlexibleTimestamp("2026-08-06T16:52:00Z"))
        let second = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1", "update_existing": true,
             "occurred_at": "2026-08-06T16:52:00Z", "parent_group": "Biostasis Working Group Sync (15 mins)"],
        ], connectorLabel: "Read AI Meetings")
        #expect(second.contains("1 updated"))
        #expect(second.contains("occurred_at, parent_group"))
        let after = try #require(try kstore.loadSourceForSync(id))
        #expect(after.dateAdded == occurred)
        let groupID = try #require(try kstore.resolvedMeetingGroupID(matching: "Biostasis Working Group Sync (15 mins)"))
        #expect(after.parentGroup == groupID)
        #expect(try scalarInt(
            dbPath: tmpPath + "/knowledge.db",
            "SELECT COUNT(*) FROM group_members WHERE source_id = '\(id)' AND group_id = '\(groupID)'"
        ) == 1)

        // Pushing the identical item a third time changes nothing and says so
        // per field: the date and series are already right.
        let third = try store.addSources([
            ["url": url, "title": "[EF] Biostasis Working Group Sync (15 mins) - 2026/08/06 09:52",
             "source_type": "meeting", "content": "Transcript v1", "update_existing": true,
             "occurred_at": "2026-08-06T16:52:00Z", "parent_group": "Biostasis Working Group Sync (15 mins)"],
        ], connectorLabel: "Read AI Meetings")
        #expect(third.contains("1 updated"))
        #expect(!third.contains("occurred_at"))
        #expect(!third.contains("parent_group"))

        // A bad date on an update is that item's failure, not the batch's.
        let bad = try store.addSources([
            ["url": url, "title": "x", "source_type": "meeting", "content": "Transcript v1",
             "update_existing": true, "occurred_at": "yesterday"],
            ["url": "https://app.read.ai/analytics/meetings/01J1OTHER", "title": "Other", "source_type": "meeting",
             "content": "t", "occurred_at": "2026-09-01T10:00:00Z", "parent_group": "One-off"],
        ], connectorLabel: "Read AI Meetings")
        #expect(bad.contains("1 added"))
        #expect(bad.contains("1 failed"))
        #expect(bad.contains("[0] Error:"))
        #expect(bad.contains("ISO 8601"))
    }

    @Test("remove_connector_sources removes exactly the plugin's sources")
    func removePluginSourcesRemovesOwnOnly() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/rm/1", title: "R1", sourceType: "article",
            content: "x", parentGroup: nil, author: nil, connectorLabel: "Doomed Plugin"
        )
        _ = try store.addSource(
            url: "https://example.com/rm/2", title: "R2", sourceType: "article",
            content: "y", parentGroup: nil, author: nil, connectorLabel: "Doomed Plugin"
        )
        _ = try store.addSource(
            url: "https://example.com/rm/keep", title: "Keep", sourceType: "article",
            content: "z", parentGroup: nil, author: nil
        )

        let result = try store.removePluginSources(label: "Doomed Plugin")
        #expect(result.contains("Removed 2 of 2"))

        let kstore = try store.knowledgeStore()
        #expect(try kstore.activeSourceIDs(withPluginLabel: "Doomed Plugin").isEmpty)
        let keptID = try sourceID(in: store, url: "https://example.com/rm/keep")
        let kept = try #require(try kstore.loadSourceForSync(keptID))
        #expect(kept.status == .active)

        #expect(try store.removePluginSources(label: "Doomed Plugin")
            .contains("No active sources found"))
        #expect(try store.removePluginSources(label: "  ").hasPrefix("Error:"))
    }

    @Test("Knowledge exclusions follow source-family policy; hiding is visual and excludes nothing")
    func knowledgeSearchExcludedSourceIDs() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "read-ai",
            title: "Read AI meeting",
            content: "meeting notes",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.readAI.rawValue
        )
        try insertSource(
            dbPath: dbPath,
            id: "drive",
            title: "Drive meeting",
            content: "meeting notes",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.googleDriveMeetings.rawValue
        )
        try insertSource(
            dbPath: dbPath,
            id: "zoom",
            title: "Zoom recording",
            content: "recording transcript",
            sourceType: "meeting",
            discoveryOrigin: DiscoveryOrigin.zoom.rawValue,
            url: "https://example.zoom.us/rec/share/abc"
        )
        try insertSource(dbPath: dbPath, id: "hidden", title: "Hidden", content: "private notes")

        let knowledgeStore = try store.knowledgeStore()
        try knowledgeStore.setSourceHidden("hidden", hidden: true)
        let excluded = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [.meetings])

        // Meetings is one knowledge family across every provider, so excluding
        // it excludes the Drive and Zoom sessions as well as the Read AI one.
        //
        // This is a deliberate narrowing. The split tabs allowed "exclude Read
        // AI meetings from AI discovery but keep Drive meetings", because the
        // exclusion preference is keyed by tab and provider decided the tab.
        // One tab makes it all-or-nothing. Getting that back means a
        // provider-level preference of its own, which is the honest shape for a
        // provider-level policy — not a side effect of which tab a session sat in.
        #expect(excluded.contains("read-ai"))
        #expect(excluded.contains("drive"))
        #expect(excluded.contains("zoom"))
        // Hiding takes a source off the sources list and nowhere else
        // (product owner, 2026-09-11): it stays in knowledge.
        #expect(!excluded.contains("hidden"))

        // And with Meetings included, no provider's meetings are excluded.
        let meetingsIncluded = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [.videos])
        #expect(!meetingsIncluded.contains("read-ai"))
        #expect(!meetingsIncluded.contains("drive"))
        #expect(!meetingsIncluded.contains("zoom"))
        #expect(!meetingsIncluded.contains("hidden"))
        // And with nothing excluded, nothing is excluded — hidden or not.
        #expect(try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: []).isEmpty)

        // A hidden show is the exception: its episodes are muted for the AI
        // too, except one the learner unhid on its own. A show that is merely
        // hidden episode by episode is not.
        var muted = StudioArticle(url: "https://pod.example/muted-1", title: "Muted episode", sourceType: .podcast, id: "muted-1")
        muted.domain = "Muted Show"
        var unhidden = StudioArticle(url: "https://pod.example/muted-2", title: "Unhidden episode", sourceType: .podcast, id: "muted-2")
        unhidden.domain = "Muted Show"
        var loose = StudioArticle(url: "https://pod.example/loose", title: "Hidden by itself", sourceType: .podcast, id: "loose-hidden")
        loose.domain = "Open Show"
        for episode in [muted, unhidden, loose] {
            try knowledgeStore.saveSource(episode)
        }
        try knowledgeStore.setPodcastShowHidden("Muted Show", hidden: true)
        try knowledgeStore.setPodcastEpisodeVisibleOverride("muted-2", visible: true)
        try knowledgeStore.setSourceHidden("loose-hidden", hidden: true)
        let mutedShow = try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: [])
        #expect(mutedShow == ["muted-1"])
        try knowledgeStore.setPodcastShowHidden("Muted Show", hidden: false)
        #expect(try knowledgeStore.knowledgeSearchExcludedSourceIDs(excludedTabs: []).isEmpty)
    }

    @Test("Keyword search still sees hidden sources; an excluded family is skipped and its cap counts only what it shows")
    func keywordSearchSeesHiddenSourcesAndSkipsExcludedFamilies() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Hiding is visual (product owner, 2026-09-11): a hidden lecture leaves the
        // sources list and stays answerable, so search still returns it.
        // An article, since course material belongs to no Sources family and
        // so is never excluded by one (courses-design.md).
        try insertSource(dbPath: dbPath, id: "hidden-lecture", title: "MCB 80: Lecture 19 - Critical periods and aging",
                         content: "Alzheimer's disease and the aging brain", sourceType: "article")
        try insertSource(dbPath: dbPath, id: "paper-a", title: "Amyloid paper", content: "Alzheimer's disease pathology", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "paper-b", title: "Tau paper", content: "Alzheimer's disease and tau", sourceType: "paper")
        try store.knowledgeStore().setSourceHidden("hidden-lecture", hidden: true)

        let sweep = try store.searchSourcesKeyword(keywords: ["Alzheimer"])
        #expect(sweep.contains("paper-a"))
        #expect(sweep.contains("paper-b"))
        #expect(sweep.contains("hidden-lecture"))

        // Narrowed to articles, the hidden lecture is the answer.
        let articles = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "article")
        #expect(articles.contains("hidden-lecture"))

        // A source family excluded from knowledge in Settings is the boundary
        // that still applies, and an excluded row must not consume the page:
        // two visible matches fit a cap of two exactly, so the answer is
        // complete, not "2+".
        let defaults = UserDefaults.standard
        let key = StudioSidebarTab.knowledgeExclusionPreferenceKey
        let priorExclusion = defaults.stringArray(forKey: key)
        defer {
            if let priorExclusion { defaults.set(priorExclusion, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set([StudioSidebarTab.articles.rawValue], forKey: key)
        #expect(try store.knowledgeStore().knowledgeSearchExcludedSourceIDs(includeArchived: true) == ["hidden-lecture"])
        let page = try store.searchSourcesKeyword(keywords: ["Alzheimer"], limit: 2)
        #expect(page.contains("paper-a"))
        #expect(page.contains("paper-b"))
        #expect(!page.contains("hidden-lecture"))
        #expect(page.contains("2 sources"))
        #expect(!page.contains("2+"))

        // And a cap of one is honestly truncated by the visible remainder.
        let one = try store.searchSourcesKeyword(keywords: ["Alzheimer"], limit: 1)
        #expect(one.contains("1+ sources"))
        #expect(!one.contains("hidden-lecture"))
    }

    @Test("The article family covers manually added and unclassified web pages")
    func keywordSearchArticleFamilyCoversWebPageStates() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(dbPath: dbPath, id: "web-article", title: "Classified article", content: "Alzheimer's disease research", sourceType: "article")
        try insertSource(dbPath: dbPath, id: "web-manual", title: "Manually added page", content: "Alzheimer's disease notes", sourceType: "manual")
        try insertSource(dbPath: dbPath, id: "web-pending", title: "Page awaiting classification", content: "Alzheimer's disease preprint", sourceType: "unclassified")
        try insertSource(dbPath: dbPath, id: "paper-a", title: "Amyloid paper", content: "Alzheimer's disease pathology", sourceType: "paper")

        // One filter, every saved web page: the schema offers article alone.
        let articles = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "article")
        #expect(articles.contains("web-article"))
        #expect(articles.contains("web-manual"))
        #expect(articles.contains("web-pending"))
        #expect(!articles.contains("paper-a"))
        #expect(articles.contains("3 sources"))

        // The storage states are still accepted from an older schema and mean
        // the same family, so a stale client gets the same answer.
        let pending = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "unclassified")
        #expect(pending == articles)

        // Other families stay exact.
        let papers = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "paper")
        #expect(papers.contains("paper-a"))
        #expect(!papers.contains("web-manual"))

        // And the schema no longer offers the storage states, only families.
        let schema = MCPToolRegistry(store: MCPDataStore()).tools
            .first { $0.name == "search_sources_keyword" }?
            .inputSchema["properties"] as? [String: Any]
        let offered = (schema?["source_type"] as? [String: Any])?["enum"] as? [String]
        #expect(offered == StudioSourceType.searchFamilyNames)
        #expect(offered?.contains("unclassified") == false)
        #expect(offered?.contains("manual") == false)

        #expect(throws: MCPError.self) {
            _ = try store.searchSourcesKeyword(keywords: ["Alzheimer"], sourceType: "slack")
        }
    }

    @Test("Keyword search reads only the named sources, takes 30 keywords, and names the ones found nowhere")
    func keywordSearchScopesToNamedSources() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // The 2026-09-23 chat on two papers asked which of one paper's compounds
        // the other shares; a third paper naming them must stay out of the sweep.
        try insertSource(dbPath: dbPath, id: "twin", title: "Digital twin paper",
                         content: "Cells were treated with nocodazole and stained with MitoTracker Green; ATP was measured.", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "cardiac", title: "Cardiac paper",
                         content: "Sestamibi uptake fell after CCCP; ATP and calcium were measured.", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "elsewhere", title: "Unrelated paper",
                         content: "Nocodazole and CCCP appear here too.", sourceType: "paper")

        let scoped = try store.searchSourcesKeyword(
            keywords: ["nocodazole", "CCCP", "ATP", "oligomycin"],
            sourceIDs: ["twin", "cardiac"]
        )
        #expect(scoped.contains("id: twin"))
        #expect(scoped.contains("id: cardiac"))
        #expect(!scoped.contains("elsewhere"))
        #expect(scoped.contains("among the 2 given sources"))
        #expect(scoped.contains("In none of them: \"oligomycin\"."))

        // Thirty keywords go in one call; past that the refusal says how to split.
        let thirty = (1...30).map { "compound\($0)" }
        _ = try store.searchSourcesKeyword(keywords: thirty, sourceIDs: ["twin"])
        do {
            _ = try store.searchSourcesKeyword(keywords: thirty + ["compound31"])
            Issue.record("31 keywords should be refused")
        } catch MCPError.invalidInput(let message) {
            #expect(message.contains("has 31"))
            #expect(message.contains("several calls"))
        }

        // An id that is no source is refused rather than quietly searching nothing.
        #expect(throws: MCPError.self) {
            _ = try store.searchSourcesKeyword(keywords: ["ATP"], sourceIDs: ["no-such-source"])
        }

        // The schema carries the cap, so a model sees it before it calls.
        let schema = MCPToolRegistry(store: MCPDataStore()).tools
            .first { $0.name == "search_sources_keyword" }?
            .inputSchema["properties"] as? [String: Any]
        #expect((schema?["keywords"] as? [String: Any])?["maxItems"] as? Int == SourceKeywordSearch.maximumKeywords)
        #expect(schema?["source_ids"] != nil)
    }

    @Test("Keyword search finds a keyword that is not ASCII, and ASCII keywords the text spells with ligatures")
    func keywordSearchFoldsCaseBeyondASCII() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Bioenergetics Chapter 4 said Δψ 58 times, and the single keyword
        // "Δψ" answered that no source contains it (2026-09-26): SQL bound it
        // lowercased, as δψ, and LIKE folds only ASCII case.
        try insertSource(dbPath: dbPath, id: "chapter-4", title: "Chapter 4: Chemiosmotic Energy Transduction",
                         content: "Δp is dominant. The membrane potential (Δψ) and ΔpH add up; ΔΨ is the same quantity.", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "worksheet", title: "Math 21 B: worksheet27",
                         content: "Diﬀerential Operators. Previously on Math 21b...", sourceType: "course")
        try insertSource(dbPath: dbPath, id: "german", title: "Stadtplan", content: "Die Straße nach Wien.")
        try insertSource(dbPath: dbPath, id: "english", title: "Unrelated", content: "This sis sa text about proton leak.")

        let greek = try store.searchSourcesKeyword(keywords: ["Δψ"])
        #expect(greek.contains("id: chapter-4"))
        #expect(greek.contains("Δψ ×2"))
        let lowercase = try store.searchSourcesKeyword(keywords: ["δψ"])
        #expect(lowercase.contains("id: chapter-4"))
        #expect(lowercase.contains("δψ ×2"))
        let mixed = try store.searchSourcesKeyword(keywords: ["ΔpH", "membrane"], matchAll: true)
        #expect(mixed.contains("id: chapter-4"))

        // PDFs extract "ff" as U+FB00, and a sweep for the ASCII word must
        // still find it; so must "strasse" find "Straße".
        let ligature = try store.searchSourcesKeyword(keywords: ["Differential Operators"])
        #expect(ligature.contains("id: worksheet"))
        let sharpS = try store.searchSourcesKeyword(keywords: ["strasse"])
        #expect(sharpS.contains("id: german"))

        // And "ß" means those letters, not "s" and any character after it.
        let strict = try store.searchSourcesKeyword(keywords: ["ß"])
        #expect(strict.contains("id: german"))
        #expect(!strict.contains("id: english"))
        #expect(strict.contains("ß ×1"))
    }

    @Test("Every source type a tool schema offers is one the tool accepts")
    func toolSchemasOfferOnlyKnownSourceTypes() throws {
        var checked = 0
        for tool in MCPToolRegistry(store: MCPDataStore()).tools {
            guard let properties = tool.inputSchema["properties"] as? [String: Any] else { continue }
            var offered: [String] = []
            if let single = properties["source_type"] as? [String: Any],
               let values = single["enum"] as? [String] {
                offered += values
            }
            if let many = properties["source_types"] as? [String: Any],
               let items = many["items"] as? [String: Any],
               let values = items["enum"] as? [String] {
                offered += values
            }
            for value in offered {
                checked += 1
                let accepted: StudioSourceType? = tool.name == "generate_source_audio"
                    ? MCPDataStore.audioGenerationSourceType(named: value)
                    : StudioSourceType(rawValue: value)
                #expect(accepted != nil, "\(tool.name) offers source type '\(value)', which the app has no source family for")
            }
        }
        // The search tools and the audio tool all carry a type list; a schema
        // refactor that drops them should be noticed here, not by a caller.
        #expect(checked >= 3)
    }

    /// "Look at the latest YouTube video" (2026-09-22) came back with another
    /// recent video: the chat reached for a ranked search, which orders by
    /// similarity. filter_sources with only a type is the recency listing, and
    /// it prints the minute so same-day imports read in order.
    @Test("filter_sources by type alone lists the most recently added first, with the time it was added")
    func filterSourcesLatestOfAType() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "video-morning", title: "Morning upload", content: "a", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "video-afternoon", title: "Afternoon upload", content: "b", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "video-yesterday", title: "Yesterday's upload", content: "c", sourceType: "video")
        try insertSource(dbPath: dbPath, id: "paper-newest", title: "Newest paper", content: "d", sourceType: "paper")
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 22; parts.hour = 9; parts.minute = 5
        let morning = try #require(Calendar.current.date(from: parts))
        let afternoon = morning.addingTimeInterval(6 * 3600)
        let yesterday = morning.addingTimeInterval(-86400)
        try execSQL(dbPath: dbPath, """
            UPDATE sources SET date_added = \(morning.timeIntervalSinceReferenceDate) WHERE id = 'video-morning';
            UPDATE sources SET date_added = \(afternoon.timeIntervalSinceReferenceDate) WHERE id = 'video-afternoon';
            UPDATE sources SET date_added = \(yesterday.timeIntervalSinceReferenceDate) WHERE id = 'video-yesterday';
            UPDATE sources SET date_added = \(afternoon.addingTimeInterval(60).timeIntervalSinceReferenceDate) WHERE id = 'paper-newest';
        """)

        let latest = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                             sourceType: "video", includeArchived: false, limit: 1)
        let lines = latest.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("3 sources, showing the 1 most recently added"))
        #expect(lines[1].contains("video-afternoon") && lines[1].contains("added 2026-09-22 15:05"))
        #expect(!latest.contains("paper-newest"))

        let all = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                          sourceType: "video", includeArchived: false, limit: 10)
        let order = ["video-afternoon", "video-morning", "video-yesterday"].map { all.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order[0]! < order[1]! && order[1]! < order[2]!)
    }

    /// 2026-09-22: "which Huberman episodes are on mitochondria" was answered
    /// by a ranked search over the whole library, where every other show's
    /// mitochondria episode competed for eight slots and the Jared Rutter
    /// episode never surfaced. A show or author is metadata, and listing by it
    /// has to be exhaustive.
    @Test("filter_sources lists every episode of a show and every paper by an author; a show scopes both searches")
    func filterSourcesByShowAndAuthor() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "ep-rutter", title: "How Mitochondria Control Your Metabolism | Dr. Jared Rutter",
                         content: "pyruvate enters the mitochondria", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-picard", title: "Improve Energy & Longevity by Optimizing Mitochondria | Dr. Martin Picard",
                         content: "mitochondria signal", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-sleep", title: "Master Your Sleep", content: "adenosine builds up", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "ep-other", title: "Mitochondria with Martin Picard", content: "mitochondria everywhere", sourceType: "podcast")
        try insertSource(dbPath: dbPath, id: "paper-picard", title: "Mitochondrial psychobiology", content: "energy", sourceType: "paper")
        try insertSource(dbPath: dbPath, id: "paper-else", title: "Unrelated biology", content: "cells", sourceType: "paper")
        try execSQL(dbPath: dbPath, """
            UPDATE podcasts SET domain = 'Huberman Lab', show_name = 'Huberman Lab' WHERE source_id IN ('ep-rutter', 'ep-picard', 'ep-sleep');
            UPDATE podcasts SET domain = 'Mind & Matter', show_name = 'Mind & Matter' WHERE source_id = 'ep-other';
            UPDATE papers SET author = 'Martin Picard, Carmen Sandi' WHERE source_id = 'paper-picard';
            UPDATE papers SET author = 'Someone Else' WHERE source_id = 'paper-else';
        """)

        let shows = try store.listShows(kind: nil)
        #expect(shows.contains("[podcast] Huberman Lab — 3 episodes"))
        #expect(shows.contains("[podcast] Mind & Matter — 1 episode"))

        // Part of the name is enough, and every episode comes back.
        let huberman = try store.filterSources(show: "huberman", author: nil, titleContains: nil, text: nil,
                                               sourceType: nil, includeArchived: false, limit: 200)
        #expect(huberman.contains("ep-rutter") && huberman.contains("ep-picard") && huberman.contains("ep-sleep"))
        #expect(!huberman.contains("ep-other"))
        #expect(huberman.contains("3 sources"))

        let hubermanMito = try store.filterSources(show: "Huberman Lab", author: nil, titleContains: "mitochondria", text: nil,
                                                   sourceType: nil, includeArchived: false, limit: 200)
        #expect(hubermanMito.contains("ep-rutter") && hubermanMito.contains("ep-picard") && !hubermanMito.contains("ep-sleep"))

        let byAuthor = try store.filterSources(show: nil, author: "picard", titleContains: nil, text: nil,
                                               sourceType: "paper", includeArchived: false, limit: 200)
        #expect(byAuthor.contains("paper-picard") && !byAuthor.contains("paper-else"))

        // "Everything with Martin Picard": guest in a title or author of a paper.
        let person = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "Martin Picard",
                                             sourceType: nil, includeArchived: false, limit: 200)
        #expect(person.contains("ep-picard") && person.contains("ep-other") && person.contains("paper-picard"))
        #expect(!person.contains("ep-rutter"))

        #expect(throws: MCPError.self) {
            _ = try store.filterSources(show: nil, author: nil, titleContains: nil, text: nil,
                                        sourceType: nil, includeArchived: false, limit: 200)
        }
        #expect(throws: MCPError.self) {
            _ = try store.filterSources(show: "No Such Show", author: nil, titleContains: nil, text: nil,
                                        sourceType: nil, includeArchived: false, limit: 200)
        }

        // The keyword sweep scoped to the show leaves the other show's episode out.
        let sweep = try store.searchSourcesKeyword(keywords: ["mitochondria"], show: "Huberman")
        #expect(sweep.contains("ep-rutter") && sweep.contains("ep-picard"))
        #expect(!sweep.contains("ep-other"))

        // A show alone is enough for the semantic tool to list that show.
        let listed = try await store.searchSourcesSemantic(queryText: "", show: "Huberman Lab")
        #expect(listed.contains("ep-rutter") && listed.contains("ep-sleep") && !listed.contains("ep-other"))
    }

    /// A book is stored as chapter-level sources; its title and author live on
    /// the book record, not on the chapters. "Do I have Power, Sex, Suicide by
    /// Nick Lane?" answered no (2026-10-03) because `author` and `text` only
    /// read the chapter rows.
    @Test("filter_sources finds a book's chapters by the book's title and author")
    func filterSourcesFindsBookChaptersByBookTitleAndAuthor() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "chapter-5", title: "5) Proton Power", content: "chemiosmosis", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "chapter-6", title: "6) The Dynamo", content: "membranes", sourceType: "book")
        try insertSource(dbPath: dbPath, id: "other-chapter", title: "1) Intro", content: "other", sourceType: "book")
        try execSQL(dbPath: dbPath, """
            INSERT INTO books (id, title, author) VALUES ('book-power', 'Power, Sex, Suicide', 'Nick Lane');
            INSERT INTO books (id, title, author) VALUES ('book-other', 'Another Book', 'Someone Else');
            INSERT INTO group_members (source_id, group_id, sort_index)
            VALUES ('chapter-5', 'book-power', 5), ('chapter-6', 'book-power', 6), ('other-chapter', 'book-other', 1);
        """)

        let byAuthor = try store.filterSources(show: nil, author: "Nick Lane", titleContains: nil, text: nil,
                                               sourceType: nil, includeArchived: false, limit: 200)
        #expect(byAuthor.contains("chapter-5") && byAuthor.contains("chapter-6") && !byAuthor.contains("other-chapter"))
        #expect(byAuthor.contains("by Nick Lane"))

        let byText = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "nick lane",
                                             sourceType: "book", includeArchived: false, limit: 200)
        #expect(byText.contains("chapter-5") && !byText.contains("other-chapter"))

        let byBookTitle = try store.filterSources(show: nil, author: nil, titleContains: nil, text: "Power, Sex, Suicide",
                                                  sourceType: nil, includeArchived: false, limit: 200)
        #expect(byBookTitle.contains("chapter-5") && byBookTitle.contains("chapter-6") && !byBookTitle.contains("other-chapter"))
    }

    private func insertSource(
        dbPath: String,
        id: String,
        title: String,
        content: String,
        sourceType: String = "article",
        discoveryOrigin: String = "test",
        url: String? = nil
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for source insert")
        }
        defer { sqlite3_close(db) }

        var sourceStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO sources (id, date_added, state, source_type, status)
            VALUES (?, ?, ?, ?, 'active')
        """, -1, &sourceStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test source insert")
        }
        defer { sqlite3_finalize(sourceStmt) }

        sqlite3_bind_text(sourceStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(sourceStmt, 2, 0)
        sqlite3_bind_text(sourceStmt, 3, ("ready" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(sourceStmt, 4, (sourceType as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sourceStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test source insert")
        }

        let subtypeTable: String
        switch sourceType {
        case "paper": subtypeTable = "papers"
        case "podcast": subtypeTable = "podcasts"
        case "book": subtypeTable = "book_sources"
        case "course": subtypeTable = "course_sources"
        case "meeting": subtypeTable = "meeting_sources"
        case "video": subtypeTable = "videos"
        case "xPost": subtypeTable = "x_posts"
        default: subtypeTable = "articles"
        }
        var subtypeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO \(subtypeTable) (source_id, url, normalized_url, title, domain, discovery_origin, word_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, -1, &subtypeStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test subtype insert")
        }
        defer { sqlite3_finalize(subtypeStmt) }
        sqlite3_bind_text(subtypeStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let sourceURL = url ?? "https://example.com/\(id)"
        sqlite3_bind_text(subtypeStmt, 2, (sourceURL as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 3, (sourceURL as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 4, (title as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 5, ("example.com" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(subtypeStmt, 6, (discoveryOrigin as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(subtypeStmt, 7, Int64(content.split(separator: " ").count))
        guard sqlite3_step(subtypeStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test subtype insert")
        }

        var contentStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO source_content (source_id, content) VALUES (?, ?)", -1, &contentStmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare test content insert")
        }
        defer { sqlite3_finalize(contentStmt) }

        sqlite3_bind_text(contentStmt, 1, (id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(contentStmt, 2, (content as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(contentStmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute test content insert")
        }
    }

    private func execSQL(dbPath: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw MCPError.database(message)
        }
    }

    private func scalarInt(dbPath: String, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare scalar query")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func scalarString(dbPath: String, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare scalar query")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    private func parsedSessionID(from response: String) -> String {
        response
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .replacingOccurrences(of: "Session ID: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func makeTestPDF(at url: URL, text: String) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 640)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MCPError.invalidInput("Could not create test PDF")
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
        NSString(string: text).draw(
            in: CGRect(x: 36, y: 120, width: 340, height: 480),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        try (data as Data).write(to: url)
    }

    private func insertFTS(dbPath: String, id: String, title: String, author: String = "", body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for full-text insert")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO source_fts (source_id, title, author, body) VALUES (?, ?, ?, ?)
        """, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare full-text insert")
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 3, (author as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 4, (body as NSString).utf8String, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to insert full-text row")
        }
    }

    private func insertEmbedding(dbPath: String, entityId: String, vector: [Float]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw MCPError.database("Failed to open test DB for embedding insert")
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO embeddings (entity_type, entity_id, model, vector, updated_at)
            VALUES (?, ?, ?, ?, ?)
        """, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPError.database("Failed to prepare embedding insert")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ("source" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (entityId as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, (StorageService.sourceEmbeddingModel as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = vector.withUnsafeBufferPointer { buffer in
            sqlite3_bind_blob(stmt, 4, buffer.baseAddress, Int32(buffer.count * MemoryLayout<Float>.size), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_double(stmt, 5, 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MCPError.database("Failed to execute embedding insert")
        }
    }

    /// A timebound Goal (a companion row with a deadline and no Notebook) whose
    /// sources are in its pool and placed on the Schedule, tagged with it.
    private func insertScheduleGoal(
        dbPath: String,
        goalID: String,
        startAt: Date,
        endAt: Date,
        items: [(id: String, sourceID: String, addedAt: Date, completedAt: Date?)]
    ) throws {
        let now = startAt.timeIntervalSinceReferenceDate
        try execSQL(dbPath: dbPath, """
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind)
            VALUES ('\(goalID)', 'Study plan', \(startAt.timeIntervalSinceReferenceDate), \(endAt.timeIntervalSinceReferenceDate), \(now), \(now), 'active', 'companion');
        """)
        for item in items {
            let completedSQL = item.completedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "NULL"
            try execSQL(dbPath: dbPath, """
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at)
                VALUES ('\(item.id)', '\(goalID)', '\(item.sourceID)', \(item.addedAt.timeIntervalSinceReferenceDate), \(completedSQL));
            """)
            // The Schedule tools read shared placements now: one scheduled_sources row
            // per source (planned day + completion), tagged to goals via
            // scheduled_source_goals. Each test source may appear in only one goal
            // (source_id is UNIQUE on scheduled_sources).
            let addedAtSQL = "\(item.addedAt.timeIntervalSinceReferenceDate)"
            try execSQL(dbPath: dbPath, """
                INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
                VALUES ('\(item.id)', '\(item.sourceID)', \(addedAtSQL), \(addedAtSQL), \(completedSQL), \(now), \(now));
            """)
            try execSQL(dbPath: dbPath, """
                INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
                VALUES ('\(item.id)', '\(goalID)', \(addedAtSQL));
            """)
        }
    }

    private func insertCompletedReviewSession(dbPath: String, sessionID: String, sourceID: String, endedAt: Date) throws {
        try execSQL(dbPath: dbPath, """
            INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary)
            VALUES ('\(sessionID)', 'Review', \(endedAt.addingTimeInterval(-600).timeIntervalSinceReferenceDate), \(endedAt.timeIntervalSinceReferenceDate), 'completed', 0.9, 'Reviewed');
            INSERT INTO review_session_sources (session_id, source_id)
            VALUES ('\(sessionID)', '\(sourceID)');
        """)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidInput("Expected JSON object")
        }
        return object
    }

    // MARK: - add_source

    @Test("addSource rejects paper bypasses that cannot run the mandatory LLM gate")
    func addSourceRejectsPaperBypass() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: "https://example.com/paper.pdf",
                title: "Test Paper",
                sourceType: "paper",
                content: "This is the full text of the paper.",
                parentGroup: nil,
                author: "John Doe"
            )
        }
        let list = try store.listSources()
        #expect(!list.contains("Test Paper"))
    }

    @Test("addSource creates a course source with parent_group")
    func addSourceToCourse() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let result = try store.addSource(
            url: "/path/to/lecture.pdf",
            title: "Lecture 1 - Intro",
            sourceType: "course",
            content: "Lecture notes content.",
            parentGroup: "ML 101",
            author: nil
        )

        #expect(result.contains("course: ML 101"))
    }

    @Test("addSource refuses a course source with no course to belong to")
    func addSourceRejectsCourselessCourseSource() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // The Courses tab lists courses, so course material outside one would be
        // a library row nothing can show. Ask for the course instead of adding it.
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: "/path/to/handout.pdf",
                title: "Handout",
                sourceType: "course",
                content: "Handout content.",
                parentGroup: nil,
                author: nil
            )
        }
        #expect(throws: MCPError.self) {
            _ = try store.addSource(
                url: "/path/to/handout.pdf",
                title: "Handout",
                sourceType: "course",
                content: "Handout content.",
                parentGroup: "   ",
                author: nil
            )
        }
        #expect(!(try store.listSources()).contains("Handout"))
    }

    @Test("addSource without content sets state to queued")
    func addSourceWithoutContent() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        _ = try store.addSource(
            url: "https://example.com/article",
            title: "Queued Article",
            sourceType: "article",
            content: nil,
            parentGroup: nil,
            author: nil
        )

        // Just verify it was added
        let list = try store.listSources()
        #expect(list.contains("Queued Article"))
    }

    @Test("listSources groups book chapters under book headings")
    func listSourcesGroupsBookChapters() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "chapter-2",
            title: "2) Entropy and Time",
            content: "Chapter two content",
            sourceType: "book"
        )
        try insertSource(
            dbPath: dbPath,
            id: "chapter-1",
            title: "1) Energy Flow",
            content: "Chapter one content",
            sourceType: "book"
        )
        try insertSource(
            dbPath: dbPath,
            id: "paper-1",
            title: "Related Paper",
            content: "Paper content",
            sourceType: "paper"
        )
        try execSQL(dbPath: dbPath, """
            INSERT INTO books (id, title) VALUES ('book-power', 'Power, Sex, Suicide');
            INSERT INTO group_members (source_id, group_id, sort_index)
            VALUES ('chapter-2', 'book-power', 2), ('chapter-1', 'book-power', 1);
        """)

        let list = try store.listSources()

        #expect(list.contains("Books (1):"))
        #expect(list.contains("- [book] Power, Sex, Suicide (book_id: book-power, chapters: 2"))
        #expect(list.contains("  - [chapter] 1) Energy Flow (id: chapter-1"))
        #expect(list.contains("  - [chapter] 2) Entropy and Time (id: chapter-2"))
        #expect(list.contains("Other sources (1):"))
        #expect(list.contains("- [paper] Related Paper"))

        let firstChapterIndex = list.range(of: "1) Energy Flow")?.lowerBound
        let secondChapterIndex = list.range(of: "2) Entropy and Time")?.lowerBound
        #expect(firstChapterIndex != nil)
        #expect(secondChapterIndex != nil)
        #expect(firstChapterIndex! < secondChapterIndex!)
    }

    // MARK: - delete_source

    @Test("deleteSource removes source and content")
    func deleteSource() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let result = try store.addSource(
            url: "https://example.com/to-delete",
            title: "Delete Me",
            sourceType: "article",
            content: "Some content",
            parentGroup: nil,
            author: nil
        )
        // Extract ID from result
        let id = result.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        #expect(!id.isEmpty)

        let deleteResult = try store.deleteSource(id)
        #expect(deleteResult.contains("Deleted source 'Delete Me'"))

        let list = try store.listSources()
        #expect(!list.contains("Delete Me"))
    }

    @Test("deleteSource returns message for unknown ID")
    func deleteSourceNotFound() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let result = try store.deleteSource("nonexistent-id")
        #expect(result.contains("Source not found"))
    }

    // MARK: - update_source

    @Test("updateSource changes title and author")
    func updateSourceMetadata() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let paper = StudioArticle(
            url: "https://example.com/update-me",
            title: "Old Title",
            sourceType: .paper,
            author: "Old Author"
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id

        let result = try store.updateSource(
            sourceID: id,
            title: "New Title",
            author: "New Author",
            parentGroup: nil,
            content: nil
        )
        #expect(result.contains("Updated source"))

        let list = try store.listSources()
        #expect(list.contains("New Title"))
        #expect(list.contains("New Author"))
    }

    @Test("updateSource with content sets state to ready")
    func updateSourceWithContent() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/needs-content",
            title: "Needs Content",
            sourceType: "manual",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        _ = try store.updateSource(
            sourceID: id,
            title: nil,
            author: nil,
            parentGroup: nil,
            content: "Now has content with several words in it."
        )

        let detail = try store.getSourceContent(id)
        #expect(detail.contains("Now has content"))
    }

    @Test("getSourceContent resolves the unique source prefixes returned in citations")
    func getSourceContentResolvesUniquePrefix() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/prefix-readable",
            title: "Readable by title",
            sourceType: "manual",
            content: "Canonical paper content.",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        #expect(id.count >= 8)

        let detail = try store.getSourceContent(String(id.prefix(8)))

        #expect(detail.contains("Readable by title"))
        #expect(detail.contains("Canonical paper content"))
    }

    @Test("MCP saves a pre-generated review guide against an exact source revision")
    func savesPreGeneratedSourceReviewGuide() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Canonical source text about a causal mechanism and its main limitation."
        try insertSource(
            dbPath: dbPath,
            id: "review-guide-source",
            title: "Review Guide Source",
            content: content
        )

        let expectedSHA256 = PaperContentPreparationService.sha256(content)
        let detail = try store.getSourceContent("review-guide-source")
        #expect(detail.contains("content_sha256: \(expectedSHA256)"))

        let result = try store.saveSourceReviewGuide(
            sourceID: "review-guide-source",
            expectedContentSHA256: expectedSHA256,
            guide: """
            KEY IDEAS
            1. The causal mechanism.

            REVIEW QUESTIONS AND ANSWER GUIDES
            - Question: How does the mechanism work?
            - Strong answer: The source links the cause to the effect.
            - Probe: What limitation constrains that claim?

            CONNECTION QUESTION
            How does the limitation change the causal interpretation?
            """
        )

        #expect(result.contains("Saved Source Review Guide"))
        let saved = try #require(try store.knowledgeStore().loadSourceReviewGuide("review-guide-source"))
        #expect(saved.sourceSHA256 == expectedSHA256)
        #expect(saved.generatorVersion == SourceReviewGuide.currentVersion)
        #expect(saved.guide.contains("Strong answer"))
        #expect(try store.knowledgeStore().hasPendingSyncChange(entity: .source, logicalKey: "review-guide-source"))
    }

    @Test("MCP rejects a pre-generated review guide after source content changes")
    func rejectsStalePreGeneratedSourceReviewGuide() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "stale-review-guide-source",
            title: "Changing Source",
            content: "Original canonical text."
        )

        let staleSHA256 = PaperContentPreparationService.sha256("Original canonical text.")
        try execSQL(
            dbPath: dbPath,
            "UPDATE source_content SET content = 'Updated canonical text.' WHERE source_id = 'stale-review-guide-source'"
        )

        #expect(throws: MCPError.self) {
            _ = try store.saveSourceReviewGuide(
                sourceID: "stale-review-guide-source",
                expectedContentSHA256: staleSHA256,
                guide: "KEY IDEAS\n1. Stale guide"
            )
        }
        #expect(try store.knowledgeStore().loadSourceReviewGuide("stale-review-guide-source") == nil)
    }

    @Test("updateSource returns message for unknown ID")
    func updateSourceNotFound() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let result = try store.updateSource(
            sourceID: "nonexistent",
            title: "X",
            author: nil,
            parentGroup: nil,
            content: nil
        )
        #expect(result.contains("Source not found"))
    }

    @Test("updateSource with no fields returns no-op message")
    func updateSourceNoFields() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let addResult = try store.addSource(
            url: "https://example.com/no-change",
            title: "No Change",
            sourceType: "article",
            content: nil,
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        let result = try store.updateSource(
            sourceID: id,
            title: nil,
            author: nil,
            parentGroup: nil,
            content: nil
        )
        #expect(result.contains("No fields to update"))
    }

    @Test("source action tools update paywall, hidden, and context state")
    func sourceActionToolsUpdateSourceState() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let paper = StudioArticle(
            url: "https://example.com/action-paper",
            title: "Action Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id

        let actions = try store.listSourceActions(id)
        #expect(actions.contains("set_source_paywall_status"))
        #expect(!actions.contains("set_source_context_membership"))

        _ = try store.setSourcePaywallStatus(sourceID: id, isPaywalled: true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT is_paywalled FROM papers WHERE source_id = '\(id)'") == 1)
        let paywallActions = try store.listSourceActions(id)
        #expect(paywallActions.contains("recheck_paywalled_papers"))
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "recheck_paywalled_papers" })
        #expect(MCPToolRegistry.annotations(for: "recheck_paywalled_papers")["openWorldHint"] as? Bool == true)

        _ = try store.setSourceHidden(sourceID: id, hidden: true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = '\(id)'") == 1)

        #expect(!MCPToolRegistry.shared.tools.contains { $0.name == "set_source_context_membership" })
    }

    @Test("paywall recheck is a no-op when the catalog has no eligible papers")
    func paywallRecheckNoEligiblePapers() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let ordinaryPaper = StudioArticle(
            url: "https://example.com/ordinary-paper",
            title: "Ordinary Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(ordinaryPaper)

        let result = try await store.recheckPaywalledPapers(sourceIDs: nil, limit: nil)

        #expect(result == "No paywalled papers need rechecking.")
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(ordinaryPaper.id))
        #expect(!saved.hasPaywallMarker)
    }

    @Test("paper download failures are classified as paywall evidence or transient")
    func paperPaywallEvidenceClassification() {
        // Paywall-shaped failures: the bulk download pass auto-marks these paywalled.
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.accessDenied) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(401)) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(402)) != nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.fetchFailed) != nil)
        let unavailable = PaperPDFUnavailableError(sourceURL: "https://doi.org/10.1000/xyz")
        #expect(MCPDataStore.paperPaywallEvidence(for: unavailable)?.contains("10.1000/xyz") == true)

        // Transient or unrelated failures: left in the needs-attention pool.
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(404)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.httpError(500)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: SourceError.pdfReadFailed) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: URLError(.timedOut)) == nil)
        #expect(MCPDataStore.paperPaywallEvidence(for: MCPError.invalidInput("Downloaded file is not a readable PDF")) == nil)
    }

    @Test("A paywalled URL import keeps the paper as a paywalled row with its bibliography")
    func paywalledURLImportSavesPaywalledPaper() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1126/science.1077780"
        let page = PaperService.PaperPageMetadata(
            title: "Rates of behavior and aging specified by mitochondrial function during development",
            authorsDisplay: "Andrew Dillin et al.",
            journal: "Science",
            year: "2002",
            doi: "10.1126/science.1077780",
            pdfURL: nil
        )
        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: page,
            scholarlyMetadata: nil,
            doi: "10.1126/science.1077780",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(result.hasPrefix("Added paper 'Rates of behavior and aging"))
        #expect(result.contains("marked it paywalled: publisher denied access (HTTP 403)"))
        #expect(result.contains("attach_pdf_to_paper"))
        #expect(result.contains("recheck_paywalled_papers"))

        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.sourceType == .paper)
        #expect(saved.hasPaywallMarker)
        #expect(saved.isPaywalled)
        #expect(saved.statusFlag == .paywall)
        #expect(saved.state == .error)
        #expect(saved.resolvedPDFPath == nil)
        #expect(saved.author == "Andrew Dillin et al.")
        #expect(saved.journal == "Science")
        #expect(saved.publishedYear == "2002")
        #expect(saved.doi == "10.1126/science.1077780")
        #expect(saved.discoveryOrigin == .manual)

        // The saved row is the one every recovery path works from.
        #expect(try store.listSourceActions(id).contains("recheck_paywalled_papers"))
        #expect(try store.existingPaperByDOI("10.1126/science.1077780")?.id == id)
    }

    /// https://doi.org/10.1016/j.cmet.2022.02.001 on 2026-09-18: the DOI resolves
    /// to linkinghub.elsevier.com, whose interstitial is titled "Redirecting" and
    /// carries no citation meta, the PDF is behind the paywall, and Crossref has
    /// the whole record. The paper was saved as "Redirecting" — author, journal,
    /// year and DOI all right, title the interstitial's. The Crossref title is
    /// the paper's whenever there is one; the page's stands in only without it,
    /// and an interstitial's never does.
    @Test("A paywalled Elsevier DOI import takes the Crossref title, not the interstitial's")
    func paywalledElsevierImportPrefersCrossrefTitleOverRedirecting() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1016/j.cmet.2022.02.001"
        let doi = "10.1016/j.cmet.2022.02.001"
        let crossrefTitle = "The NADPARK study: A randomized phase I trial of nicotinamide riboside supplementation in Parkinson's disease"
        // What the page-metadata fetch used to hand back for the interstitial:
        // a title and nothing else.
        let interstitial = PaperService.PaperPageMetadata(
            title: "Redirecting", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
        )
        let crossref = PaperService.CrossrefMetadata(
            authorsDisplay: "Brage Brakedal et al.",
            journal: "Cell Metabolism",
            year: "2022",
            title: crossrefTitle,
            doi: doi
        )

        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: interstitial,
            scholarlyMetadata: crossref,
            doi: doi,
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        ))
        #expect(result.hasPrefix("Added paper '\(crossrefTitle)'"))

        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.title == crossrefTitle)
        #expect(saved.isPaywalled)
        #expect(saved.author == "Brage Brakedal et al.")
        #expect(saved.journal == "Cell Metabolism")
        #expect(saved.publishedYear == "2022")
        #expect(saved.doi == doi)
    }

    @Test("A paywalled import with a Crossref record takes its title over the page's")
    func paywalledImportPrefersCrossrefTitleWheneverPresent() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // The page-metadata fetch now yields nothing for a redirect page, so
        // the DOI record is the only title there is.
        let redirectOnly = "https://doi.org/10.1016/j.neuron.2026.04.048"
        let neuronTitle = "A neuron paper the interstitial never named"
        let neuron = try #require(try store.savePaywalledPaperImport(
            sourceURL: redirectOnly,
            normalizedURL: URLNormalizer.normalize(redirectOnly),
            titleOverride: nil,
            pageMetadata: nil,
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: "A. Author et al.", journal: "Neuron", year: "2026",
                title: neuronTitle, doi: "10.1016/j.neuron.2026.04.048"
            ),
            doi: "10.1016/j.neuron.2026.04.048",
            evidence: "no open-access PDF found for \(redirectOnly) (direct link, PMC, and Unpaywall all came up empty)",
            connectorLabel: nil
        ))
        #expect(neuron.hasPrefix("Added paper '\(neuronTitle)'"))

        // A landing page that does name the paper still yields to the DOI
        // record's title when there is one…
        let both = "https://doi.org/10.1016/j.bbabio.2024.149193"
        let page = PaperService.PaperPageMetadata(
            title: "BBA Bioenergetics article page title", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
        )
        let bothSaved = try #require(try store.savePaywalledPaperImport(
            sourceURL: both,
            normalizedURL: URLNormalizer.normalize(both),
            titleOverride: nil,
            pageMetadata: page,
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: nil, journal: nil, year: nil,
                title: "Mitochondrial supercomplexes in bioenergetics", doi: "10.1016/j.bbabio.2024.149193"
            ),
            doi: "10.1016/j.bbabio.2024.149193",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(bothSaved.hasPrefix("Added paper 'Mitochondrial supercomplexes in bioenergetics'"))

        // …and stands in when the record has no title of its own.
        let pageOnly = "https://doi.org/10.1016/j.neubiorev.2024.105971"
        let pageOnlySaved = try #require(try store.savePaywalledPaperImport(
            sourceURL: pageOnly,
            normalizedURL: URLNormalizer.normalize(pageOnly),
            titleOverride: nil,
            pageMetadata: PaperService.PaperPageMetadata(
                title: "A review the landing page named", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
            ),
            scholarlyMetadata: PaperService.CrossrefMetadata(
                authorsDisplay: "B. Author", journal: "Neuroscience & Biobehavioral Reviews", year: "2024",
                title: nil, doi: "10.1016/j.neubiorev.2024.105971"
            ),
            doi: "10.1016/j.neubiorev.2024.105971",
            evidence: "publisher denied access (HTTP 403)",
            connectorLabel: nil
        ))
        #expect(pageOnlySaved.hasPrefix("Added paper 'A review the landing page named'"))
    }

    @Test("An interstitial title with no Crossref record falls back to the URL, not 'Redirecting'")
    func paywalledImportNeverKeepsInterstitialTitle() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://doi.org/10.1016/j.cmet.2022.02.001"
        let result = try #require(try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: PaperService.PaperPageMetadata(
                title: "Redirecting", authorsDisplay: nil, journal: nil, year: nil, doi: nil, pdfURL: nil
            ),
            scholarlyMetadata: nil,
            doi: "10.1016/j.cmet.2022.02.001",
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        ))
        #expect(!result.contains("'Redirecting'"))
        let id = try sourceID(in: store, url: sourceURL)
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(id))
        #expect(saved.title != "Redirecting")
        #expect(!saved.title.isEmpty)

        #expect(store.titleNeedsReplacement("Redirecting", sourceURL: sourceURL))
        #expect(store.titleNeedsReplacement("linkinghub.elsevier.com", sourceURL: "https://linkinghub.elsevier.com/retrieve/pii/S1550413122000456"))
        #expect(!store.titleNeedsReplacement("Redirecting T cells against cancer", sourceURL: sourceURL))
        #expect(store.usablePageTitle("Redirecting", sourceURL: sourceURL) == nil)
        #expect(store.usablePageTitle("  A real title ", sourceURL: sourceURL) == "A real title")
    }

    @Test("A paywall-shaped failure with no paper identity adds nothing")
    func paywalledURLImportWithoutIdentitySavesNothing() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let sourceURL = "https://example.com/some/page"
        let result = try store.savePaywalledPaperImport(
            sourceURL: sourceURL,
            normalizedURL: URLNormalizer.normalize(sourceURL),
            titleOverride: nil,
            pageMetadata: nil,
            scholarlyMetadata: nil,
            doi: nil,
            evidence: "publisher served a web page instead of the PDF",
            connectorLabel: nil
        )
        #expect(result == nil)
        let kstore = try store.knowledgeStore()
        #expect(kstore.sourceExistsByURL(sourceURL) == nil)
    }

    @Test("attachPDFToPaper fails closed when the PDF has no readable paper text")
    func attachPDFToPaperRequiresReadablePaperText() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let paperURL = "https://example.com/attach-paper"

        let paper = StudioArticle(
            url: paperURL,
            title: "Attach Paper",
            sourceType: .paper
        )
        try store.knowledgeStore().saveSource(paper)
        let id = paper.id
        let sourcePDF = URL(fileURLWithPath: tmpPath).appendingPathComponent("source.pdf")
        try makeTestPDF(at: sourcePDF, text: "")

        do {
            _ = try await store.attachPDFToPaper(
                sourceID: id,
                filePath: sourcePDF.path,
                pdfURL: nil
            )
            Issue.record("Attaching a paper without readable text should fail")
        } catch {
            #expect(error is MCPError)
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT url FROM papers WHERE source_id = '\(id)'") == paperURL)
        let localPath = try scalarString(dbPath: dbPath, "SELECT local_file_path FROM papers WHERE source_id = '\(id)'")
        #expect(localPath?.hasPrefix("Papers/") == true)
        #expect(localPath?.hasSuffix(".pdf") == true)
        #expect(try scalarString(dbPath: dbPath, "SELECT state FROM sources WHERE id = '\(id)'") == "error")
        #expect(try scalarString(dbPath: dbPath, "SELECT paper_ingestion_method FROM papers WHERE source_id = '\(id)'") == nil)
    }

    @Test("removeSource dismisses and archives a normal source")
    func removeSourceArchivesAndDismisses() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let addResult = try store.addSource(
            url: "https://example.com/remove-me",
            title: "Remove Me",
            sourceType: "article",
            content: "Cached source text",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""

        let result = try store.removeSource(id)

        #expect(result.contains("archived"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM dismissed_sources WHERE url = 'https://example.com/remove-me'") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id = '\(id)' AND status = 'archived'") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_content WHERE source_id = '\(id)'") == 0)
    }

    @Test("unarchiveSource reverses removal without leaving a dismissal tombstone")
    func unarchiveSourceClearsRemovalDismissal() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let url = "https://example.com/restore-me"

        let addResult = try store.addSource(
            url: url,
            title: "Restore Me",
            sourceType: "article",
            content: "Cached source text",
            parentGroup: nil,
            author: nil
        )
        let id = addResult.components(separatedBy: "id: ").last?.components(separatedBy: ",").first ?? ""
        _ = try store.removeSource(id)

        let result = try store.unarchiveSourceRestoringContent(id)

        #expect(result.contains("Unarchived source"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM dismissed_sources WHERE url = '\(url)'") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id = '\(id)' AND status = 'active'") == 1)
    }

    @Test("searchSourcesSemantic returns nearest embedded sources first")
    func searchSourcesSemanticRanksResults() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Partial Reprogramming Overview",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Epigenetic Clocks in Aging",
            content: "Age reversal biomarkers and methylation clocks."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-c",
            title: "Completely Different Topic",
            content: "Compiler optimization and static analysis."
        )

        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.8, 0.2, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-c", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "partial reprogramming", limit: 2, threshold: 0.1)

        #expect(result.contains("Partial Reprogramming Overview"))
        #expect(result.contains("Epigenetic Clocks in Aging"))
        #expect(!result.contains("Completely Different Topic"))

        let firstIndex = result.range(of: "Partial Reprogramming Overview")?.lowerBound
        let secondIndex = result.range(of: "Epigenetic Clocks in Aging")?.lowerBound
        #expect(firstIndex != nil)
        #expect(secondIndex != nil)
        if let firstIndex, let secondIndex {
            #expect(firstIndex < secondIndex)
        }
    }

    @Test("Discovery suggests only what the model judges to fit, and a Notebook made from a chat takes the chat in")
    func discoveryKeepsJudgedFitAndFilesTheCallingChat() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(dbPath: dbPath, id: "source-a", title: "Partial Reprogramming Overview",
                         content: "Yamanaka factors and cellular rejuvenation.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Epigenetic Clocks in Aging",
                         content: "Age reversal biomarkers and methylation clocks.")
        try insertSource(dbPath: dbPath, id: "source-c", title: "Completely Different Topic",
                         content: "Compiler optimization and static analysis.")
        // Every source sits near the topic, as the anisotropic embedding has
        // it, so similarity alone would suggest all three.
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.95, 0.05, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-c", vector: [0.93, 0.07, 0])

        let judged = JudgedCandidates()
        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] },
            libraryFitJudge: { notebook, candidates in
                await judged.record(notebook: notebook.title, candidates: candidates.map(\.title))
                return Set(candidates.map(\.id).filter { $0 != "source-c" })
            }
        )
        let ks = try store.knowledgeStore()
        try ks.createReviewSession(id: "chat-host", topic: "Make me a notebook on reprogramming", sourceIDs: [])

        let result = try await store.createNotebook(
            title: "Partial reprogramming", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: true, hostSessionID: "chat-host"
        )

        let notebookID = try #require(createdNotebookID(in: result))
        let notebook = try #require(try ks.loadLearningGoal(notebookID))
        #expect(Set(notebook.items.filter(\.isPendingApproval).map(\.sourceID)) == ["source-a", "source-b"])
        #expect(await judged.notebook == "Partial reprogramming")
        #expect(await judged.candidates.contains("Completely Different Topic"))

        // The chat that asked is filed in the Notebook, and its reply is told
        // not to list or show what it made.
        #expect(try ks.loadReviewSessionGoalID(sessionID: "chat-host") == notebookID)
        #expect(result.contains("filed this chat in it"))
        #expect(result.hasPrefix("Created Notebook ‘Partial reprogramming’, filed this chat in it"))
        #expect(result.contains("Do not list its sources or the suggestions"))
        #expect(!result.contains("Pass notebook_id"))
    }

    private actor JudgedCandidates {
        var notebook: String?
        var candidates: [String] = []
        func record(notebook: String, candidates: [String]) {
            self.notebook = notebook
            self.candidates = candidates
        }
    }

    /// A library shaped like the one the 2026-10-11 notebook was made in. Its embedding
    /// is anisotropic, so every source sits near every query, and here the three
    /// off-topic ones sit nearest the topic. The paper the chat was about (`seed-paper`)
    /// and the one on-topic source share its rare words (Polycomb, bivalent, H3K27me3,
    /// chromatin); nothing else does, and neither title says the topic's words.
    private func makeSeededDiscoveryLibrary(_ ks: KnowledgeStore, dbPath: String) throws {
        func vector(_ weights: [Int: Float]) -> [Float] {
            var values = [Float](repeating: 0, count: StorageService.sourceEmbeddingDimensions)
            for (axis, weight) in weights { values[axis] = weight }
            return values
        }
        func add(_ id: String, title: String, body: String, near weights: [Int: Float]?) throws {
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try ks.replaceSourceFTS(sourceID: id, title: title, author: "", body: body)
            if let weights {
                try ks.saveEmbedding(
                    entityType: .sourceChunk,
                    entityId: StorageService.sourceChunkEmbeddingId(sourceId: id, index: 0),
                    vector: vector(weights),
                    model: StorageService.sourceEmbeddingModel
                )
            }
        }
        try add("far-terahertz", title: "Terahertz waves and conscious experience",
                body: "Terahertz radiation, microtubules and awareness.", near: [0: 1])
        try add("far-deglycase", title: "A deglycase in early parkinsonism",
                body: "Oxidative stress, a deglycase and dopaminergic neurons.", near: [0: 0.98, 1: 0.2])
        try add("far-tunnelling", title: "Proton tunnelling in enzymes",
                body: "Quantum tunnelling of protons speeds enzyme catalysis.", near: [0: 0.95, 1: 0.31])
        try add("seed-paper", title: "Polycomb marks and bivalent chromatin in development",
                body: "Polycomb complexes keep bivalent promoters poised. H3K27me3 spreads where Polycomb silences. "
                    + "Bivalent chromatin resolves in development, and H3K27me3 returns with Polycomb.",
                near: [0: 0.8, 1: 0.6])
        try add("on-topic", title: "Silencing drift in old tissue",
                body: "Polycomb occupancy and H3K27me3 fall with age, and bivalent promoters lose their poise. "
                    + "Chromatin drifts as Polycomb is lost.",
                near: [0: 0.6, 1: 0.8])
        // Enough of a library that the shared words are rare in it.
        for index in 0..<20 {
            try add("filler-\(index)", title: "Unrelated note \(index)",
                    body: "General prose about compilers, history and exercise.", near: nil)
        }
    }

    /// The query vector the topic embeds to in `makeSeededDiscoveryLibrary`'s library.
    private static let seededDiscoveryQuery: [Float] = {
        var values = [Float](repeating: 0, count: StorageService.sourceEmbeddingDimensions)
        values[0] = 1
        return values
    }()

    @Test("Discovery seeded by a Notebook's own source ranks what shares its rare words first")
    func discoverySeededBySourceRanksSharedRareTermsFirst() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in Self.seededDiscoveryQuery })
        let ks = try store.knowledgeStore()
        try makeSeededDiscoveryLibrary(ks, dbPath: dbPath)

        // The topic alone: the embedding puts every off-topic source ahead of the one
        // that belongs, which is how twelve unrelated papers were suggested.
        let topicOnly = try await store.companionDiscover(
            topic: "Grammar of cellular identity", excluding: ["seed-paper"],
            sinceReferenceTimestamp: nil, limit: 24
        )
        // (The three off-topic sources tie closely, so their order among themselves is not the point.)
        #expect(Set(topicOnly.map(\.sourceID).dropLast()) == ["far-terahertz", "far-deglycase", "far-tunnelling"])
        #expect(topicOnly.last?.sourceID == "on-topic")

        // Seeded by the paper the Notebook was made from, the source sharing its rare
        // words leads, and the seed itself is never suggested back.
        let seeded = try await store.companionDiscover(
            topic: "Grammar of cellular identity", seedSourceIDs: ["seed-paper"], excluding: [],
            sinceReferenceTimestamp: nil, limit: 24
        )
        #expect(seeded.first?.sourceID == "on-topic")
        #expect(!seeded.map(\.sourceID).contains("seed-paper"))
        #expect(Set(seeded.map(\.sourceID)) == ["on-topic", "far-terahertz", "far-deglycase", "far-tunnelling"])

        // A seed with no full-text row yet gives up its share of the vote rather than
        // diluting the others': the ranking comes out as if it were not there.
        let withUnindexedSeed = try await store.companionDiscover(
            topic: "Grammar of cellular identity", seedSourceIDs: ["not-indexed", "seed-paper"], excluding: [],
            sinceReferenceTimestamp: nil, limit: 24
        )
        #expect(withUnindexedSeed.map(\.sourceID) == seeded.map(\.sourceID))
        #expect(withUnindexedSeed.map(\.relevance) == seeded.map(\.relevance))
    }

    @Test("A Notebook made from a chat starts with the sources the chat discussed, and they steer its suggestions")
    func notebookFromChatIsSeededByWhatTheChatDiscussed() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let judged = JudgedCandidates()
        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in Self.seededDiscoveryQuery },
            libraryFitJudge: { notebook, candidates in
                await judged.record(notebook: notebook.title, candidates: candidates.map(\.title))
                return Set(candidates.map(\.id).filter { $0 == "on-topic" })
            }
        )
        let ks = try store.knowledgeStore()
        try makeSeededDiscoveryLibrary(ks, dbPath: dbPath)

        // The chat was opened on no source; its reply cites the paper by in-app link,
        // and once a source the library does not hold.
        try ks.createReviewSession(id: "chat-host", topic: "About a paper", sourceIDs: [])
        _ = try ks.addReviewExchange(
            sessionID: "chat-host",
            question: "",
            answer: "Turn this into a notebook",
            evaluation: "As [the paper](foreverlm://source/seed-paper) argues, and [a lost one](foreverlm://source/not-in-library-0000) too.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )

        let result = try await store.createNotebook(
            title: "Grammar of cellular identity", description: nil, topic: nil, endDateString: "",
            sourceIDs: [], dailyTarget: nil, discover: true, hostSessionID: "chat-host"
        )

        let notebookID = try #require(createdNotebookID(in: result))
        let notebook = try #require(try ks.loadLearningGoal(notebookID))
        #expect(notebook.items.filter(\.isApproved).map(\.sourceID) == ["seed-paper"])
        #expect(notebook.items.filter(\.isPendingApproval).map(\.sourceID) == ["on-topic"])
        #expect(result.contains("Seeds: 1, 1 of them the sources this chat discussed."))
        // The judge read the seeded ranking: the source sharing the paper's words first.
        #expect(await judged.candidates.first == "Silencing drift in old tissue")
        #expect(try ks.loadReviewSessionGoalID(sessionID: "chat-host") == notebookID)

        // A caller's own sources come first, and the chat's are not repeated.
        let given = try await store.createNotebook(
            title: "Grammar of cellular identity, again", description: nil, topic: nil, endDateString: "",
            sourceIDs: ["far-terahertz", "seed-paper"], dailyTarget: nil, discover: false, hostSessionID: "chat-host"
        )
        let givenID = try #require(createdNotebookID(in: given))
        let givenNotebook = try #require(try ks.loadLearningGoal(givenID))
        #expect(Set(givenNotebook.items.filter(\.isApproved).map(\.sourceID)) == ["far-terahertz", "seed-paper"])
        #expect(given.contains("Seeds: 2."))
    }

    @Test("searchSourcesSemantic filters a relative-date meeting lookup deterministically")
    func searchSourcesSemanticFiltersMeetingDateWithoutEmbeddingGuesswork() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let targetDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: targetDay))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let targetDate = formatter.string(from: targetDay)

        try insertSource(
            dbPath: dbPath,
            id: "meeting-yesterday",
            title: "Journal Club — Somatic Mutations in Hashimoto's Thyroiditis",
            content: "A discussion of somatic mutation burden in thyroid tissue.",
            sourceType: "meeting"
        )
        try insertSource(
            dbPath: dbPath,
            id: "meeting-older",
            title: "Partial Reprogramming Case Study",
            content: "A commercially focused partial reprogramming discussion.",
            sourceType: "meeting"
        )
        try insertSource(
            dbPath: dbPath,
            id: "article-yesterday",
            title: "Thyroid News",
            content: "An article imported on the same day.",
            sourceType: "article"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE sources SET date_added = \(targetDay.timeIntervalSinceReferenceDate) WHERE id IN ('meeting-yesterday', 'article-yesterday'); "
                + "UPDATE sources SET date_added = \(previousDay.timeIntervalSinceReferenceDate) WHERE id = 'meeting-older';"
        )

        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in
                Issue.record("A date-and-type-only lookup must not invoke semantic embedding")
                return [1, 0, 0]
            }
        )
        let result = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: targetDate,
            addedTo: targetDate
        )

        #expect(result.contains("Journal Club — Somatic Mutations in Hashimoto's Thyroiditis"))
        #expect(result.contains("occurred: \(targetDate)"))
        #expect(!result.contains("Partial Reprogramming Case Study"))
        #expect(!result.contains("Thyroid News"))
    }

    @Test("A source search takes back the timestamp it printed, and says which axis found nothing")
    func searchSourcesSemanticRoundTripsItsOwnPrintedDate() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 16, minute: 53)))

        try insertSource(
            dbPath: dbPath,
            id: "meeting-printed",
            title: "Journal Club — Elamipretide",
            content: "A discussion of the SS-31 trial results.",
            sourceType: "meeting"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE sources SET date_added = \(day.timeIntervalSinceReferenceDate) WHERE id = 'meeting-printed';"
        )

        let searchStore = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })

        // The exact string the search prints for a meeting — "occurred:
        // 2026-08-30 16:53 PDT". A model narrowing its next call hands that
        // back, and the tool used to refuse the timestamp it had just written.
        let printed = DateFormatter()
        printed.locale = Locale(identifier: "en_US_POSIX")
        printed.timeZone = .current
        printed.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let stamp = printed.string(from: day)

        let narrowed = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: stamp,
            addedTo: stamp
        )
        #expect(narrowed.contains("Journal Club — Elamipretide"))

        // A publication year spelled as a real day is well-formed and matches
        // nothing. The empty result has to name the axis it filtered on, or it
        // reads as "your library has no such source".
        let empty = try await searchStore.searchSourcesSemantic(
            queryText: "",
            sourceType: "meeting",
            addedFrom: "2019-01-01",
            addedTo: "2019-12-31"
        )
        #expect(empty.contains("2019-01-01"))
        #expect(empty.contains("added to the library"))
        #expect(empty.contains("never on when it was published"))
    }

    @Test("searchSourcesSemantic omits sources already in the excluded Notebook")
    func searchSourcesSemanticExcludesNotebookSources() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Partial Reprogramming Overview",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Epigenetic Clocks in Aging",
            content: "Age reversal biomarkers and methylation clocks."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [0.8, 0.2, 0])

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Rejuvenation",
            topic: "partial reprogramming",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )

        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        // Without the exclusion, the source already in the Notebook ranks first.
        let unfiltered = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1
        )
        #expect(unfiltered.contains("Partial Reprogramming Overview"))

        // With it, the top hit drops out and the limit is filled from what remains.
        let filtered = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1,
            excludeNotebookID: goal.id
        )
        #expect(!filtered.contains("Partial Reprogramming Overview"))
        #expect(filtered.contains("Epigenetic Clocks in Aging"))
        #expect(filtered.contains("excluding 1 already in Notebook 'Rejuvenation'"))
    }

    @Test("searchSourcesSemantic can restrict results to a Notebook's approved pool")
    func searchSourcesSemanticRestrictsToNotebookSources() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Notebook Reprogramming Notes",
            content: "Yamanaka factors and partial reprogramming."
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-b",
            title: "Outside Reprogramming Survey",
            content: "A broader survey of partial reprogramming."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [0.8, 0.2, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-b", vector: [1, 0, 0])

        let notebook = try store.knowledgeStore().createCompanionGoal(
            title: "Scoped Rejuvenation",
            topic: "partial reprogramming",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )
        let searchStore = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let scoped = try await searchStore.searchSourcesSemantic(
            queryText: "partial reprogramming",
            limit: 5,
            threshold: 0.1,
            notebookID: notebook.id
        )

        #expect(scoped.contains("Notebook Reprogramming Notes"))
        #expect(!scoped.contains("Outside Reprogramming Survey"))
        #expect(scoped.contains("in Notebook 'Scoped Rejuvenation'"))

        await #expect(throws: MCPError.self) {
            _ = try await searchStore.searchSourcesSemantic(
                queryText: "partial reprogramming",
                notebookID: notebook.id,
                excludeNotebookID: notebook.id
            )
        }
    }

    @Test("searchSourcesSemantic reports when no embeddings pass threshold")
    func searchSourcesSemanticNoResults() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Epigenetic Clocks in Aging",
            content: "Yamanaka factors and cellular rejuvenation."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-a", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "partial reprogramming", limit: 5, threshold: 0.95)
        #expect(result.contains("No semantically or text-matched sources found"))
    }

    @Test("searchSourcesSemantic includes exact acronym text matches")
    func searchSourcesSemanticIncludesAcronymTextMatches() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-gwas",
            title: "Book Chapter on Genetics",
            content: "The author criticizes GWAS repeatedly as part of a broader attack on gene-centric explanations."
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-gwas", vector: [0, 1, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GWAS", limit: 5, threshold: 0.95)

        #expect(result.contains("Book Chapter on Genetics"))
        #expect(result.contains("GWAS"))
        #expect(result.contains("text:"))
    }

    @Test("source search bounds term-statistics work while preserving a trailing anchor")
    func sourceSearchTermsAreBounded() {
        let terms = (0..<40).map { "term\($0)" }.joined(separator: " ") + " GDF15"
        let parsed = SourceSearchEngine.searchTerms(for: terms)

        #expect(parsed.count == SourceSearchEngine.maximumStatisticalTerms)
        #expect(parsed.first == "term0")
        #expect(parsed.last == "gdf15")
    }

    @Test("word-delimiter analysis reduces both spellings of a term to the same parts")
    func sourceSearchAnalyzesHyphenationAway() {
        // The point of the analysis: whichever way the learner writes it, the word
        // arrives as the same parts, so the alternatives offered to FTS are identical.
        let bare = SourceSearchEngine.analyzedWords(for: "GDF15")
        let hyphenated = SourceSearchEngine.analyzedWords(for: "gdf-15")
        #expect(bare.map(\.parts) == [["gdf", "15"]])
        #expect(hyphenated.map(\.parts) == [["gdf", "15"]])
        #expect(bare.first?.variants == ["gdf15", "gdf 15"])
        #expect(bare.first?.variants == hyphenated.first?.variants)

        // Typed tokens stay as typed — those are the keys corpus statistics use.
        #expect(bare.first?.typedTokens == ["gdf15"])
        #expect(hyphenated.first?.typedTokens == ["gdf", "15"])

        // A run of letters carries no boundary to split on, so it is left alone
        // rather than guessed at.
        #expect(SourceSearchEngine.analyzedWords(for: "cfmtDNA").map(\.parts) == [["cfmtdna"]])
        #expect(SourceSearchEngine.analyzedWords(for: "cf-mtDNA").map(\.parts) == [["cf", "mtdna"]])

        // The text-side fold closes up punctuation within a word but keeps the spaces
        // between words: a boundary the writer put there is not one to match across.
        #expect(SourceSearchEngine.catenatedFold("GDF-15 as a Biomarker") == "gdf15 as a biomarker")
        #expect(SourceSearchEngine.catenatedFold("the rapist") == "the rapist")
    }

    @Test("index-time analysis adds the closed-up spelling and keeps the split one")
    func sourceSearchIndexAnalysisAddsSymbolTokens() {
        // Added, not substituted: the tokens `unicode61` would produce are all still
        // there, so "Windows 10" keeps working on a body that wrote "Windows-10".
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "GDF-15") == ["GDF", "15", "GDF15"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "Windows-10") == ["Windows", "10", "Windows10"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "5-HT") == ["5", "HT", "5HT"])

        // A letters/letters boundary carries no symbol to close up, and structured text
        // must not be mangled: a DOI's "1038" and "s41586" are not one word.
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "state-of-the-art")
            == ["state", "of", "the", "art"])
        #expect(SourceSearchEngine.indexAnalyzedTokens(in: "10.1038/s41586-023")
            == ["10", "1038", "s41586", "023"])

        // Ordinary prose passes through untouched; only the symbol-like word grows.
        #expect(SourceSearchEngine.indexAnalyzedText("Circulating GDF-15 rises in muscle")
            == "Circulating GDF 15 GDF15 rises in muscle")
        #expect(SourceSearchEngine.indexAnalyzedText("no punctuation here")
            == "no punctuation here")
    }

    @Test("analyzed MATCH expressions offer every spelling as an alternative")
    func sourceSearchExpressionsCoverVariants() {
        let words = SourceSearchEngine.analyzedWords(for: "GDF15 biomarker")

        // A space inside a quoted FTS5 string is a phrase — adjacent tokens — which is
        // how the index stored "GDF-15".
        #expect(SourceSearchEngine.ftsMatchExpression(for: words)
            == "(\"gdf15\" OR \"gdf 15\") OR \"biomarker\"")
        #expect(SourceSearchEngine.ftsAllTermsMatchExpression(for: words)
            == "(\"gdf15\" OR \"gdf 15\") AND \"biomarker\"")

        // The hyphenated query produces the same expression, which is the symmetry.
        let hyphenated = SourceSearchEngine.analyzedWords(for: "GDF-15 biomarker")
        #expect(SourceSearchEngine.ftsMatchExpression(for: hyphenated)
            == SourceSearchEngine.ftsMatchExpression(for: words))
    }

    @Test("more like this keeps a source's own rare words, by how often it says them and how rare they are")
    func moreLikeThisChoosesDistinctiveTerms() {
        let text = "Polycomb POLYCOMB polycomb bivalent Bivalent the the the the cells cells cells "
            + "Ezh2 EZH2 2026 2026 ab ab once café cafe"
        // Folded as the index folds; a number, a two-letter token and a word said once
        // never name a subject. Most frequent first, ties by spelling.
        let candidates = SourceSearchEngine.moreLikeThisCandidateTerms(in: text)
        #expect(candidates.map(\.term) == ["the", "cells", "polycomb", "bivalent", "cafe", "ezh2"])
        #expect(candidates.map(\.count) == [4, 3, 3, 2, 2, 2])

        // In a library of 100: "the" and "cells" are ordinary vocabulary, "ezh2" is held
        // by no other source and can retrieve nothing, and a word never measured is
        // left out. The rest by tf·idf: polycomb (3 × 3.36) before bivalent (2 × 2.91)
        // before cafe (2 × 1.60).
        let terms = SourceSearchEngine.moreLikeThisTerms(
            candidates: candidates,
            documentFrequencies: ["the": 99, "cells": 60, "polycomb": 3, "bivalent": 5, "ezh2": 1, "cafe": 20],
            corpusSize: 100
        )
        #expect(terms == ["polycomb", "bivalent", "cafe"])

        // A long source still asks with a bounded number of words.
        let many = (0..<30).map { (term: "term\(String(format: "%02d", $0))", count: 2) }
        let bounded = SourceSearchEngine.moreLikeThisTerms(
            candidates: many,
            documentFrequencies: Dictionary(uniqueKeysWithValues: many.map { ($0.term, 2) }),
            corpusSize: 100
        )
        #expect(bounded.count == SourceSearchEngine.moreLikeThisTermCount)
        #expect(bounded.first == "term00")
    }

    @Test("fused ranking adds each ranking's weighted reciprocal rank, an id once per ranking")
    func fusedRankingAddsWeightedReciprocalRanks() {
        let fused = SourceSearchEngine.fusedRanking([
            (ids: ["a", "b", "c"], weight: 1),
            (ids: ["c", "d"], weight: 0.5),
            (ids: ["c", "e", "c"], weight: 0.5),
        ])
        // c is in all three, so it leads though no ranking put it first alone; d and e
        // tie and go by id.
        #expect(fused.map(\.id) == ["c", "a", "b", "d", "e"])
        let k = SourceSearchEngine.rrfK
        let c = fused.first { $0.id == "c" }?.score ?? 0
        #expect(abs(c - (1 / (k + 3) + 0.5 / (k + 1) + 0.5 / (k + 1))) < 1e-6)
        #expect(SourceSearchEngine.fusedRanking([]).isEmpty)
    }

    @Test("body-text search finds a term written the other way round")
    func searchSourcesSemanticFindsHyphenationVariants() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // Neither title names the protein: only the bodies do, and each spells it the
        // other way. This is the case the in-app metadata filter cannot reach.
        let hyphenatedBody = "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        let bareBody = "GDF15 remains poorly understood as a signal of cellular stress."
        try insertSource(
            dbPath: dbPath,
            id: "source-hyphenated",
            title: "Mitochondrial stress markers",
            content: hyphenatedBody
        )
        try insertSource(
            dbPath: dbPath,
            id: "source-bare",
            title: "A mystery hormone",
            content: bareBody
        )
        // Indexed the way the background indexer would, so this exercises the full-text
        // branch — where `unicode61` stores the hyphenated spelling as two adjacent
        // tokens and the bare one as a single token — rather than the substring scan
        // that only stands in while the index is behind.
        try execSQL(dbPath: dbPath, """
            INSERT INTO source_fts (source_id, title, author, body) VALUES
              ('source-hyphenated', 'Mitochondrial stress markers', '', '\(hyphenatedBody)'),
              ('source-bare', 'A mystery hormone', '', '\(bareBody)');
            """)

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        // A threshold no cosine similarity can clear keeps the semantic branch out of
        // it, so the full-text branch is what answers in both directions.
        let bareQuery = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5, threshold: 1.5)
        #expect(bareQuery.contains("Mitochondrial stress markers"))
        #expect(bareQuery.contains("A mystery hormone"))

        let hyphenQuery = try await store.searchSourcesSemantic(queryText: "GDF-15", limit: 5, threshold: 1.5)
        #expect(hyphenQuery.contains("Mitochondrial stress markers"))
        #expect(hyphenQuery.contains("A mystery hormone"))

        // A different protein still matches neither.
        let unrelated = try await store.searchSourcesSemantic(queryText: "GDF16", limit: 5, threshold: 1.5)
        #expect(!unrelated.contains("Mitochondrial stress markers"))
        #expect(!unrelated.contains("A mystery hormone"))
    }

    @Test("the scan that stands in for an unbuilt index reads both spellings too")
    func searchSourcesSemanticScanFallbackFindsHyphenationVariants() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        // No `source_fts` rows: a source added moments ago, before the indexer reached
        // it. Retrieval falls back to a content scan, and that window must not change
        // which spelling works.
        try insertSource(
            dbPath: dbPath,
            id: "source-hyphenated",
            title: "Mitochondrial stress markers",
            content: "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        )

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let bareQuery = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5, threshold: 1.5)
        #expect(bareQuery.contains("Mitochondrial stress markers"))

        let unrelated = try await store.searchSourcesSemantic(queryText: "GDF16", limit: 5, threshold: 1.5)
        #expect(!unrelated.contains("Mitochondrial stress markers"))
    }

    @Test("source search recognizes only complete DOI identifiers")
    func sourceSearchDOIIdentifierParsing() {
        #expect(SourceSearchEngine.doiIdentifier(from: "10.1038/S41586-023-06004-9") == "10.1038/s41586-023-06004-9")
        #expect(SourceSearchEngine.doiIdentifier(from: "https://doi.org/10.1038/s41586-023-06004-9") == "10.1038/s41586-023-06004-9")
        #expect(SourceSearchEngine.doiIdentifier(from: "paper 10.1038/s41586-023-06004-9") == nil)
    }

    @Test("exact DOI lookup returns a paper without relying on token search")
    func searchSourcesSemanticFindsExactDOI() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "doi-paper",
            title: "A title with no identifier tokens",
            content: "Body text with no identifier tokens.",
            sourceType: "paper"
        )
        try execSQL(
            dbPath: dbPath,
            "UPDATE papers SET doi = '10.1038/s41586-023-06004-9' WHERE source_id = 'doi-paper'"
        )

        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })
        let result = try await store.searchSourcesSemantic(
            queryText: "https://doi.org/10.1038/s41586-023-06004-9",
            limit: 5
        )

        #expect(result.contains("A title with no identifier tokens"))
    }

    @Test("nearby query terms outrank the same terms scattered through a source")
    func searchSourcesSemanticUsesTermProximity() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let nearBody = "alpha beta gamma " + String(repeating: "padding ", count: 20)
        let farBody = "alpha " + String(repeating: "padding ", count: 14) + "beta gamma "

        try insertSource(dbPath: dbPath, id: "a-far", title: "Scattered evidence", content: farBody)
        try insertFTS(dbPath: dbPath, id: "a-far", title: "", body: farBody)
        try insertSource(dbPath: dbPath, id: "z-near", title: "Nearby evidence", content: nearBody)
        try insertFTS(dbPath: dbPath, id: "z-near", title: "", body: nearBody)

        let store = MCPDataStore(dbPath: dbPath, sourceEmbeddingProvider: { _ in [1, 0, 0] })
        let result = try await store.searchSourcesSemantic(queryText: "alpha beta gamma", limit: 2)
        let nearIndex = result.range(of: "Nearby evidence")?.lowerBound
        let farIndex = result.range(of: "Scattered evidence")?.lowerBound

        #expect(nearIndex != nil)
        #expect(farIndex != nil)
        if let nearIndex, let farIndex {
            #expect(nearIndex < farIndex)
        }
    }

    // MARK: - Scoped search

    /// Scoping has to happen *inside* the index, not by filtering its output.
    /// Here the attached source is the worst match in the corpus: 200 chunks
    /// score a perfect 1.0 and it scores 0. A global top-K plus a post-filter
    /// would return nothing at all, which is exactly how "which of my attached
    /// sources answers this?" silently returns an empty pool.
    @Test("scoped vector search ranks within the allowed sources only")
    func vectorIndexScopedSearchIgnoresTheRestOfTheCorpus() {
        let index = SourceVectorIndex(dimensions: 3)
        var vectors: [String: [Float]] = [:]
        for position in 0..<200 {
            vectors["loud-\(position)::chunk::0000"] = [1, 0, 0]
        }
        vectors["attached::chunk::0003"] = [0, 1, 0]
        index.load(vectors, sourceIDForChunk: Self.sourceIDForChunk)

        let scoped = index.search(
            queryVector: [1, 0, 0],
            topK: 5,
            threshold: 0,
            allowedSources: ["attached"]
        )
        #expect(scoped.count == 1)
        #expect(scoped.first?.id == "attached::chunk::0003")

        let unscoped = index.search(queryVector: [1, 0, 0], topK: 5, threshold: 0)
        #expect(unscoped.count == 5)
        #expect(unscoped.allSatisfy { $0.id.hasPrefix("loud-") })
    }

    @Test("unscoped vector search excludes opted-out source families before selection")
    func vectorIndexExcludesSourcesBeforeSelection() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "excluded::chunk::0000": [1, 0, 0],
                "included::chunk::0000": [0.8, 0.2, 0],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 1,
            threshold: 0,
            excludedSources: ["excluded"]
        )

        #expect(hits.map(\.id) == ["included::chunk::0000"])
    }

    /// A scoped search scores a gathered copy of the allowed rows, so every
    /// score has to be mapped back to the row it came from. Getting that
    /// mapping wrong returns real scores attached to the wrong chunk ids —
    /// plausible-looking results pointing at the wrong passages.
    @Test("scoped vector search maps gathered rows back to the right chunks")
    func vectorIndexScopedSearchMapsGatheredRowsBack() {
        let index = SourceVectorIndex(dimensions: 3)
        var vectors: [String: [Float]] = [:]
        for position in 0..<50 {
            vectors["other-\(position)::chunk::0000"] = [1, 0, 0]
        }
        vectors["a::chunk::0000"] = [0.9, 0.1, 0]
        vectors["a::chunk::0001"] = [0.2, 0.9, 0]
        vectors["b::chunk::0000"] = [0.5, 0.5, 0]
        index.load(vectors, sourceIDForChunk: Self.sourceIDForChunk)

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 3,
            threshold: 0,
            allowedSources: ["a", "b"]
        )

        #expect(hits.count == 3)
        #expect(hits.first?.id == "a::chunk::0000")
        #expect(Set(hits.map(\.id)) == ["a::chunk::0000", "a::chunk::0001", "b::chunk::0000"])
    }

    @Test("scoped vector search returns nothing when no allowed source is indexed")
    func vectorIndexScopedSearchWithNoMatchingSource() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(["known::chunk::0000": [1, 0, 0]], sourceIDForChunk: Self.sourceIDForChunk)

        let hits = index.search(
            queryVector: [1, 0, 0],
            topK: 5,
            threshold: 0,
            allowedSources: ["absent"]
        )
        #expect(hits.isEmpty)
    }

    @Test("a source's centroid is the unit mean of its chunk rows")
    func vectorIndexCentroidsAverageEachSourcesChunks() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "a::chunk::0000": [2, 0, 0],
                "a::chunk::0001": [0, 5, 0],
                "b::chunk::0000": [0, 0, 1],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let centroids = index.centroids(forSources: ["a", "absent"])
        #expect(Set(centroids.keys) == ["a"])
        let a = centroids["a"] ?? []
        #expect(a.count == 3)
        // Rows are normalized before averaging, so the chunk lengths 2 and 5
        // carry no weight: the mean sits on the diagonal.
        #expect(abs(a[0] - 0.7071) < 0.001)
        #expect(abs(a[1] - 0.7071) < 0.001)
        #expect(abs(a[2]) < 0.001)
    }

    @Test("best source scores take each allowed source's best chunk against any query")
    func vectorIndexBestSourceScoresAcrossQueries() {
        let index = SourceVectorIndex(dimensions: 3)
        index.load(
            [
                "a::chunk::0000": [1, 0, 0],
                "a::chunk::0001": [0, 0, 1],
                "b::chunk::0000": [0, 1, 0],
                "outside::chunk::0000": [1, 0, 0],
            ],
            sourceIDForChunk: Self.sourceIDForChunk
        )

        let best = index.bestSourceScores(
            queries: [[0, 1, 0], [0, 0, 1]],
            allowedSources: ["a", "b"]
        )
        #expect(Set(best.keys) == ["a", "b"])
        #expect(best["a"]?.query == 1)
        #expect(abs((best["a"]?.score ?? 0) - 1) < 0.001)
        #expect(best["b"]?.query == 0)
        #expect(abs((best["b"]?.score ?? 0) - 1) < 0.001)
    }

    /// Read next measures the unread library against what was actually read:
    /// a glance does not steer it, and nothing already opened, stamped read or
    /// outside the caller's pool comes back.
    @Test("read next ranks unread sources by closeness to recent reading")
    func readNextRanksUnreadSourcesByRecentReading() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let ks = try store.knowledgeStore()
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let dimensions = StorageService.sourceEmbeddingDimensions
        let model = StorageService.sourceEmbeddingModel
        func vector(_ weights: [Int: Float]) -> [Float] {
            var values = [Float](repeating: 0, count: dimensions)
            for (axis, weight) in weights { values[axis] = weight }
            return values
        }
        func embed(_ sourceID: String, _ weights: [Int: Float]) throws {
            try ks.saveEmbedding(
                entityType: .sourceChunk,
                entityId: StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: 0),
                vector: vector(weights),
                model: model
            )
        }
        let now = Date()
        func activity(_ sourceID: String, engagedSeconds: Double) throws {
            let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-86_400)).timeIntervalSinceReferenceDate
            try ks.exec("""
                INSERT INTO source_activity_days
                    (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at,
                     kinds, completed_kinds, max_fraction, engaged_seconds)
                VALUES ('day-\(sourceID)', 'placement-\(sourceID)', '\(sourceID)', \(day), \(day + 60), \(day + 90),
                        1, 0, 0.4, \(engagedSeconds))
            """)
        }

        try embed("read-mito", [0: 1])
        try activity("read-mito", engagedSeconds: 600)
        try embed("glanced-cars", [1: 1])
        try activity("glanced-cars", engagedSeconds: 30)

        try embed("unread-mito", [0: 0.9, 2: 0.1])
        try embed("unread-cars", [1: 1])
        try embed("not-in-pool", [0: 1])
        try insertSource(dbPath: dbPath, id: "stamped-read", title: "Stamped", content: "Already finished elsewhere.")
        // Generation 2 keeps the read stamp in the member's reading state, not on the source row.
        if ks.syncGeneration == .two {
            try ks.writeReadingPlace(sourceID: "stamped-read", readAt: .some(now))
        } else {
            try ks.exec("UPDATE sources SET read_at = \(now.timeIntervalSinceReferenceDate) WHERE id = 'stamped-read'")
        }
        try embed("stamped-read", [0: 1])

        let picks = try StorageService.readNextSuggestions(
            candidateIDs: ["unread-mito", "unread-cars", "stamped-read", "glanced-cars"],
            limit: 5,
            now: now,
            using: ks
        )

        #expect(picks.map(\.sourceID) == ["unread-mito", "unread-cars"])
        #expect(picks.first?.nearestReadSourceID == "read-mito")
    }

    @Test("read next offers nothing when nothing was read recently")
    func readNextIsEmptyWithoutRecentReading() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let ks = try store.knowledgeStore()
        try ks.saveEmbedding(
            entityType: .sourceChunk,
            entityId: StorageService.sourceChunkEmbeddingId(sourceId: "unread", index: 0),
            vector: [Float](repeating: 1, count: StorageService.sourceEmbeddingDimensions),
            model: StorageService.sourceEmbeddingModel
        )

        let picks = try StorageService.readNextSuggestions(candidateIDs: ["unread"], limit: 5, using: ks)
        #expect(picks.isEmpty)
    }

    private static func sourceIDForChunk(_ chunkID: String) -> String? {
        chunkID.range(of: "::chunk::").map { String(chunkID[chunkID.startIndex..<$0.lowerBound]) }
    }

    /// The GDF15 regression: the embedding model cannot represent a rare token (swapping
    /// GDF15 for GFRAL moves the sentence vector 0.6%), so on a rare-term query the
    /// semantic ranking is noise. An exact full-text match must still win. Here the
    /// embedding ranks the *wrong* source first and the true match dead last; the
    /// rarity-weighted fusion must still put the exact match on top.
    @Test("exact rare-term match outranks a semantically-similar-but-wrong source")
    func searchSourcesSemanticRareTermBeatsSemanticNoise() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let gdf15Title = "Endothelial GDF15 deficiency enhances barrier function"
        let gdf15Body = "Endothelial cells lacking GDF15 showed improved barrier integrity."
        try insertSource(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, content: gdf15Body)
        try insertFTS(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, body: gdf15Body)

        let decoyTitle = "Partial Reprogramming with Yamanaka Factors"
        let decoyBody = "Cellular rejuvenation via OSKM induction and epigenetic clocks."
        try insertSource(dbPath: dbPath, id: "source-decoy", title: decoyTitle, content: decoyBody)
        try insertFTS(dbPath: dbPath, id: "source-decoy", title: decoyTitle, body: decoyBody)

        // A realistically sized corpus: "GDF15" must be genuinely rare for the rarity
        // weighting to engage, which is the whole point of the test.
        for index in 0..<58 {
            let id = "filler-\(index)"
            let title = "Unrelated source \(index)"
            let body = "General prose about compilers, history, and cardiovascular exercise."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }

        // The embedder is blind to "GDF15" — it ranks the decoy closest to the query and
        // the true match orthogonal to it. This is the observed real-world failure: a
        // search for "GDF15" returned "Partial Reprogramming with Yamanaka Factors".
        try insertEmbedding(dbPath: dbPath, entityId: "source-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "source-gdf15", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GDF15", limit: 5)

        let gdf15Index = result.range(of: "Endothelial GDF15 deficiency")?.lowerBound
        let decoyIndex = result.range(of: "Partial Reprogramming")?.lowerBound
        #expect(gdf15Index != nil, "the exact GDF15 match must be returned at all")
        if let gdf15Index, let decoyIndex {
            #expect(gdf15Index < decoyIndex, "the exact match must outrank the semantic decoy")
        }
    }

    /// The rare term usually arrives wrapped in ordinary words. OR-ing the whole question
    /// into the full-text index retrieves every source containing "sources" or "have" and
    /// leans on BM25 to dig the real answer back out; the informative-term filter drops
    /// those before the query runs. Here every filler source contains the noise words and
    /// only one contains GDF15 — asking conversationally must rank the same as asking for
    /// the bare term.
    @Test("a rare term still leads when wrapped in a natural-language question")
    func searchSourcesSemanticRareTermSurvivesConversationalPhrasing() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let gdf15Title = "Endothelial GDF15 deficiency enhances barrier function"
        let gdf15Body = "Endothelial cells lacking GDF15 showed improved barrier integrity."
        try insertSource(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, content: gdf15Body)
        try insertFTS(dbPath: dbPath, id: "source-gdf15", title: gdf15Title, body: gdf15Body)

        // Every filler source carries the question's ordinary words, so a naive OR-ed
        // match expression retrieves all of them alongside the one real answer. The
        // corpus is sized past the rarity cutoff on purpose: GDF15 in 1 of ~121 sources
        // gives an IDF of ~4.4, which is what makes the informative-term filter engage.
        for index in 0..<120 {
            let id = "filler-\(index)"
            let title = "What sources I have on general topics \(index)"
            let body = "I have collected sources on what these general topics do and have covered."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }

        try insertEmbedding(dbPath: dbPath, entityId: "source-gdf15", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(
            queryText: "what sources do i have on GDF15?",
            limit: 5
        )

        #expect(result.contains("Endothelial GDF15 deficiency"), "the exact GDF15 match must be returned")

        let gdf15Index = result.range(of: "Endothelial GDF15 deficiency")?.lowerBound
        let firstFillerIndex = result.range(of: "What sources I have on general topics")?.lowerBound
        if let gdf15Index, let firstFillerIndex {
            #expect(gdf15Index < firstFillerIndex, "the rare term must outrank sources matching only the question's filler words")
        }
    }

    /// A short article with the requested surname in its author field can receive a much
    /// stronger BM25 score than a long PDF matching the surname and every topic term.
    /// Targeted paper lookup must lead with constraint coverage, then use BM25 and
    /// semantic similarity only to break ties.
    @Test("a targeted paper lookup prefers author plus topic coverage over one surname hit")
    func searchSourcesSemanticPaperLookupCombinesAuthorAndTopicConstraints() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let paperTitle = "Mechanism of age-related accumulation of mtDNA mutations in human blood"
        let longPaperBody = "CHIP mitochondrial DNA "
            + String(repeating: "background evidence ", count: 5_000)
            + " mutations"
        try insertSource(
            dbPath: dbPath,
            id: "gupta-mtdna-paper",
            title: paperTitle,
            content: longPaperBody,
            sourceType: "paper"
        )
        try insertFTS(
            dbPath: dbPath,
            id: "gupta-mtdna-paper",
            title: paperTitle,
            author: "Rahul Gupta",
            body: longPaperBody
        )

        let decoyTitle = "AI for Bio has a Fuzzy API problem"
        try insertSource(
            dbPath: dbPath,
            id: "ankit-gupta-decoy",
            title: decoyTitle,
            content: "A short article about machine learning for drug discovery."
        )
        try insertFTS(
            dbPath: dbPath,
            id: "ankit-gupta-decoy",
            title: decoyTitle,
            author: "Ankit Gupta",
            body: "A short article about machine learning for drug discovery."
        )

        // Keep the exact terms genuinely rare, as they are in a production-sized
        // library, and deliberately make the semantic branch prefer the wrong Gupta.
        for index in 0..<120 {
            let id = "paper-lookup-filler-\(index)"
            let title = "Unrelated source \(index)"
            let body = "General prose about compilers, history, and exercise."
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }
        try insertEmbedding(dbPath: dbPath, entityId: "ankit-gupta-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "gupta-mtdna-paper", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let result = try await store.searchSourcesSemantic(
            queryText: "CHIP mitochondrial DNA mutations Gupta",
            limit: 8
        )

        let paperIndex = result.range(of: paperTitle)?.lowerBound
        let decoyIndex = result.range(of: decoyTitle)?.lowerBound
        #expect(paperIndex != nil, "the paper satisfying the author and topic constraints must be returned")
        if let paperIndex, let decoyIndex {
            #expect(paperIndex < decoyIndex, "the complete paper match must be the first Gupta result")
        }
    }

    /// "Chris Masterjohn statins criticism" once returned Chris Hemsworth's episode
    /// and missed a Masterjohn video: each matched two of the four terms, and the
    /// tie fell to the semantic branch. Between equal counts, the rarer terms win.
    @Test("a tie on constraint count goes to the source matching the rarer terms")
    func searchSourcesSemanticConstraintTieGoesToRarerTerms() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let videoTitle = "Rethinking Serotonin And Depression"
        let videoBody = "Chris Masterjohn "
            + String(repeating: "background evidence ", count: 5_000)
            + " serotonin"
        try insertSource(dbPath: dbPath, id: "masterjohn-video", title: videoTitle, content: videoBody, sourceType: "video")
        try insertFTS(dbPath: dbPath, id: "masterjohn-video", title: videoTitle, body: videoBody)

        let decoyTitle = "Chris Hemsworth on longevity"
        let decoyBody = "Minimal feedback, not even constructive criticism."
        try insertSource(dbPath: dbPath, id: "hemsworth-decoy", title: decoyTitle, content: decoyBody)
        try insertFTS(dbPath: dbPath, id: "hemsworth-decoy", title: decoyTitle, body: decoyBody)

        // "masterjohn" in one source, "statins" in three, "criticism" in five and
        // "chris" in eight: every term informative, only the surname rare.
        for index in 0..<120 {
            let id = "tie-filler-\(index)"
            let title = "Unrelated source \(index)"
            let extra = switch index {
            case 0..<6: " Chris wrote this."
            case 6..<9: " It covers statins."
            case 9..<13: " A criticism of it."
            default: ""
            }
            let body = "General prose about compilers, history, and exercise." + extra
            try insertSource(dbPath: dbPath, id: id, title: title, content: body)
            try insertFTS(dbPath: dbPath, id: id, title: title, body: body)
        }
        try insertEmbedding(dbPath: dbPath, entityId: "hemsworth-decoy", vector: [1, 0, 0])
        try insertEmbedding(dbPath: dbPath, entityId: "masterjohn-video", vector: [0, 0, 1])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let result = try await store.searchSourcesSemantic(
            queryText: "Chris Masterjohn statins criticism",
            limit: 8
        )

        let videoIndex = result.range(of: videoTitle)?.lowerBound
        let decoyIndex = result.range(of: decoyTitle)?.lowerBound
        #expect(videoIndex != nil, "the source naming Masterjohn must be returned")
        if let videoIndex, let decoyIndex {
            #expect(videoIndex < decoyIndex, "chris + masterjohn must outrank chris + criticism")
        }
    }

    @Test("searchSourcesSemantic centers evidence on matched text")
    func searchSourcesSemanticCentersEvidenceOnMatchedText() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let opening = (0..<120).map { "opening\($0)" }.joined(separator: " ")
        let content = "\(opening) The author names GWAS directly here and then discusses missing heritability, polygenicity, and tiny effect sizes."

        try insertSource(
            dbPath: dbPath,
            id: "source-late-gwas",
            title: "Late Match Chapter",
            content: content
        )
        try insertEmbedding(dbPath: dbPath, entityId: "source-late-gwas", vector: [1, 0, 0])

        let store = MCPDataStore(
            dbPath: dbPath,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )

        let result = try await store.searchSourcesSemantic(queryText: "GWAS", limit: 5, threshold: 0.1)

        #expect(result.contains("Evidence:"))
        #expect(result.contains("GWAS directly here"))
        #expect(!result.contains("opening0 opening1 opening2"))
    }

    @Test("startReviewSession links source when topic is a quiz prompt")
    func startReviewSessionLinksSourceFromQuizPrompt() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Please use ForeverLM to quiz me on this source: AI for Bio fuzzy API problem drug discovery")
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")

        #expect(started.contains("(foreverlm://source/source-a)"), "the related source is its link, never a bare id")
        #expect(started.contains("Review session started: AI for Bio fuzzy API problem drug discovery"))
        #expect(started.contains("Review structure:"))
        #expect(started.contains("infer 3-7 core concepts"))
        #expect(sessions.contains("AI for Bio fuzzy API problem drug discovery"))
    }

    @Test("start_review_session operation id reuses one exact session")
    func startReviewSessionIsIdempotentByOperationID() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "operation-review-source",
            title: "Operation review source",
            content: "A retry must address one review session."
        )

        let first = try await store.startReviewSession(
            topic: "Operation review",
            operationID: "start-call-7"
        )
        // The exact retry must replay the stored source set rather than rerun
        // topic discovery after sync adds another matching source.
        try insertSource(
            dbPath: dbPath,
            id: "operation-review-source-late",
            title: "Operation review late arrival",
            content: "This source arrived after the operation already chose its review."
        )
        let second = try await store.startReviewSession(
            topic: "Operation review",
            operationID: "start-call-7"
        )
        let sessionID = parsedSessionID(from: first)

        #expect(!sessionID.isEmpty)
        #expect(parsedSessionID(from: second) == sessionID)
        #expect(!second.contains("operation-review-source-late"))
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id = '\(sessionID)'"
        ) == 1)

        do {
            _ = try await store.startReviewSession(
                topic: "Changed operation review",
                operationID: "start-call-7"
            )
            Issue.record("Expected changed arguments for a reused operation_id to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("different start_review_session arguments"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'mcp-review-session-operation-%'"
        ) == 1)
    }

    @Test("The server instructions and import_review_chat tell an assistant to keep a chat about sources as it goes: a new chat on the first answer, an append with session_id on every later one")
    func chatAboutSourcesIsSavedAsItGoes() throws {
        // The product owner (2026-09-20): "whenever chatting about sources in foreverlm,
        // we have to save those chats as chats in foreverlm each time … if
        // it's the first one, make a new chat, otherwise append".
        let instructions = Prompts.mcpServerInstructions
        #expect(instructions.contains("Saving a conversation about sources:"))
        #expect(instructions.contains("call import_review_chat without session_id"))
        #expect(instructions.contains("call import_review_chat again with that session_id and only the new question and answer"))
        #expect(instructions.contains("do not wait for the conversation to end"))
        #expect(instructions.contains("never import it as well"), "a live review is recorded by end_review_session, not imported twice")
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "import_review_chat" })
        #expect(tool.description.contains("save the first question and answer without session_id"))
        #expect(tool.description.contains("append each later exchange with it as soon as you have answered"))

        // The product owner (2026-09-20), on a chat whose saved copy was a paraphrase
        // written before the answer: the stored chat is the chat on screen,
        // read from Claude Code's own session file where there is one.
        #expect(instructions.contains("pass transcript_file with the value of"))
        #expect(instructions.contains("CLAUDE_CODE_SESSION_ID"))
        #expect(instructions.contains("after your answer is written"))
        #expect(instructions.contains("never a summary or a shortened version"))
        #expect(tool.description.contains("pass transcript_file"))
        #expect(tool.description.contains("never a summary or a shortened version"))
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(properties["transcript_file"] != nil)
        #expect((tool.inputSchema["required"] as? [String]) == ["title"], "transcript is one of two ways to hand over the chat")
    }

    @Test("import_review_chat appends a later chunk to the session the first chunk made")
    func importReviewChatAppendsChunks() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "chunk-source-a", title: "Chunk source A", content: "First chunk source.")
        try insertSource(dbPath: dbPath, id: "chunk-source-b", title: "Chunk source B", content: "Second chunk source.")

        let first = try store.importReviewChat(
            title: "Bayes in chunks",
            transcript: "Assistant: What is a prior?\nYou: Belief before evidence.",
            sourceIDs: ["chunk-source-a"],
            summary: nil,
            overallScore: nil,
            modelProvider: "Claude",
            modelID: nil
        )
        let sessionID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!sessionID.isEmpty)
        #expect(first.contains("pass session_id \(sessionID)"))

        let second = try store.importReviewChat(
            title: "A different title that must not win",
            transcript: "Assistant: And a posterior?\nYou: Belief after evidence.\nAssistant: Good. Likelihood?\nYou: How well the data fit a hypothesis.",
            sourceIDs: ["chunk-source-b"],
            summary: "Covered prior, posterior and likelihood.",
            overallScore: 0.9,
            modelProvider: nil,
            modelID: "claude-opus-5",
            sessionID: "foreverlm://chat/\(sessionID)"
        )
        #expect(second.contains("Appended 2 exchanges"))
        #expect(second.contains("it now holds 3"))
        #expect(second.contains("1 more source linked"))

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT exchange_count FROM review_sessions WHERE id = '\(sessionID)'") == 3)
        #expect(try scalarString(dbPath: dbPath, "SELECT topic FROM review_sessions WHERE id = '\(sessionID)'") == "Bayes in chunks")
        #expect(try scalarString(dbPath: dbPath, "SELECT summary FROM review_sessions WHERE id = '\(sessionID)'") == "Covered prior, posterior and likelihood.")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_provider FROM review_sessions WHERE id = '\(sessionID)'") == "Claude")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_id FROM review_sessions WHERE id = '\(sessionID)'") == "claude-opus-5")
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(sessionID)'") == "completed")
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(overall_score * 100 AS INTEGER) FROM review_sessions WHERE id = '\(sessionID)'") == 90)
        #expect(try scalarString(dbPath: dbPath, "SELECT group_concat(sequence_number) FROM (SELECT sequence_number FROM review_exchanges WHERE session_id = '\(sessionID)' ORDER BY sequence_number)") == "1,2,3")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(sessionID)' AND sequence_number = 3") == "Good. Likelihood?")
        let sourceIDsJSON = try scalarString(dbPath: dbPath, "SELECT source_ids FROM review_sessions WHERE id = '\(sessionID)'") ?? ""
        #expect(sourceIDsJSON.contains("chunk-source-a") && sourceIDsJSON.contains("chunk-source-b"))

        // The same chunk sent again is a retried call: acknowledged, stored once.
        let retried = try store.importReviewChat(
            title: "",
            transcript: "Assistant: And a posterior?\nYou: Belief after evidence.\nAssistant: Good. Likelihood?\nYou: How well the data fit a hypothesis.",
            sourceIDs: nil,
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            sessionID: sessionID
        )
        #expect(retried.contains("already the end"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'") == 3)

        // A transcript search finds text that arrived only in the second chunk.
        #expect(try store.searchReviewSessions(queryText: "Likelihood", limit: 5).contains(sessionID))

        // An unknown session is refused rather than silently made.
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "", transcript: "Assistant: Hi\nYou: Hello", sourceIDs: nil, summary: nil,
                overallScore: nil, modelProvider: nil, modelID: nil, sessionID: "no-such-session"
            )
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    /// A Claude Code session file as the client writes it: the learner's
    /// prompt, a progress line and a tool call, the tool's result (a user
    /// record that is not the learner), a message the learner sent while the
    /// turn ran, a sub-agent line, harness-authored user records, and the
    /// answer with a source link, plus the title the learner gave the session.
    private static func claudeCodeSessionFixture(sessionID: String, answer: String) -> String {
        let lines: [String] = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-20T21:13:35.626Z","sessionId":"\#(sessionID)","content":"ignored"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"what does the paper predict from morphology?\n\n<system-reminder>\nContents of CLAUDE.md\n</system-reminder>"},"uuid":"u1","timestamp":"2026-09-20T21:13:35.731Z","sessionId":"\#(sessionID)"}"#,
            #"{"type":"custom-title","customTitle":"Predicting membrane potential from morphology","sessionId":"\#(sessionID)"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"I'll read the paper first."}]},"uuid":"a1","timestamp":"2026-09-20T21:13:50.000Z"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__foreverlm__get_source_content","input":{"source_id":"src_paper"}}]},"uuid":"a2","timestamp":"2026-09-20T21:13:51.000Z"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"Paper text the learner never typed"}]},"uuid":"u2","timestamp":"2026-09-20T21:13:52.000Z","toolUseResult":"x"}"#,
            #"{"parentUuid":"u2","isSidechain":false,"type":"attachment","attachment":{"type":"queued_command","prompt":"and per cell or per well?","timestamp":"2026-09-20T21:14:10.000Z"},"uuid":"q1","timestamp":"2026-09-20T21:14:10.000Z"}"#,
            #"{"parentUuid":"u2","isSidechain":true,"type":"assistant","message":{"model":"claude-fable-5-1","id":"m9","role":"assistant","content":[{"type":"text","text":"sub-agent chatter"}]},"uuid":"s1","timestamp":"2026-09-20T21:14:11.000Z"}"#,
            #"{"parentUuid":"q1","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u3","timestamp":"2026-09-20T21:14:12.000Z"}"#,
            #"{"parentUuid":"u3","isSidechain":false,"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: the messages below were generated by the user while running local commands."},"uuid":"u4","timestamp":"2026-09-20T21:14:13.000Z"}"#,
            #"{"parentUuid":"u4","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m2","role":"assistant","content":[{"type":"text","text":\#(answer)}]},"uuid":"a3","timestamp":"2026-09-20T21:18:40.000Z"}"#,
            #"{"parentUuid":"a3","isSidechain":false,"type":"system","subtype":"stop_hook_summary","uuid":"h1","timestamp":"2026-09-20T21:18:53.925Z"}"#,
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static let fixtureAnswer = #""Per cell. [MitoSpace](foreverlm://source/src_paper) predicts TMRM from MitoTracker morphology at R² 0.91.\n\n| Input | R² |\n|---|---|\n| Masks | 0.74 |""#

    @Test("A Claude Code session file is read as the chat the learner saw: their prompts, including one sent mid-turn, and every text the assistant showed, timed and titled; tool calls, results, thinking, sub-agents and harness records are not")
    func claudeCodeSessionFileReadsAsTheChat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir.path) }
        let sessionID = UUID().uuidString.lowercased()
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        try Self.claudeCodeSessionFixture(sessionID: sessionID, answer: Self.fixtureAnswer).write(to: url, atomically: true, encoding: .utf8)

        let record = try AssistantTranscriptFile.read(at: url)
        #expect(record.kind == .claudeCodeSession)
        #expect(record.title == "Predicting membrane potential from morphology")
        #expect(record.modelID == "claude-opus-5")
        #expect(record.messages.map(\.role) == [.learner, .assistant, .learner, .assistant])
        #expect(record.messages[0].text == "what does the paper predict from morphology?")
        #expect(record.messages[1].text == "I'll read the paper first.")
        #expect(record.messages[2].text == "and per cell or per well?")
        #expect(record.messages[3].text.hasPrefix("Per cell. [MitoSpace](foreverlm://source/src_paper)"))
        #expect(record.messages[3].text.contains("| Masks | 0.74 |"))
        #expect(record.startedAt == MCPDataStore.parseISODate("2026-09-20T21:13:35.731Z"))
        #expect(record.endedAt == MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z"))
        let joined = record.messages.map(\.text).joined()
        #expect(!joined.contains("Paper text the learner never typed"))
        #expect(!joined.contains("sub-agent chatter"))
        #expect(!joined.contains("private"))
        #expect(!joined.contains("system-reminder"))
        #expect(!joined.contains("/clear"))
        #expect(!joined.contains("Caveat"))

        // Folded into exchanges the way a typed transcript is, each dated by
        // its last message.
        let turns = record.turns
        #expect(turns.count == 3)
        #expect(turns[0].answer == "what does the paper predict from morphology?")
        #expect(turns[0].question == nil)
        #expect(turns[1].question == "I'll read the paper first.")
        #expect(turns[1].answer == "and per cell or per well?")
        #expect(turns[1].answeredAt == MCPDataStore.parseISODate("2026-09-20T21:14:10.000Z"))
        // The answer written after the mid-turn message is its own exchange.
        #expect(turns[2].question?.hasPrefix("Per cell. [MitoSpace]") == true)
        #expect(turns[2].answer == nil)
        #expect(turns[2].answeredAt == MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z"))

        // A file that is not a session is read as a role-labelled transcript.
        let text = dir.appendingPathComponent("export.md")
        try "**User**\nWhat is a prior?\n\n**Claude**\nBelief before evidence.\n".write(to: text, atomically: true, encoding: .utf8)
        let export = try AssistantTranscriptFile.read(at: text)
        #expect(export.kind == .roleLabelledText)
        #expect(export.messages.map(\.text) == ["What is a prior?", "Belief before evidence."])

        // A session id resolves to its file under the notebooks directory.
        #expect(AssistantTranscriptFile.claudeCodeSessionFile(id: sessionID, notebooksRoot: dir.deletingLastPathComponent())?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(AssistantTranscriptFile.claudeCodeSessionFile(id: UUID().uuidString, notebooksRoot: dir.deletingLastPathComponent()) == nil)
    }

    @Test("import_review_chat with transcript_file stores the chat from Claude Code's own record, verbatim and at its hours, and a later call with session_id brings the stored chat level with the file")
    func importReviewChatReadsTheClaudeCodeSessionFile() throws {
        // The product owner (2026-09-20), on a chat saved as a paraphrase the assistant
        // wrote before answering: "it only saved a summary to foreverlm; not
        // the whole chat. it should do the whole chat … it can probably just do
        // that based on the json file on disk right?"
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_paper", title: "MitoSpace", content: "Lattice light-sheet volumes.")

        let notebooks = URL(fileURLWithPath: tmpPath).appendingPathComponent("notebooks/-Users-me-Developer-mito", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooks, withIntermediateDirectories: true)
        store.claudeCodeProjectsRoot = notebooks.deletingLastPathComponent()
        let sessionID = UUID().uuidString.lowercased()
        let file = notebooks.appendingPathComponent("\(sessionID).jsonl")
        try Self.claudeCodeSessionFixture(sessionID: sessionID, answer: Self.fixtureAnswer).write(to: file, atomically: true, encoding: .utf8)

        // The session id alone names the file; no transcript is typed.
        let first = try store.importReviewChat(
            title: "Cross-modality prediction",
            transcript: "",
            transcriptFile: sessionID,
            sourceIDs: ["src_paper"],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil
        )
        #expect(first.contains("from its Claude Code session file"))
        #expect(first.contains("with 3 exchanges"))
        #expect(first.contains("on the day's log for 2026-09-20"))
        #expect(first.contains("the same transcript_file"))
        let reviewID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!reviewID.isEmpty)

        let storedAnswer = try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") ?? ""
        #expect(storedAnswer.hasPrefix("Per cell. [MitoSpace](foreverlm://source/src_paper)"), "the answer is stored as written, source link and table included")
        #expect(storedAnswer.contains("| Masks | 0.74 |"))
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 1") == "what does the paper predict from morphology?")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 2") == "I'll read the paper first.")
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 2") == "and per cell or per well?")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_provider FROM review_sessions WHERE id = '\(reviewID)'") == "Claude")
        #expect(try scalarString(dbPath: dbPath, "SELECT model_id FROM review_sessions WHERE id = '\(reviewID)'") == "claude-opus-5")
        let startedAt = try scalarInt(dbPath: dbPath, "SELECT CAST(started_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'")
        let endedAt = try scalarInt(dbPath: dbPath, "SELECT CAST(ended_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'")
        #expect(startedAt == Int(MCPDataStore.parseISODate("2026-09-20T21:13:35.731Z")!.timeIntervalSinceReferenceDate))
        #expect(endedAt == Int(MCPDataStore.parseISODate("2026-09-20T21:18:40.000Z")!.timeIntervalSinceReferenceDate))
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(answered_at AS INTEGER) FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") == endedAt)

        // The same file again: nothing to add.
        let again = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: file.path, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: "foreverlm://chat/\(reviewID)"
        )
        #expect(again.contains("already matches its Claude Code session file"))
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(reviewID)'") == 3)

        // The conversation goes on; the file grows; the stored chat follows.
        let more = #"{"parentUuid":"a3","isSidechain":false,"type":"user","message":{"role":"user","content":"is that per cell too?"},"uuid":"u5","timestamp":"2026-09-20T21:20:00.000Z"}"# + "\n"
            + #"{"parentUuid":"u5","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m3","role":"assistant","content":[{"type":"text","text":"Yes: TMRM is a per-cell regression target."}]},"uuid":"a4","timestamp":"2026-09-20T21:20:30.000Z"}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        let grown = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: reviewID
        )
        #expect(grown.contains("1 exchange appended"))
        #expect(grown.contains("it holds 4 exchanges"))
        // The learner's new question closes the answer's exchange; the reply opens the next.
        #expect(try scalarString(dbPath: dbPath, "SELECT user_answer FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 3") == "is that per cell too?")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(reviewID)' AND sequence_number = 4") == "Yes: TMRM is a per-cell regression target.")
        #expect(try scalarInt(dbPath: dbPath, "SELECT CAST(ended_at AS INTEGER) FROM review_sessions WHERE id = '\(reviewID)'") == Int(MCPDataStore.parseISODate("2026-09-20T21:20:30.000Z")!.timeIntervalSinceReferenceDate))

        // The reported case: a chat first saved as the assistant's retelling,
        // written before the answer. Reconciling with the file replaces the
        // retelling with the answer as it was shown.
        let retold = try store.importReviewChat(
            title: "Retold chat",
            transcript: "**User**\n\nwhat does the paper predict from morphology?\n\n**Claude**\n\nShort answer: membrane potential from morphology at R2 0.91.",
            sourceIDs: ["src_paper"], summary: nil, overallScore: nil, modelProvider: "Claude", modelID: nil
        )
        let retoldID = mcpAnswerValue("session_id", in: retold) ?? ""  // the new chat's own `session_id:` line
        let repaired = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID, sourceIDs: nil, summary: nil,
            overallScore: nil, modelProvider: nil, modelID: nil, sessionID: retoldID
        )
        // The learner's question matched the record and kept its row; the
        // retelling did not and was replaced by the record's three later turns.
        #expect(repaired.contains("1 stored exchange rewritten from the record"))
        #expect(repaired.contains("2 exchanges appended"))
        #expect(repaired.contains("it holds 4 exchanges"))
        #expect(try scalarString(dbPath: dbPath, "SELECT topic FROM review_sessions WHERE id = '\(retoldID)'") == "Retold chat")
        #expect(try scalarString(dbPath: dbPath, "SELECT question FROM review_exchanges WHERE session_id = '\(retoldID)' AND sequence_number = 3")?.contains("[MitoSpace](foreverlm://source/src_paper)") == true)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(retoldID)' AND question LIKE 'Short answer%'") == 0)
        #expect(try scalarString(dbPath: dbPath, "SELECT group_concat(sequence_number) FROM (SELECT sequence_number FROM review_exchanges WHERE session_id = '\(retoldID)' ORDER BY sequence_number)") == "1,2,3,4")

        // A session this Mac has no record of, and a file outside the roots a
        // client may read, are refused by name rather than read elsewhere.
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Missing", transcript: "", transcriptFile: UUID().uuidString, sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Hosts", transcript: "", transcriptFile: "/etc/hosts", sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Nothing", transcript: "", transcriptFile: nil, sourceIDs: nil,
                summary: nil, overallScore: nil, modelProvider: nil, modelID: nil
            )
        }
    }

    /// A Claude Code session file of plain turns, each stamped at a local
    /// moment on 2026-09-28.
    private static func claudeCodeSession(sessionID: String, turns: [(learner: Bool, text: String, hour: Int, minute: Int, second: Int)]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for (index, turn) in turns.enumerated() {
            let at = Calendar.current.date(from: DateComponents(
                year: 2026, month: 9, day: 28, hour: turn.hour, minute: turn.minute, second: turn.second
            )) ?? Date()
            let stamp = formatter.string(from: at)
            let text = String(data: (try? JSONEncoder().encode(turn.text)) ?? Data(), encoding: .utf8) ?? "\"\""
            if turn.learner {
                lines.append(#"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(text)},"uuid":"u\#(index)","timestamp":"\#(stamp)","sessionId":"\#(sessionID)"}"#)
            } else {
                lines.append(#"{"parentUuid":"u\#(index - 1)","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5","id":"m\#(index)","role":"assistant","content":[{"type":"text","text":\#(text)}]},"uuid":"a\#(index)","timestamp":"\#(stamp)"}"#)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("A chat brought level with its Claude Code session file is on the day's log in sittings, and one saved with mark_reviewed false leaves the sources a later call links unreviewed")
    func importReviewChatRecordKeepsItsSittingsAndItsChoice() throws {
        // The reported chat (2026-09-28): imported with mark_reviewed false in
        // the afternoon, then brought level with its session file at seven
        // with more source_ids. It was drawn 14:26–19:04, 278 minutes, and
        // every added source came back reviewed, done and read.
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_first", title: "First", content: "First paper.")
        try insertSource(dbPath: dbPath, id: "src_later_paper", title: "Later", content: "Later paper.")
        try insertSource(dbPath: dbPath, id: "src_later_episode", title: "Episode", content: "An episode.", sourceType: "podcast")

        let notebooks = URL(fileURLWithPath: tmpPath).appendingPathComponent("notebooks/-Users-me-Developer-mito", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooks, withIntermediateDirectories: true)
        store.claudeCodeProjectsRoot = notebooks.deletingLastPathComponent()
        let sessionID = UUID().uuidString.lowercased()
        let file = notebooks.appendingPathComponent("\(sessionID).jsonl")
        let afternoon: [(learner: Bool, text: String, hour: Int, minute: Int, second: Int)] = [
            (true, "what did these papers find?", 14, 26, 10),
            (false, "Mostly that the effect holds in vivo.", 14, 29, 40),
        ]
        try Self.claudeCodeSession(sessionID: sessionID, turns: afternoon).write(to: file, atomically: true, encoding: .utf8)

        let first = try store.importReviewChat(
            title: "What the papers found", transcript: "", transcriptFile: sessionID,
            sourceIDs: ["src_first"], summary: nil, overallScore: nil, modelProvider: nil, modelID: nil,
            marksReviewed: false
        )
        #expect(first.contains("as a saved chat"))
        #expect(first.contains("on the day's log for 2026-09-28 (14:26–14:30) at the hours it ran"))
        let reviewID = mcpAnswerValue("session_id", in: first) ?? ""  // the new chat's own `session_id:` line
        #expect(!reviewID.isEmpty)

        // The learner comes back at seven; the file grows, and the call that
        // brings the chat level links more sources without saying mark_reviewed.
        let evening = afternoon + [
            (true, "and the two newer ones?", 19, 0, 5),
            (false, "They agree, with one caveat.", 19, 4, 20),
        ]
        try Self.claudeCodeSession(sessionID: sessionID, turns: evening).write(to: file, atomically: true, encoding: .utf8)
        let later = try store.importReviewChat(
            title: "", transcript: "", transcriptFile: sessionID,
            sourceIDs: ["src_later_paper", "src_later_episode"], summary: nil, overallScore: nil,
            modelProvider: nil, modelID: nil, sessionID: reviewID
        )
        #expect(later.contains("2 more sources linked, without marking them reviewed"))
        #expect(later.contains("on the day's log for 2026-09-28 (14:26–14:30, 19:00–19:05) at the hours it ran"))

        let ids = "('src_first', 'src_later_paper', 'src_later_episode')"
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_activity_days WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 0)
        #expect(try scalarString(dbPath: dbPath, "SELECT kind FROM review_sessions WHERE id = '\(reviewID)'") == "chat")
        let sourceIDsJSON = try scalarString(dbPath: dbPath, "SELECT source_ids FROM review_sessions WHERE id = '\(reviewID)'") ?? ""
        #expect(sourceIDsJSON.contains("src_later_paper") && sourceIDsJSON.contains("src_later_episode"), "linked all the same")

        let log = try #require(try store.knowledgeStore().loadDayPlan("2026-09-28")).activities.filter { $0.targetID == reviewID }
        #expect(log.map(\.durationMinutes).sorted() == [4, 5], "two sittings, not 278 minutes")
    }

    @Test("forget_source_activity takes back a review recorded in error: the automatic entry, its activity day and the read stamp go on every device, a podcast's included")
    func forgetSourceActivityTakesBackAWrongReview() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src_paper", title: "A paper", content: "A paper.")
        try insertSource(dbPath: dbPath, id: "src_episode", title: "An episode", content: "An episode.", sourceType: "podcast")
        let knowledge = try store.knowledgeStore()

        // What the append path wrote for each of the seven sources on 2026-09-28.
        try store.markScheduledSourcesReviewed(["src_paper", "src_episode"])
        let placementID = try #require(try knowledge.scheduledSourceID(forSource: "src_paper"))
        let ids = "('src_paper', 'src_episode')"
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 2)
        // The tools that existed could not take it back.
        #expect(throws: MCPError.self) { try store.unscheduleSources(sourceIDs: ["src_paper"]) }

        try execSQL(dbPath: dbPath, "DELETE FROM sync_changes")
        let today = DayPlan.dateString(for: Date())
        let registry = MCPToolRegistry(store: store)
        let outcome = await registry.callToolDetailed(
            name: "forget_source_activity",
            arguments: ["source_ids": ["src_paper", "src_episode"], "date": today]
        )
        #expect(!outcome.isError)
        let result = try parseJSON(outcome.text)
        #expect(result["status"] as? String == "forgotten")
        #expect(result["date"] as? String == today)
        let sources = try #require(result["sources"] as? [[String: Any]])
        #expect(sources.map { $0["source_id"] as? String } == ["src_paper", "src_episode"])
        #expect(sources.allSatisfy { $0["read_at_cleared"] is String && $0["was_completed"] as? Bool == true })
        let day = try #require((sources.first?["days"] as? [[String: Any]])?.first)
        #expect(day["date"] as? String == today)
        #expect(day["completed_kinds"] as? [String] == ["review"])

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_activity_days WHERE source_id IN \(ids)") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id IN \(ids) AND read_at IS NOT NULL") == 0)
        // CloudKit carries it: the placement's deletion takes its activity
        // days off the other Macs, and the read stamp travels with the source.
        #expect(try scalarString(dbPath: dbPath, "SELECT operation FROM sync_changes WHERE entity_type = 'scheduledSource' AND logical_key = '\(placementID)'") == "delete")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'scheduledSource' AND operation = 'delete'") == 2)
        // Under generation 2 the stamp is the ReadingState's, which the outbox sends once the store
        // is activated, not a source change in this queue.
        if knowledge.syncGeneration == .one {
            #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'source' AND logical_key IN \(ids) AND operation = 'save'") == 2)
        }
        // And the sources are still in the library.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM sources WHERE id IN \(ids)") == 2)
    }

    @Test("forget_source_activity changes nothing when any source has a plan, activity on another day, or nothing recorded")
    func forgetSourceActivityRefusesWhatItWouldWronglyErase() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src_planned", "src_history", "src_wrong", "src_untouched"] {
            try insertSource(dbPath: dbPath, id: id, title: id, content: "Text of \(id).")
        }
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let today = DayPlan.dateString(for: now)
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))

        // A plan the learner made and then reviewed.
        _ = try await store.assignSourcesToDay(sourceIDs: ["src_planned"], dateString: today)
        try store.markScheduledSourcesReviewed(["src_planned"])
        // Real reading yesterday, and a wrong review today, on one automatic entry.
        try knowledge.recordScheduledSourceActivity(sourceID: "src_history", on: yesterday, kind: .reading)
        try store.markScheduledSourcesReviewed(["src_history", "src_wrong"])

        /// The refusal's text, or "" when the call went through.
        func refusal(_ ids: [String], on date: String) -> String {
            do {
                _ = try store.forgetSourceActivity(sourceIDs: ids, dateString: date)
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal(["src_wrong", "src_planned"], on: today).contains("unschedule_sources"))
        #expect(refusal(["src_wrong", "src_history"], on: today).contains("also has activity on \(DayPlan.dateString(for: yesterday))"))
        #expect(refusal(["src_wrong", "src_untouched"], on: today).contains("src_untouched has no recorded activity"))
        // All or nothing: the source that could have been forgotten was not.
        #expect(try knowledge.scheduledSourceID(forSource: "src_wrong") != nil)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM source_projection WHERE id = 'src_wrong' AND read_at IS NOT NULL") == 1)
        // The day is required, never assumed, and has to be the day it was recorded.
        #expect(throws: MCPError.self) { try store.forgetSourceActivity(sourceIDs: ["src_wrong"], dateString: nil) }
        #expect(refusal(["src_wrong"], on: DayPlan.dateString(for: yesterday)).contains("also has activity on \(today)"))
        // Alone, on its day, it goes.
        #expect(refusal(["src_wrong"], on: today).isEmpty)
        #expect(try knowledge.scheduledSourceID(forSource: "src_wrong") == nil)
        // The plan and the history are as they were.
        #expect(try knowledge.scheduledSourceID(forSource: "src_planned") != nil)
        #expect(try knowledge.loadSourceActivityDays(sourceID: "src_history").count == 2)
    }

    @Test("import_review_chat files a first import directly under an explicit Notebook")
    func importReviewChatFilesUnderNotebook() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "notebook-import-source",
            title: "Notebook import source",
            content: "A completed external chat can be filed in its Notebook at import time."
        )

        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Mito Phenotyping",
            topic: "mitochondrial phenotyping",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let imported = try store.importReviewChat(
            title: "Energy transformation assays",
            transcript: "Assistant: What did the assays show?\nYou: Energetically costly compensation.",
            sourceIDs: ["notebook-import-source"],
            summary: "Primary mitochondrial disease phenotyping.",
            overallScore: nil,
            modelProvider: "ChatGPT",
            modelID: nil,
            notebookID: notebook.id
        )
        let sessionID = mcpAnswerValue("session_id", in: imported) ?? ""  // the new chat's own `session_id:` line
        #expect(!sessionID.isEmpty)
        #expect(imported.contains("Filed under Notebook ‘Mito Phenotyping’."))
        #expect(!imported.contains("(id: "), "no id beside a name (Prompts.hiddenIDs)")
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(sessionID)'"
        ) == notebook.id)
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.goalID == notebook.id)

        // Notebook placement is independent of the Notebook's approved source
        // pool, matching Move to Notebook in the sidebar. The external chat can
        // retain exact library citations without silently adding those sources
        // to the Notebook.
        #expect(try knowledge.notebookContextSourceIDs(notebookID: notebook.id).isEmpty)
        #expect(try store.reviewSessionSourceIDs(sessionID: sessionID) == ["notebook-import-source"])

        // Later chunks keep the first import's Notebook. Repeating notebook_id is
        // harmless and is not a request to move an existing imported chat.
        _ = try store.importReviewChat(
            title: "Ignored",
            transcript: "Assistant: Which context matters?\nYou: The standardized whole-room chamber.",
            sourceIDs: nil,
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil,
            notebookID: "not-a-notebook",
            sessionID: sessionID
        )
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(sessionID)'"
        ) == notebook.id)

        #expect(throws: MCPError.self) {
            try store.importReviewChat(
                title: "Invalid Notebook",
                transcript: "Assistant: Hi\nYou: Hello",
                sourceIDs: [],
                summary: nil,
                overallScore: nil,
                modelProvider: nil,
                modelID: nil,
                notebookID: "not-a-notebook"
            )
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("Review sessions link to a Notebook only when notebook id is explicit")
    func reviewSessionsRequireExplicitNotebookAttribution() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Explicit notebook review",
            content: "Review content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Review Notebook",
            topic: "review",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-a"]
        )
        let priorSelection = ActiveNotebookPreference.notebookID
        ActiveNotebookPreference.notebookID = notebook.id
        defer { ActiveNotebookPreference.notebookID = priorSelection }

        func sessionID(from response: String) -> String {
            response
                .components(separatedBy: "\n")
                .first { $0.hasPrefix("Session ID: ") }?
                .replacingOccurrences(of: "Session ID: ", with: "") ?? ""
        }

        let unscoped = try await store.startReviewSession(
            topic: "Explicit notebook review",
            sourceID: "source-a"
        )
        let unscopedID = sessionID(from: unscoped)
        #expect(!unscopedID.isEmpty)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(unscopedID)'"
        ) == nil)

        let scoped = try await store.startScopedReviewSession(
            topic: "Explicit notebook review",
            sourceID: "source-a",
            notebookID: notebook.id
        )
        let scopedID = sessionID(from: scoped)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT goal_id FROM review_sessions WHERE id = '\(scopedID)'"
        ) == notebook.id)
        #expect(scoped.contains("linked to your Notebook \"Review Notebook\""))
    }

    @Test("startReviewSession binds to the host chat session instead of creating a phantom one")
    func startReviewSessionBindsToHostSession() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        // Stand in for the session in-app Chat opens before the model calls any tool.
        let hostID = UUID().uuidString
        try store.knowledgeStore().createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)

        let started = try await store.startReviewSession(
            topic: "Please quiz me on AI for Bio fuzzy API problem drug discovery",
            hostSessionID: hostID
        )

        // No second session row: the review is the chat the learner is already in,
        // and the reviewed source is linked onto it.
        #expect(started.contains("Session ID: \(hostID)"))
        #expect(started.contains("This chat is the review session"))
        #expect(try store.reviewSessionSourceIDs(sessionID: hostID) == ["source-a"])
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("startReviewSession bound to a host chat ignores a caller idempotency key")
    func startReviewSessionIgnoresOperationIDForHostSession() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Metabolism",
            content: "Glycolysis yields ATP without oxygen."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let hostID = UUID().uuidString
        try store.knowledgeStore().createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)

        // The model was offered no such key, but a chat that passes one anyway is
        // still the review; the host session is the only identity that matters.
        for operationID in ["review-request-1", "", "   "] {
            let started = try await store.startReviewSession(
                topic: "Metabolism book review",
                sourceIDs: ["source-a"],
                operationID: operationID,
                hostSessionID: hostID
            )
            #expect(started.contains("Session ID: \(hostID)"))
        }
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
    }

    @Test("a blank operation_id from a remote caller means no idempotency key")
    func blankOperationIDMeansNone() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-a", title: "Metabolism", content: "Glycolysis yields ATP.")
        let store = MCPDataStore(dbPath: dbPath)

        _ = try await store.startReviewSession(topic: "Metabolism", sourceIDs: ["source-a"], operationID: "")
        _ = try await store.startReviewSession(topic: "Metabolism", sourceIDs: ["source-a"], operationID: "  ")

        // Two plain starts, two sessions: neither blank key was treated as a retry.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 2)
    }

    @Test("endReviewSession with a host chat ends that chat and does not duplicate its transcript")
    func endReviewSessionUsesHostSession() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        let store = MCPDataStore(dbPath: dbPath)
        let hostID = UUID().uuidString
        let knowledge = try store.knowledgeStore()
        try knowledge.createReviewSession(id: hostID, topic: "Chat", sourceIDs: [], startedAt: Date(), goalID: nil)
        _ = try knowledge.addReviewExchange(
            sessionID: hostID,
            question: "",
            answer: "The endpoints are underspecified.",
            evaluation: "Right — say why.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: []
        )

        // A lost or invented session id must still resolve back to the host chat.
        _ = try store.endReviewSession(
            sessionID: "00000000-DEAD-BEEF-0000-000000000000",
            hostSessionID: hostID,
            overallScore: 0.8,
            summary: "Solid on the fuzzy API issue.",
            transcript: "Claude: What makes the API fuzzy?\nMe: The endpoints are underspecified."
        )

        // One session, one exchange: the chat's own turns, not a re-imported copy.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_sessions") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(hostID)'") == 1)
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(hostID)'") == "completed")
    }

    @Test("end_review_session rejects missing, nonfinite, boolean, and out-of-range scores")
    func endReviewSessionRequiresStrictScore() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let sessionID = "strict-score-session"
        try store.knowledgeStore().createReviewSession(
            id: sessionID,
            topic: "Strict score",
            sourceIDs: [],
            startedAt: Date()
        )
        let registry = MCPToolRegistry(store: store)
        let invalidScores: [Any?] = [nil, true, Double.nan, -0.01, 1.01, "0.5"]

        for invalidScore in invalidScores {
            var arguments: [String: Any] = [
                "session_id": sessionID,
                "summary": "Must not complete.",
            ]
            if let invalidScore { arguments["overall_score"] = invalidScore }
            let outcome = await registry.callToolDetailed(
                name: "end_review_session",
                arguments: arguments,
                access: .internalFullAccess
            )
            #expect(outcome.isError)
            #expect(outcome.text.contains("overall_score"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
    }

    @Test("replaying whole session completion preserves endedAt, quiz count, gaps, and transcript")
    func endReviewSessionCompletionIsIdempotent() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-replay",
            title: "Replay-safe review",
            content: "Retrieval practice requires an unaided attempt before feedback."
        )
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Replay Notebook",
            topic: "retrieval",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-replay"]
        )
        let started = try await store.startScopedReviewSession(
            topic: "Replay-safe review",
            sourceID: "source-replay",
            notebookID: notebook.id
        )
        let id = parsedSessionID(from: started)
        let transcript = "Tutor: Why retrieve first?\nLearner: To expose what I can actually access."
        let gaps: [[String: Any]] = [[
            "summary": "Needs to distinguish retrieval strength from familiarity.",
            "source_id": "source-replay",
            "severity": 0.6,
            "status": "open",
        ]]

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.76,
            summary: "Understands the basic retrieval-before-feedback sequence.",
            transcript: transcript,
            gaps: gaps
        )
        let endedAt = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g', ended_at) FROM review_sessions WHERE id = '\(id)'"
        )
        let quizCount = try scalarInt(
            dbPath: dbPath,
            "SELECT quiz_count FROM learning_goal_items WHERE goal_id = '\(notebook.id)' AND source_id = 'source-replay'"
        )
        let gapCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = '\(notebook.id)'"
        )
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'"
        )

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.76,
            summary: "Understands the basic retrieval-before-feedback sequence.",
            transcript: transcript,
            gaps: gaps
        )

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g', ended_at) FROM review_sessions WHERE id = '\(id)'"
        ) == endedAt)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT quiz_count FROM learning_goal_items WHERE goal_id = '\(notebook.id)' AND source_id = 'source-replay'"
        ) == quizCount)
        #expect(quizCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = '\(notebook.id)'"
        ) == gapCount)
        #expect(gapCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'"
        ) == exchangeCount)
        #expect(exchangeCount == 1)
    }

    @Test("memoryReview returns durable concept IDs, reasons, rubrics, and anchors")
    func memoryReviewReturnsConceptPlan() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval practice strengthens later access more than passive rereading."
        try insertSource(
            dbPath: dbPath,
            id: "source-memory",
            title: "Retrieval practice",
            content: content
        )
        let now = Date()
        let item = MemoryItem(
            id: "memory-item",
            kind: .concept,
            target: "Explain why retrieval practice improves later access",
            rubricJSON: #"{"criteria":["Contrasts retrieval with rereading"]}"#,
            sources: [
                MemoryItemSource(
                    id: "memory-anchor",
                    memoryItemID: "memory-item",
                    sourceID: "source-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: now.addingTimeInterval(-10 * 86_400),
            updatedAt: now.addingTimeInterval(-10 * 86_400)
        )
        try store.knowledgeStore().saveMemoryItem(item)
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "memory-struggle-attempt",
                memoryItemID: item.id,
                attemptType: .review,
                prompt: "Why is retrieval different from rereading?",
                learnerAnswer: "Rereading makes it familiar.",
                feedback: "You did not explain the diagnostic effort of retrieval.",
                score: 0.4,
                scheduleRating: .hard,
                gradeState: .graded,
                evidenceJSON: #"{"missing_rubric_elements":["Contrasts retrieval with rereading"],"misconception":"Equates familiarity with recall","retrieval_quality":"hinted"}"#,
                attemptedAt: now.addingTimeInterval(-2 * 86_400)
            )
        )

        let output = try await store.memoryReview(
            goalID: nil,
            limit: 5,
            startSession: false
        )
        let payload = try parseJSON(output)
        let memoryItems = payload["memory_items"] as? [[String: Any]]
        let first = memoryItems?.first

        #expect(first?["item_id"] as? String == "memory-item")
        #expect(first?["reason"] as? String == "struggle")
        #expect(first?["learning_target"] as? String == item.target)
        #expect(first?["grading_rubric_json"] as? String == item.rubricJSON)
        #expect((first?["sources"] as? [[String: Any]])?.first?["source_id"] as? String == "source-memory")
        let prior = (first?["prior_struggles"] as? [[String: Any]])?.first
        #expect(prior?["retrieval_quality"] as? String == "hinted")
        #expect((prior?["missing_rubric_elements"] as? [String]) == ["Contrasts retrieval with rereading"])
        #expect(prior?["misconception"] as? String == "Equates familiarity with recall")
        #expect(first?["ask"] == nil, "a target from before cards is worded afresh")
    }

    @Test("memoryReview hands over a kept card's wording to ask, the learner's rewording when there is one")
    func memoryReviewAsksKeptCardsAsWorded() async throws {
        // The card state rows in a suite of the test's own: on a host whose library syncs generation 2,
        // the standard defaults' rows give way to the Card records (`MemoryCardStateStore.usesCardRecords`),
        // so a rewording written there would never be read.
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        let content = "Retrieval practice strengthens later access more than passive rereading."
        try insertSource(dbPath: dbPath, id: "source-card", title: "Retrieval practice", content: content)
        let now = Date()
        let card = MemoryCard(
            cardID: "card-\(UUID().uuidString)",
            front: "What strengthens later access more than rereading?",
            back: "Retrieval practice.",
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "source-card")
        )
        let knowledge = try store.knowledgeStore()
        let item = try knowledge.keepMemoryCard(
            card, sourceID: "source-card", quote: "Retrieval practice strengthens later access",
            at: now.addingTimeInterval(-10 * 86_400)
        )
        #expect(try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: card.front, remembered: false, sessionKey: "review-1",
            at: now.addingTimeInterval(-2 * 86_400)
        ) == .recorded)

        func askedWording() async throws -> String? {
            let payload = try parseJSON(try await store.memoryReview(goalID: nil, limit: 5, startSession: false))
            let entry = (payload["memory_items"] as? [[String: Any]])?.first { $0["item_id"] as? String == item.id }
            return entry?["ask"] as? String
        }
        #expect(try await askedWording() == card.front)

        // The learner's own rewording lives in the deck's state row, not the item.
        let key = MemoryCardDeckState.preferenceKey(deckID: try #require(card.deckID))
        var row = MemoryCardDeckState()
        row.markKept(cardID: card.cardID, memoryItemID: item.id, at: now)
        row.cards[card.cardID]?.editedFront = "Which beats rereading for later access?"
        defaults.set(row.preferenceValue, forKey: key)
        #expect(try await askedWording() == "Which beats rereading for later access?")
        #expect(MCPDataStore.memoryReviewSessionInstructions.contains("An item with `ask` is a card the learner kept"))
    }

    // MARK: Memory cards: save_card_drafts, list_cards, triage_cards

    /// A store whose card tools keep their state rows in a defaults suite of
    /// their own, so nothing reaches the host's defaults or its sync queue.
    private func makeCardStore() throws -> (store: MCPDataStore, dbPath: String, defaults: UserDefaults, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_cards_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("knowledge.db").path
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = MCPDataStore(dbPath: dbPath, cardStateDefaults: defaults)
        _ = try store.knowledgeStore()
        return (store, dbPath, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tmpDir)
        })
    }

    private static let cardSourceText = "Retrieval practice strengthens later access more than passive rereading. Spacing the practice helps too."

    @Test("The card tools are registered: list_cards only reads, triage_cards can drop cards for good, and a study chat saves drafts")
    func cardToolsAreRegistered() {
        let names = Set(MCPToolRegistry(store: MCPDataStore()).tools.map(\.name))
        #expect(names.isSuperset(of: ["save_card_drafts", "list_cards", "triage_cards"]))
        #expect(MCPToolRegistry.annotations(for: "list_cards")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "triage_cards")["destructiveHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "save_card_drafts")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "save_card_drafts")["destructiveHint"] as? Bool == false)
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("save_card_drafts"))
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("save_card_drafts"), "drafts an assistant wrote cost nothing to save")
    }

    @Test("save_card_drafts saves grounded cards, free, to wait in To Check, refuses an unknown source, and the deck is never a Doc")
    func saveCardDraftsTool() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)

        let payload = try parseJSON(try await store.saveCardDrafts(cards: [
            [
                "source_id": "source-cards",
                "front": "What strengthens later access more than rereading?",
                "back": "Retrieval practice.",
                "why": "Recalling is itself practice.",
                "quote": "Retrieval practice strengthens later access",
                "difficulty": "easy",
                "seed": "guide:q1",
                "back_images": [
                    "![Retrieval curve](foreverlm://image/source-cards/page/2)",
                    ["target": "foreverlm://image/source-cards/page/3", "alt": "Spacing comparison"],
                ],
            ],
            ["source_id": "source-cards", "front": "What does rereading feel like?", "back": "Familiar.", "quote": "words the source never printed"],
            ["source_id": "source-cards", "front": "A card without an answer?", "quote": "Spacing the practice helps too"],
        ], keptByDefault: true))
        #expect(payload["saved_count"] as? Int == 1)
        let entry = try #require((payload["sources"] as? [[String: Any]])?.first)
        #expect(entry["source_id"] as? String == "source-cards")
        #expect((entry["saved_card_ids"] as? [String])?.count == 1)
        #expect((entry["not_grounded"] as? [[String: Any]])?.first?["front"] as? String == "What does rereading feel like?")
        #expect((payload["incomplete"] as? [[String: Any]])?.first?["missing"] as? [String] == ["back"])

        // It waits in To Check, kept by default since the learner asked for it.
        let listed = try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil))
        let card = try #require((listed["to_check"] as? [[String: Any]])?.first)
        #expect(card["kind"] as? String == "draft")
        #expect(card["kept_by_default"] as? Bool == true)
        #expect(card["origin"] as? String == MemoryCardOrigin.assistant.rawValue)
        #expect(card["seed"] as? String == "guide:q1")
        #expect(card["source_title"] as? String == "Retrieval practice")
        #expect(card["expires_at"] != nil)
        let backImages = try #require(card["back_images"] as? [[String: Any]])
        #expect(backImages.compactMap { $0["alt"] as? String } == ["Retrieval curve", "Spacing comparison"])
        #expect(MemoryCardStateStore.load(deckID: MemoryCard.draftDeckID(sourceID: "source-cards"), defaults: defaults).cards.isEmpty, "saving writes no state row")

        // An id the library does not hold refuses the whole call and names list_sources.
        do {
            _ = try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "Q?", "back": "A.", "quote": "Spacing the practice helps too"],
                ["source_id": "no-such-source", "front": "Q?", "back": "A.", "quote": "x"],
            ], keptByDefault: false)
            Issue.record("An unknown source id was accepted")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_sources"))
            #expect(error.localizedDescription.contains("no-such-source"))
        }
        #expect((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check_count"] as? Int == 1)

        // The deck is the learner's own memory state and no Doc: list_docs
        // never lists it, and every Doc tool refuses its id.
        let docs = try parseJSON(try await store.listArtifacts(notebookID: nil))
        #expect((docs["docs"] as? [[String: Any]])?.isEmpty == true)
        let registry = MCPToolRegistry(store: store)
        for (tool, arguments) in [
            ("read_doc", ["doc_id": MemoryCard.draftDeckID(sourceID: "source-cards")]),
            ("delete_doc", ["doc_id": MemoryCard.draftDeckID(sourceID: "source-cards")]),
        ] as [(String, [String: Any])] {
            let outcome = await registry.callToolDetailed(name: tool, arguments: arguments)
            #expect(outcome.isError, "\(tool) answered \(outcome.text)")
            #expect(outcome.text.contains("list_cards"), "\(tool) answered \(outcome.text)")
        }
        #expect(try store.knowledgeStore().loadArtifact(MemoryCard.draftDeckID(sourceID: "source-cards")) != nil)
    }

    @Test("triage_cards keeps, edits and skips cards to check on the learner's word, and list_cards lists the kept ones with the wording to ask")
    func listAndTriageCardsTools() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access?", "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access", "seed": "q1"],
            ["source_id": "source-cards", "front": "What else helps?", "back": "Spacing.", "quote": "Spacing the practice helps too", "seed": "q2"],
            ["source_id": "source-cards", "front": "Is rereading passive?", "back": "Yes.", "quote": "passive rereading", "seed": "q3"],
        ], keptByDefault: false)
        let listed = try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: "source-cards", limit: nil))
        #expect(listed["to_check_count"] as? Int == 3)
        #expect(listed["to_check_summary"] as? String == "3 cards from 1 source")
        let ids = (listed["to_check"] as? [[String: Any]] ?? []).compactMap { $0["card_id"] as? String }
        #expect(ids.count == 3)

        // A decision with no such action changes nothing.
        do {
            _ = try await store.triageCards(decisions: [["card_id": ids[0], "action": "archive"]], keepSourceIDs: [], skipSourceIDs: [])
            Issue.record("An unknown action was accepted")
        } catch is MCPError {}

        let triaged = try parseJSON(try await store.triageCards(decisions: [
            ["card_id": ids[0], "action": "keep"],
            ["card_id": ids[1], "action": "keep", "front": "Besides retrieval, what helps later access?"],
            ["card_id": ids[2], "action": "skip"],
            ["card_id": "card-nobody-drafted", "action": "keep"],
        ], keepSourceIDs: [], skipSourceIDs: []))
        #expect((triaged["kept"] as? [[String: Any]])?.count == 2)
        #expect(triaged["skipped"] as? [String] == [ids[2]])
        #expect(triaged["not_found"] as? [String] == ["card-nobody-drafted"])
        #expect(triaged["to_check_count"] as? Int == 0)
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")
        #expect(MemoryCardStateStore.state(cardID: ids[2], deckID: deckID, defaults: defaults)?.status == .skipped)
        #expect(MemoryCardStateStore.state(cardID: ids[0], deckID: deckID, defaults: defaults)?.status == .kept)

        let kept = try parseJSON(try await store.listCards(status: "kept", notebookID: nil, sourceID: nil, limit: nil))
        let cards = kept["kept"] as? [[String: Any]] ?? []
        #expect(Set(cards.compactMap { $0["ask"] as? String }) == ["What strengthens later access?", "Besides retrieval, what helps later access?"])
        #expect(cards.allSatisfy { $0["schedule"] as? String == "new" }, "a kept card is first asked the day after it is kept")
        #expect(cards.allSatisfy { ($0["item_id"] as? String)?.hasPrefix("memory-card-v1") == true })
        #expect((try parseJSON(try await store.listCards(status: nil, notebookID: nil, sourceID: nil, limit: nil)))["to_check_count"] as? Int == 0)
    }

    @Test("triage_cards decides a source's cards at once, and list_cards narrows to one Notebook's sources")
    func triageCardsBySourceAndNotebook() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-other", title: "Sleep", content: "Sleep consolidates what was learned during the day.")
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "What strengthens later access?", "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access"],
            ["source_id": "source-cards", "front": "What else helps?", "back": "Spacing.", "quote": "Spacing the practice helps too"],
            ["source_id": "source-other", "front": "What does sleep do to learning?", "back": "It consolidates it.", "quote": "Sleep consolidates what was learned"],
        ], keptByDefault: false)
        let ks = try store.knowledgeStore()
        let notebook = try ks.createCompanionGoal(
            title: "Retrieval", topic: "retrieval", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["source-cards"]
        )
        let inNotebook = try parseJSON(try await store.listCards(status: nil, notebookID: notebook.id, sourceID: nil, limit: nil))
        #expect(inNotebook["to_check_count"] as? Int == 2)
        #expect(Set((inNotebook["to_check"] as? [[String: Any]] ?? []).compactMap { $0["source_id"] as? String }) == ["source-cards"])

        let triaged = try parseJSON(try await store.triageCards(
            decisions: [], keepSourceIDs: ["source-cards"], skipSourceIDs: ["source-other", "source-unknown"]
        ))
        #expect((triaged["kept"] as? [[String: Any]])?.count == 2)
        #expect((triaged["skipped"] as? [String])?.count == 1)
        #expect(triaged["sources_with_nothing_to_check"] as? [String] == ["source-unknown"])
        #expect(try ks.loadMemoryItems().count == 2)

        // The same source in both lists is refused before anything is written.
        do {
            _ = try await store.triageCards(decisions: [], keepSourceIDs: ["source-cards"], skipSourceIDs: ["source-cards"])
            Issue.record("A source both kept and skipped was accepted")
        } catch is MCPError {}
    }

    // MARK: The card review over MCP: get_due_cards, record_card_result, update_card

    /// A card kept on `source-cards` `daysAgo` days ago, its state in the
    /// source's deck.
    private func keepCard(
        _ store: MCPDataStore,
        front: String,
        back: String,
        quote: String,
        keptDaysAgo: Double
    ) throws -> (card: MemoryCard, item: MemoryItem) {
        let card = MemoryCard(
            cardID: "card-\(UUID().uuidString)",
            front: front,
            back: back,
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "source-cards")
        )
        let item = try store.knowledgeStore().keepMemoryCard(
            card, sourceID: "source-cards", quote: quote,
            at: Date().addingTimeInterval(-keptDaysAgo * 86_400)
        )
        return (card, item)
    }

    @Test("The card review's tools are registered: get_due_cards only reads, record_card_result takes nothing back, update_card can retire a card")
    func cardReviewToolsAreRegistered() {
        let registry = MCPToolRegistry(store: MCPDataStore())
        let names = Set(registry.tools.map(\.name))
        #expect(names.isSuperset(of: ["get_due_cards", "record_card_result", "update_card"]))
        #expect(MCPToolRegistry.annotations(for: "get_due_cards")["readOnlyHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "record_card_result")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "record_card_result")["destructiveHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: "update_card")["destructiveHint"] as? Bool == true)
        #expect(!MCPToolRegistry.paidWorkToolNames.contains("record_card_result"), "an answer costs nothing")
        let recordSchema = registry.tools.first { $0.name == "record_card_result" }?.inputSchema
        #expect(recordSchema?["required"] as? [String] == ["remembered"])
        #expect(recordSchema?["anyOf"] == nil && recordSchema?["oneOf"] == nil, "either id is said in the description, never a top-level anyOf")
        // The assistant-facing texts say how a kept card is asked.
        #expect(Prompts.mcpServerInstructions.contains("get_due_cards"))
        #expect(registry.tools.first { $0.name == "memory_review" }?.description.contains("get_due_cards") == true)
        #expect(MCPDataStore.cohortConductInstructions.contains("through get_due_cards or memory_review"))
        #expect(MCPDataStore.dueCardsInstructions.contains("exactly as written"))
    }

    @Test("get_due_cards deals today's cards in the card review's order with the wording to ask, and narrows to a Notebook")
    func getDueCardsDealsToday() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        try insertSource(dbPath: dbPath, id: "source-other", title: "Sleep", content: "Sleep consolidates what was learned during the day.")
        let knowledge = try store.knowledgeStore()
        let now = Date()
        // Due: kept ten days ago and forgotten two days ago.
        let (dueCard, due) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 10)
        #expect(try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: dueCard.front, remembered: false, sessionKey: "earlier",
            at: now.addingTimeInterval(-2 * 86_400)
        ) == .recorded)
        // New and eligible: kept two days ago, never answered.
        let (newCard, fresh) = try keepCard(store, front: "What else helps?", back: "Spacing.", quote: "Spacing the practice helps too", keptDaysAgo: 2)
        // Kept just now: first asked tomorrow, so not today's.
        let (_, keptToday) = try keepCard(store, front: "Is rereading passive?", back: "Yes.", quote: "passive rereading", keptDaysAgo: 0)

        let payload = try parseJSON(try await store.getDueCards(notebookID: nil, limit: nil))
        let cards = payload["cards"] as? [[String: Any]] ?? []
        #expect(cards.compactMap { $0["item_id"] as? String } == [due.id, fresh.id], "due first, then new; a card kept today waits")
        #expect(!cards.contains { $0["item_id"] as? String == keptToday.id })
        #expect(cards.first?["ask"] as? String == dueCard.front)
        #expect(cards.first?["back"] as? String == "Retrieval practice.")
        #expect(cards.first?["card_id"] as? String == dueCard.cardID)
        #expect(cards.first?["is_new"] as? Bool == false)
        #expect(cards.first?["source_title"] as? String == "Retrieval practice")
        #expect(cards.first?["quote"] as? String == "Retrieval practice strengthens later access")
        #expect(cards.last?["is_new"] as? Bool == true)
        #expect(cards.last?["reason"] as? String == "new")
        #expect(payload["due_count"] as? Int == 1)
        #expect(payload["new_count"] as? Int == 1)
        #expect((payload["sitting_id"] as? String)?.hasPrefix("mcp-cards-") == true)
        #expect((payload["instructions"] as? String)?.contains("record_card_result") == true)

        // The learner's own rewording is the wording to ask.
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")
        var row = MemoryCardStateStore.load(deckID: deckID, defaults: defaults)
        row.markKept(cardID: newCard.cardID, memoryItemID: fresh.id, at: now)
        row.cards[newCard.cardID]?.editedFront = "Besides retrieval, what helps later access?"
        defaults.set(row.preferenceValue, forKey: MemoryCardDeckState.preferenceKey(deckID: deckID))
        let reworded = try parseJSON(try await store.getDueCards(notebookID: nil, limit: nil))
        #expect((reworded["cards"] as? [[String: Any]])?.last?["ask"] as? String == "Besides retrieval, what helps later access?")

        // A Notebook's cards are those on its sources.
        let notebook = try knowledge.createCompanionGoal(
            title: "Sleep", topic: "sleep", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["source-other"]
        )
        let narrowed = try parseJSON(try await store.getDueCards(notebookID: notebook.id, limit: nil))
        #expect((narrowed["cards"] as? [[String: Any]])?.isEmpty == true)
        #expect((narrowed["notebook"] as? [String: Any])?["notebook_id"] as? String == notebook.id)
        let limited = try parseJSON(try await store.getDueCards(notebookID: nil, limit: 1))
        #expect((limited["cards"] as? [[String: Any]])?.count == 1)
        #expect(limited["listed"] as? Int == 1)
    }

    @Test("record_card_result records a self-graded answer by the card review's rules, once a sitting, and refuses what is no kept card")
    func recordCardResultTool() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let (dueCard, due) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 10)
        _ = try knowledge.recordSelfGradedMemoryCardAttempt(
            memoryItemID: due.id, prompt: dueCard.front, remembered: false, sessionKey: "earlier",
            at: now.addingTimeInterval(-2 * 86_400)
        )

        let recorded = try parseJSON(try await store.recordCardResult(
            cardID: dueCard.cardID, itemID: nil, remembered: true,
            asked: "Which strengthens later access?", sittingID: "mcp-cards-test", practice: nil
        ))
        #expect(recorded["outcome"] as? String == "recorded")
        #expect(recorded["item_id"] as? String == due.id)
        #expect(recorded["next_due_at"] != nil)
        let attempt = try #require(try knowledge.loadMemoryAttempts(memoryItemID: due.id).first { $0.attemptedAt > now.addingTimeInterval(-60) })
        #expect(attempt.prompt == "Which strengthens later access?", "the wording asked is the attempt's question")
        #expect(attempt.learnerAnswer == MemoryAttempt.selfGradedAnswer)
        #expect(attempt.score == 1)
        #expect(attempt.scheduleRating == .good)
        #expect(attempt.gradeState == .graded)
        #expect(attempt.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "mcp-cards-test", memoryItemID: due.id))

        // The same answer sent again in the sitting is counted once; another
        // sitting finds the card not due any more, and an early answer never
        // moves its schedule.
        let again = try parseJSON(try await store.recordCardResult(
            cardID: nil, itemID: due.id, remembered: false, asked: nil, sittingID: "mcp-cards-test", practice: nil
        ))
        #expect(again["outcome"] as? String == "already_recorded")
        let early = try parseJSON(try await store.recordCardResult(
            cardID: dueCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: "mcp-cards-later", practice: nil
        ))
        #expect(early["outcome"] as? String == "not_counted")
        #expect(try knowledge.loadMemoryAttempts(memoryItemID: due.id).count == 2)

        // A card kept today is first asked tomorrow, unless the learner asked
        // to practise it; without asked, the card's own wording is recorded.
        let (todayCard, today) = try keepCard(store, front: "What else helps?", back: "Spacing.", quote: "Spacing the practice helps too", keptDaysAgo: 0)
        let notYet = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: nil, practice: nil
        ))
        #expect(notYet["outcome"] as? String == "not_counted")
        #expect((notYet["message"] as? String)?.contains("practice") == true)
        let practised = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: false, asked: nil, sittingID: nil, practice: true
        ))
        #expect(practised["outcome"] as? String == "recorded")
        #expect(practised["asked"] as? String == todayCard.front)
        #expect((practised["sitting_id"] as? String)?.hasPrefix("mcp-cards-") == true, "one sitting a day without sitting_id")
        #expect(try knowledge.loadMemoryAttempts(memoryItemID: today.id).first?.scheduleRating == .again)

        // A retired card is never recorded.
        try knowledge.retireMemoryCard(memoryItemID: today.id)
        let retired = try parseJSON(try await store.recordCardResult(
            cardID: todayCard.cardID, itemID: nil, remembered: true, asked: nil, sittingID: "mcp-other", practice: true
        ))
        #expect(retired["outcome"] as? String == "retired")

        // Refusals: no answer, a number for a boolean, no id, two cards, a
        // card still to check, an id no card answers to.
        _ = try await store.saveCardDrafts(cards: [
            ["source_id": "source-cards", "front": "Is rereading passive?", "back": "Yes.", "quote": "passive rereading"],
        ], keptByDefault: false)
        let draftID = try #require((try parseJSON(try await store.listCards(status: "to_check", notebookID: nil, sourceID: nil, limit: nil))["to_check"] as? [[String: Any]])?.first?["card_id"] as? String)
        let refusals: [(String?, String?, Any?, String)] = [
            (dueCard.cardID, nil, nil, "remembered is required"),
            (dueCard.cardID, nil, 1, "true or false"),
            (nil, nil, true, "card_id"),
            (dueCard.cardID, today.id, true, "two different cards"),
            (draftID, nil, true, "triage_cards"),
            ("card-nobody-kept", nil, true, "No kept card"),
        ]
        for (cardID, itemID, remembered, expected) in refusals {
            do {
                _ = try await store.recordCardResult(cardID: cardID, itemID: itemID, remembered: remembered, asked: nil, sittingID: "mcp-refused", practice: nil)
                Issue.record("record_card_result accepted \(String(describing: cardID)) / \(String(describing: remembered))")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains(expected), "\(error.localizedDescription)")
            }
        }
        #expect(try knowledge.loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: draftID)) == nil, "a card to check stays a draft")
    }

    @Test("save_card_drafts and update_card hold every card to standing on its own: reworded once, or refused with the reason")
    func cardWordingGateOverMCP() async throws {
        let (store, dbPath, _, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let wording = CannedCardWording(pointing: ["this lecture", "the speaker"]) { question in
            question.contains("this lecture") ? "In retrieval research, what strengthens later access more than rereading?" : nil
        }
        try await CardWordingGate.$backendOverride.withValue(wording) {
            let payload = try parseJSON(try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "In this lecture, what strengthens later access more than rereading?",
                 "back": "Retrieval practice.", "quote": "Retrieval practice strengthens later access"],
                ["source_id": "source-cards", "front": "What does the speaker say spacing does?",
                 "back": "It helps too.", "quote": "Spacing the practice helps too"],
            ], keptByDefault: false))
            #expect(payload["saved_count"] as? Int == 1)
            let entry = try #require((payload["sources"] as? [[String: Any]])?.first)
            let reworded = try #require((entry["reworded"] as? [[String: Any]])?.first)
            #expect(reworded["was"] as? String == "In this lecture, what strengthens later access more than rereading?")
            #expect(reworded["front"] as? String == "In retrieval research, what strengthens later access more than rereading?")
            let refused = try #require((entry["not_standalone"] as? [[String: Any]])?.first)
            #expect(refused["front"] as? String == "What does the speaker say spacing does?")
            #expect((refused["reason"] as? String)?.contains("points at its source") == true)
            #expect(payload["wording_guidance"] != nil)

            // update_card: new words that point at the source and do not
            // mend are refused, and nothing changes.
            let (card, _) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 3)
            do {
                _ = try await store.updateCard(
                    cardID: card.cardID, itemID: nil, front: "What does the speaker call it?", back: nil, why: nil,
                    startOver: nil, alwaysAsk: nil, retire: nil
                )
                Issue.record("update_card saved a card that points at its source")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("points at its source"), "\(error.localizedDescription)")
            }
        }

        // A check that cannot run saves nothing, and says why.
        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        try await CardWordingGate.$backendOverride.withValue(down) {
            let payload = try parseJSON(try await store.saveCardDrafts(cards: [
                ["source_id": "source-cards", "front": "What helps besides retrieval?", "back": "Spacing the practice.", "quote": "Spacing the practice helps too"],
            ], keptByDefault: false))
            #expect(payload["saved_count"] as? Int == 0)
            let reason = (payload["sources_not_saved"] as? [[String: Any]])?.first?["reason"] as? String
            #expect(reason?.contains("could not be checked") == true)
        }
    }

    @Test("update_card rewords, holds, starts over and retires a kept card as All Cards does")
    func updateCardTool() async throws {
        let (store, dbPath, defaults, cleanup) = try makeCardStore()
        defer { cleanup() }
        try insertSource(dbPath: dbPath, id: "source-cards", title: "Retrieval practice", content: Self.cardSourceText)
        let knowledge = try store.knowledgeStore()
        let (card, item) = try keepCard(store, front: "What strengthens later access?", back: "Retrieval practice.", quote: "Retrieval practice strengthens later access", keptDaysAgo: 3)
        let deckID = MemoryCard.draftDeckID(sourceID: "source-cards")

        // A new front alone rewords it: the item and its schedule stay.
        let reworded = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: "Which beats rereading for later access?", back: nil, why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(reworded["changed"] as? Bool == true)
        #expect(reworded["ask"] as? String == "Which beats rereading for later access?")
        #expect(reworded["item_id"] as? String == item.id)
        #expect(MemoryCardStateStore.state(cardID: card.cardID, deckID: deckID, defaults: defaults)?.editedFront == "Which beats rereading for later access?")
        #expect(try knowledge.loadMemoryItem(item.id)?.status == .active)
        let kept = try parseJSON(try await store.listCards(status: "kept", notebookID: nil, sourceID: nil, limit: nil))
        #expect((kept["kept"] as? [[String: Any]])?.first?["ask"] as? String == "Which beats rereading for later access?")
        // The same words again change nothing; the words it was kept with clear the rewording.
        let unchanged = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: "Which beats rereading for later access?", back: nil, why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(unchanged["changed"] as? Bool == false)
        _ = try await store.updateCard(cardID: card.cardID, itemID: nil, front: card.front, back: nil, why: nil, startOver: nil, alwaysAsk: true, retire: nil)
        let held = MemoryCardStateStore.state(cardID: card.cardID, deckID: deckID, defaults: defaults)
        #expect(held?.editedFront == nil)
        #expect(held?.alwaysAsk == true)

        // A new back starts it over: a new card, the old one retired.
        let restarted = try parseJSON(try await store.updateCard(
            cardID: card.cardID, itemID: nil, front: nil, back: "Practising retrieval.", why: nil,
            startOver: nil, alwaysAsk: nil, retire: nil
        ))
        #expect(restarted["started_over"] as? Bool == true)
        #expect(restarted["previous_item_id"] as? String == item.id)
        let newItemID = try #require(restarted["item_id"] as? String)
        let newCardID = try #require(restarted["card_id"] as? String)
        #expect(newItemID != item.id && newCardID != card.cardID)
        #expect(try knowledge.loadMemoryItem(item.id)?.status == .retired)
        let revision = try #require(try knowledge.loadMemoryItem(newItemID))
        #expect(revision.target == "Practising retrieval.")
        #expect(MemoryCard(storedIn: revision)?.front == card.front, "asked as it was asked before")
        #expect(MemoryCardStateStore.state(cardID: newCardID, deckID: deckID, defaults: defaults)?.alwaysAsk == true, "a card started over keeps always ask")

        // Refusals: nothing asked, retire with an edit, an empty front, a retired card.
        let refusals: [(String?, String?, Any?, Any?, String)] = [
            (nil, nil, nil, nil, "Pass front"),
            ("New words", nil, nil, true, "retire takes no other change"),
            ("  ", nil, nil, nil, "front and a back"),
        ]
        for (front, back, startOver, retire, expected) in refusals {
            do {
                _ = try await store.updateCard(cardID: newCardID, itemID: nil, front: front, back: back, why: nil, startOver: startOver, alwaysAsk: nil, retire: retire)
                Issue.record("update_card accepted \(String(describing: front))")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains(expected), "\(error.localizedDescription)")
            }
        }
        do {
            _ = try await store.updateCard(cardID: card.cardID, itemID: nil, front: "Again?", back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: nil)
            Issue.record("A retired card was changed")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("retired"))
        }

        // Retire: never asked again; retiring again says so.
        let retired = try parseJSON(try await store.updateCard(cardID: newCardID, itemID: nil, front: nil, back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: true))
        #expect(retired["retired"] as? Bool == true)
        #expect(try knowledge.loadMemoryItem(newItemID)?.status == .retired)
        let twice = try parseJSON(try await store.updateCard(cardID: nil, itemID: newItemID, front: nil, back: nil, why: nil, startOver: nil, alwaysAsk: nil, retire: true))
        #expect((twice["message"] as? String)?.contains("already") == true)
    }

    @Test("memoryReview reserves one legacy intake slot beside four due concepts")
    func memoryReviewMatchesSharedFiveItemSelection() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let attemptedAt = now.addingTimeInterval(-30 * 86_400)

        for index in 0..<5 {
            let sourceID = "concept-source-\(index)"
            let itemID = "concept-item-\(index)"
            let content = "Concept \(index) requires effortful retrieval before corrective feedback."
            try insertSource(
                dbPath: dbPath,
                id: sourceID,
                title: "Concept \(index)",
                content: content
            )
            try knowledge.saveMemoryItem(
                MemoryItem(
                    id: itemID,
                    kind: .concept,
                    target: "Explain concept \(index)",
                    rubricJSON: #"{"criteria":["Explains the mechanism"]}"#,
                    sources: [
                        MemoryItemSource(
                            id: "concept-anchor-\(index)",
                            memoryItemID: itemID,
                            sourceID: sourceID,
                            excerpt: content,
                            sourceSHA256: PaperContentPreparationService.sha256(content),
                            sortIndex: 0
                        ),
                    ],
                    createdAt: attemptedAt.addingTimeInterval(-86_400),
                    updatedAt: attemptedAt.addingTimeInterval(-86_400)
                )
            )
            _ = try knowledge.recordMemoryAttempt(
                MemoryAttempt(
                    id: "concept-attempt-\(index)",
                    memoryItemID: itemID,
                    attemptType: .review,
                    prompt: "Explain concept \(index).",
                    learnerAnswer: "A partial explanation.",
                    feedback: "Retrieve it again later.",
                    score: 0.8,
                    scheduleRating: .good,
                    gradeState: .graded,
                    attemptedAt: attemptedAt
                )
            )
        }

        let legacyContent = "A legacy source-level review must become a concept trace."
        try insertSource(
            dbPath: dbPath,
            id: "legacy-intake-source",
            title: "Legacy intake",
            content: legacyContent
        )
        try knowledge.createReviewSession(
            id: "legacy-intake-session",
            topic: "Legacy intake review",
            sourceIDs: ["legacy-intake-source"],
            startedAt: attemptedAt
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "legacy-intake-session",
            question: "What is the mechanism?",
            answer: "I do not remember.",
            evaluation: "Needs another retrieval.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["legacy-intake-source"],
            answeredAt: attemptedAt
        )
        try knowledge.completeReviewSession(
            sessionID: "legacy-intake-session",
            overallScore: 0.2,
            summary: "Weak legacy recall.",
            endedAt: attemptedAt
        )

        let payload = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 5,
                startSession: false
            )
        )
        let conceptItems = try #require(payload["memory_items"] as? [[String: Any]])
        let legacyItems = try #require(payload["items"] as? [[String: Any]])
        let newItems = try #require(payload["new_items"] as? [[String: Any]])

        #expect(conceptItems.count == 4)
        #expect(legacyItems.count == 1)
        #expect(legacyItems.first?["source_id"] as? String == "legacy-intake-source")
        #expect(newItems.isEmpty)
    }

    @Test("memoryReview operation id reuses one session and rejects changed arguments")
    func memoryReviewStartIsIdempotentByOperationID() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let content = "Retrieval before feedback exposes accessible knowledge."
        try insertSource(
            dbPath: dbPath,
            id: "operation-source",
            title: "Operation identity",
            content: content
        )
        let old = Date().addingTimeInterval(-20 * 86_400)
        try knowledge.saveMemoryItem(
            MemoryItem(
                id: "operation-item",
                kind: .concept,
                target: "Explain retrieval before feedback",
                rubricJSON: #"{"criteria":["Explains diagnostic effort"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "operation-anchor",
                        memoryItemID: "operation-item",
                        sourceID: "operation-source",
                        excerpt: content,
                        sourceSHA256: PaperContentPreparationService.sha256(content),
                        sortIndex: 0
                    ),
                ],
                createdAt: old.addingTimeInterval(-86_400),
                updatedAt: old.addingTimeInterval(-86_400)
            )
        )
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "operation-attempt",
                memoryItemID: "operation-item",
                attemptType: .review,
                prompt: "Explain retrieval before feedback.",
                learnerAnswer: "It reveals what is accessible.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old
            )
        )

        let first = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "provider-call-42"
            )
        )
        let firstSessionID = try #require(first["session_id"] as? String)
        let persistedPlan = try #require(
            try knowledge.loadReviewSessionForSync(firstSessionID)
        )
        #expect(persistedPlan.sourceIDs == ["operation-source"])
        let launchedItem = try #require(try knowledge.loadMemoryItem("operation-item"))
        #expect(persistedPlan.cardIDs == [
            "memory-item-v2:\(MemoryTutorIdentity.immutableCurriculumFingerprint(launchedItem)):operation-item"
        ])
        let lateContent = "A later sync must not replace the queue chosen by an existing operation."
        try insertSource(
            dbPath: dbPath,
            id: "operation-source-late",
            title: "Late operation source",
            content: lateContent
        )
        let lateItem = MemoryItem(
            id: "operation-item-late",
            kind: .concept,
            target: "Explain stable operation replay",
            rubricJSON: #"{"criteria":["Explains stable replay"]}"#,
            sources: [
                MemoryItemSource(
                    id: "operation-anchor-late",
                    memoryItemID: "operation-item-late",
                    sourceID: "operation-source-late",
                    excerpt: lateContent,
                    sourceSHA256: PaperContentPreparationService.sha256(lateContent),
                    sortIndex: 0
                ),
            ],
            createdAt: old.addingTimeInterval(-100 * 86_400),
            updatedAt: old.addingTimeInterval(-100 * 86_400)
        )
        try knowledge.saveMemoryItem(lateItem)
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "operation-attempt-late",
                memoryItemID: lateItem.id,
                attemptType: .review,
                prompt: "Why must a retry be stable?",
                learnerAnswer: "It prevents the request from changing underneath the caller.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(-100 * 86_400)
            )
        )
        let second = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "provider-call-42"
            )
        )
        let sessionID = try #require(first["session_id"] as? String)
        let firstIDs = (first["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String }
        let secondIDs = (second["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String }

        #expect(second["session_id"] as? String == sessionID)
        #expect(secondIDs == firstIDs)
        #expect(secondIDs == ["operation-item"])
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id = '\(sessionID)'"
        ) == 1)

        do {
            _ = try await store.memoryReview(
                goalID: nil,
                limit: 2,
                startSession: true,
                operationID: "provider-call-42"
            )
            Issue.record("Expected changed arguments for a reused operation_id to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("different memory_review arguments"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'mcp-memory-review-operation-%'"
        ) == 1)

        // Simulate CloudKit adopting a divergent server curriculum under the
        // same deterministic item ID after the assistant received its queue.
        try execSQL(
            dbPath: dbPath,
            "UPDATE memory_items SET target = 'Replacement server curriculum' WHERE id = 'operation-item'"
        )
        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0.8,
                summary: "Must remain open after curriculum replacement.",
                transcript: "Tutor: Explain retrieval.\nLearner: It reveals accessible knowledge.",
                memoryAttempts: [[
                    "item_id": "operation-item",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                    "evaluation": "Good.",
                    "prompt": "Explain retrieval before feedback.",
                    "learner_answer": "It reveals what is accessible.",
                ]]
            )
            Issue.record("Expected a replaced queued curriculum to fail closed")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("changed after this review was prepared"))
        }
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM memory_attempts WHERE session_id = '\(sessionID)'"
        ) == 0)
    }

    @Test("memoryReview replay resolves a portable first-review card after source id remap")
    func memoryReviewReplayResolvesPortableFirstReviewSource() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let localSourceID = "local-portable-review-source"
        let foreignSourceID = "foreign-portable-review-source"
        let normalizedURL = "https://example.com/\(localSourceID)"
        try insertSource(
            dbPath: dbPath,
            id: localSourceID,
            title: "Portable first review",
            content: "Portable source identity keeps a queued first review stable across devices."
        )
        let portableKey = try knowledge.portableMemorySourceKey(sourceID: localSourceID)
        let operation = try #require(try store.deterministicMCPOperationSessionIdentity(
            "portable-first-review-retry",
            namespace: "memory-review-v1",
            sessionPrefix: "mcp-memory-review",
            requestFields: [
                "version": 1,
                "goal_id": NSNull(),
                "limit": 1,
            ]
        ))
        try knowledge.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: operation.sessionID,
                topic: "Daily memory refresh",
                startedAt: Date(timeIntervalSinceReferenceDate: 500),
                endedAt: nil,
                status: "active",
                overallScore: nil,
                summary: nil,
                sourceIDs: [foreignSourceID],
                cardIDs: ["new-first-review-portable:\(portableKey)"],
                exchangeCount: 0,
                goalID: nil,
                exchanges: [],
                sourceIdentities: [
                    CloudKitSourceIdentityPayload(
                        sourceID: foreignSourceID,
                        url: normalizedURL,
                        normalizedURL: normalizedURL,
                        doi: nil,
                        publishedDOI: nil
                    ),
                ]
            )
        )

        let persisted = try #require(try knowledge.loadReviewSessionForSync(operation.sessionID))
        #expect(persisted.sourceIDs == [localSourceID])
        #expect(persisted.cardIDs == ["new-first-review-portable:\(portableKey)"])

        let replay = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "portable-first-review-retry"
            )
        )
        #expect(replay["session_id"] as? String == operation.sessionID)
        let firstReviews = try #require(replay["new_items"] as? [[String: Any]])
        #expect(firstReviews.compactMap { $0["source_id"] as? String } == [localSourceID])
    }

    @Test("memory review completion marks only the source actually attempted")
    func memoryReviewStopAfterOneLeavesUntouchedQueueSourcesEligible() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-45 * 86_400)

        for index in 1...2 {
            let sourceID = "partial-memory-source-\(index)"
            let itemID = "partial-memory-item-\(index)"
            let content = "Canonical concept \(index) must remain independently eligible until it is actually attempted."
            try insertSource(
                dbPath: dbPath,
                id: sourceID,
                title: "Partial memory \(index)",
                content: content
            )
            try knowledge.saveMemoryItem(
                MemoryItem(
                    id: itemID,
                    kind: .concept,
                    target: "Explain canonical concept \(index)",
                    rubricJSON: #"{"criteria":["Explains the concept"]}"#,
                    sources: [
                        MemoryItemSource(
                            id: "partial-memory-anchor-\(index)",
                            memoryItemID: itemID,
                            sourceID: sourceID,
                            excerpt: content,
                            sourceSHA256: PaperContentPreparationService.sha256(content),
                            sortIndex: 0
                        ),
                    ],
                    createdAt: old,
                    updatedAt: old
                )
            )
            _ = try knowledge.recordMemoryAttempt(
                MemoryAttempt(
                    id: "partial-memory-old-attempt-\(index)",
                    memoryItemID: itemID,
                    attemptType: .review,
                    prompt: "Explain concept \(index).",
                    learnerAnswer: "An old answer.",
                    feedback: "Needs a refresh.",
                    score: 0.5,
                    scheduleRating: .hard,
                    gradeState: .graded,
                    attemptedAt: old.addingTimeInterval(Double(index))
                )
            )
        }

        let start = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 2,
                startSession: true,
                operationID: "partial-memory-operation"
            )
        )
        let sessionID = try #require(start["session_id"] as? String)
        let queued = try #require(start["memory_items"] as? [[String: Any]])
        #expect(queued.count == 2)
        let attemptedID = try #require(queued.first?["item_id"] as? String)
        let untouchedID = attemptedID == "partial-memory-item-1"
            ? "partial-memory-item-2"
            : "partial-memory-item-1"
        let attemptedSourceID = attemptedID.replacingOccurrences(
            of: "partial-memory-item-",
            with: "partial-memory-source-"
        )
        let untouchedSourceID = untouchedID.replacingOccurrences(
            of: "partial-memory-item-",
            with: "partial-memory-source-"
        )
        let memoryAttempts: [[String: Any]] = [[
            "item_id": attemptedID,
            "prompt": "Explain this concept without looking back.",
            "learner_answer": "I can now explain the mechanism independently.",
            "evaluation": "Correct and independent.",
            "score": 0.95,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
        ]]
        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.95,
            summary: "Stopped after one of two queued concepts.",
            transcript: "Tutor: Explain one concept.\nLearner: I can explain it independently.",
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(attemptedSourceID)' AND completed_at IS NOT NULL"
        ) == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(untouchedSourceID)' AND completed_at IS NOT NULL"
        ) == 0)
        let next = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 2, startSession: false)
        )
        let nextIDs = (next["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String } ?? []
        #expect(nextIDs.contains(untouchedID))
    }

    @Test("memoryReview cannot consume legacy state without graded concept evidence")
    func memoryReviewRejectsEmptyEvidenceCompletion() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-40 * 86_400)
        let content = "Legacy retrieval history must not be consumed without a concept attempt."
        try insertSource(
            dbPath: dbPath,
            id: "empty-evidence-source",
            title: "Empty evidence guard",
            content: content
        )
        try knowledge.createReviewSession(
            id: "empty-evidence-legacy",
            topic: "Old review",
            sourceIDs: ["empty-evidence-source"],
            startedAt: old
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "empty-evidence-legacy",
            question: "What was the mechanism?",
            answer: "I do not remember.",
            evaluation: "Needs retrieval.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["empty-evidence-source"],
            answeredAt: old
        )
        try knowledge.completeReviewSession(
            sessionID: "empty-evidence-legacy",
            overallScore: 0.2,
            summary: "Weak recall.",
            endedAt: old
        )
        let plannedAt = Date().timeIntervalSinceReferenceDate
        try execSQL(dbPath: dbPath, """
            INSERT INTO scheduled_sources
                (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES
                ('empty-evidence-schedule', 'empty-evidence-source', \(plannedAt), \(plannedAt), NULL, \(plannedAt), \(plannedAt));
        """)

        let plan = try parseJSON(
            try await store.memoryReview(
                goalID: nil,
                limit: 1,
                startSession: true,
                operationID: "empty-evidence-start"
            )
        )
        let sessionID = try #require(plan["session_id"] as? String)

        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0.5,
                summary: "A review allegedly happened.",
                transcript: "Tutor: Explain it.\nLearner: I am unsure."
            )
            Issue.record("Expected memory completion without memory_attempts to fail")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("structured memory_attempts"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE id = 'empty-evidence-schedule' AND completed_at IS NULL"
        ) == 1)

        // A launched memory queue is durable resume state even before its first
        // grade. Refuse completion rather than deleting that queue or consuming
        // review state without evidence.
        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0,
                summary: "Canceled before review."
            )
            Issue.record("Expected a durable memory queue without evidence to remain open")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("no structured memory_attempts"))
        }
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE id = 'empty-evidence-schedule' AND completed_at IS NULL"
        ) == 1)

        do {
            _ = try store.endReviewSession(
                sessionID: "mcp-memory-review-missing",
                overallScore: 0.5,
                summary: "Late transcript retry.",
                transcript: "Tutor: Explain it.\nLearner: I am unsure.",
                sourceIDs: ["empty-evidence-source"]
            )
            Issue.record("Expected a missing memory-review identity to fail closed")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("will not import its transcript"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == 1)
    }

    @Test("failed-only memory evidence cannot consume review or Schedule state")
    func memoryReviewRejectsFailedOnlyEvidenceCompletion() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("knowledge.db").path
        let knowledge = try store.knowledgeStore()
        let sourceID = "failed-only-memory-source"
        let itemID = "failed-only-memory-item"
        let sessionID = "mcp-memory-review-failed-only"
        let content = "A grader failure is durable evidence, but it is not a successful review."
        try insertSource(
            dbPath: dbPath,
            id: sourceID,
            title: "Failed-only memory evidence",
            content: content
        )
        try knowledge.saveMemoryItem(MemoryItem(
            id: itemID,
            kind: .concept,
            target: "Explain why failed grading must not advance review state",
            rubricJSON: #"{"criteria":["Separates durable failure evidence from a grade"]}"#,
            sources: [
                MemoryItemSource(
                    id: "failed-only-memory-anchor",
                    memoryItemID: itemID,
                    sourceID: sourceID,
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ]
        ))
        try knowledge.createReviewSession(
            id: sessionID,
            topic: "Failed-only memory review",
            sourceIDs: [sourceID]
        )
        _ = try knowledge.recordMemoryAttemptCreatingReviewExchange(
            sessionID: sessionID,
            sourceRefs: [sourceID],
            attempt: MemoryAttempt(
                id: "failed-only-memory-attempt",
                memoryItemID: itemID,
                prompt: "Why should a grader failure leave this concept due?",
                learnerAnswer: "Because the app has no trustworthy grade.",
                gradeState: .failed,
                gradingError: "The configured grading model failed.",
                attemptedAt: Date()
            )
        )

        do {
            _ = try store.endReviewSession(
                sessionID: sessionID,
                overallScore: 0,
                summary: "Grading failed."
            )
            Issue.record("Expected failed-only memory evidence to leave the review open")
        } catch let error as MCPError {
            #expect(String(describing: error).contains("recorded learner conversation"))
        }

        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT status FROM review_sessions WHERE id = '\(sessionID)'"
        ) == "active")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = '\(sourceID)'"
        ) == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM memory_attempts WHERE id = 'failed-only-memory-attempt' AND grade_state = 'failed'"
        ) == 1)
    }

    @Test("Concurrent memory review and completion mutations serialize one shared connection")
    func concurrentMemoryReviewAndCompletionMutationsSerialize() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval must happen before feedback to expose accessible knowledge."
        try insertSource(
            dbPath: dbPath,
            id: "concurrent-source",
            title: "Concurrent retrieval",
            content: content
        )
        let knowledge = try store.knowledgeStore()
        let now = Date()
        try knowledge.saveMemoryItem(
            MemoryItem(
                id: "concurrent-memory-item",
                kind: .concept,
                target: "Explain retrieval before feedback.",
                rubricJSON: #"{"criteria":["Explains diagnostic effort"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "concurrent-anchor",
                        memoryItemID: "concurrent-memory-item",
                        sourceID: "concurrent-source",
                        excerpt: content,
                        sourceSHA256: PaperContentPreparationService.sha256(content),
                        sortIndex: 0
                    )
                ],
                createdAt: now.addingTimeInterval(-10 * 86_400),
                updatedAt: now.addingTimeInterval(-10 * 86_400)
            )
        )
        // Reviewed once and due again, so every memory_review starts a session:
        // a never-reviewed item is new and never due.
        _ = try knowledge.recordMemoryAttempt(
            MemoryAttempt(
                id: "concurrent-memory-attempt",
                memoryItemID: "concurrent-memory-item",
                attemptType: .review,
                prompt: "Why retrieve before feedback?",
                learnerAnswer: "It shows what I can reach.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: now.addingTimeInterval(-9 * 86_400)
            )
        )

        let operationCount = 8
        for index in 0..<operationCount {
            try knowledge.createReviewSession(
                id: "concurrent-end-\(index)",
                topic: "Concurrent completion \(index)",
                sourceIDs: ["concurrent-source"],
                startedAt: now.addingTimeInterval(Double(index))
            )
        }

        // Widen the transaction overlap enough that the pre-gate implementation
        // deterministically issued nested BEGIN/ROLLBACK calls on the one cached
        // connection. With whole-tool mutation serialization, every call succeeds.
        try knowledge.exec("""
            CREATE TRIGGER slow_concurrent_session_insert
            BEFORE INSERT ON review_sessions
            BEGIN
                SELECT sum(value) FROM (
                    WITH RECURSIVE numbers(value) AS (
                        VALUES(0)
                        UNION ALL
                        SELECT value + 1 FROM numbers WHERE value < 30000
                    )
                    SELECT value FROM numbers
                );
            END
        """)
        try knowledge.exec("""
            CREATE TRIGGER slow_concurrent_session_complete
            BEFORE UPDATE OF status ON review_sessions
            WHEN NEW.status = 'completed'
            BEGIN
                SELECT sum(value) FROM (
                    WITH RECURSIVE numbers(value) AS (
                        VALUES(0)
                        UNION ALL
                        SELECT value + 1 FROM numbers WHERE value < 30000
                    )
                    SELECT value FROM numbers
                );
            END
        """)

        let registry = MCPToolRegistry(store: store)
        let successes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<operationCount {
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "memory_review",
                        arguments: ["limit": 1, "start_session": true],
                        access: .internalFullAccess
                    )
                    return !outcome.isError && !outcome.text.contains("transaction within a transaction")
                }
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "end_review_session",
                        arguments: [
                            "session_id": "concurrent-end-\(index)",
                            "overall_score": 0.8,
                            "summary": "Concurrent review completed.",
                            "transcript": "Tutor: Explain retrieval.\nLearner: Recall before feedback.",
                        ],
                        access: .internalFullAccess
                    )
                    return !outcome.isError && !outcome.text.contains("transaction within a transaction")
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(successes.count == operationCount * 2)
        #expect(successes.allSatisfy { $0 })
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE id LIKE 'concurrent-end-%' AND status = 'completed'"
        ) == operationCount)
    }

    @Test("Read-only tools share the store gate; a writer holds it alone, in arrival order")
    func storeGateSharesReadsAndSerializesWrites() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // Two readers hold the gate together.
        await store.acquireToolOperation(.shared)
        let secondReader = MCPTestSignal()
        let secondReaderTask = Task {
            await store.acquireToolOperation(.shared)
            await secondReader.signal()
        }
        await secondReaderTask.value
        #expect(await secondReader.hasSignaled)

        // A writer waits for both readers to leave...
        let writerAdmitted = MCPTestSignal()
        let writerReleased = MCPTestSignal()
        let writerTask = Task {
            await store.acquireToolOperation(.exclusive)
            await writerAdmitted.signal()
            await writerReleased.wait()
            await store.releaseToolOperation()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await writerAdmitted.hasSignaled))
        await store.releaseToolOperation()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await writerAdmitted.hasSignaled))

        // ...and a reader that arrives behind the queued writer waits for it,
        // so a stream of reads cannot starve a write.
        let lateReaderAdmitted = MCPTestSignal()
        let lateReaderTask = Task {
            await store.acquireToolOperation(.shared)
            await lateReaderAdmitted.signal()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await lateReaderAdmitted.hasSignaled))

        await store.releaseToolOperation()
        await writerAdmitted.wait()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await lateReaderAdmitted.hasSignaled))

        await writerReleased.signal()
        await writerTask.value
        await lateReaderTask.value
        #expect(await lateReaderAdmitted.hasSignaled)
        await store.releaseToolOperation()
    }

    @Test("A read-only tool runs while another reader holds the gate")
    func readOnlyToolDoesNotWaitForOtherReaders() async throws {
        // Until 2026-09-18 every tool held the gate alone, so a list_courses
        // queued behind whatever read happened to be running. A read cannot
        // leave uncommitted rows for another read to see, so it shares.
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let registry = MCPToolRegistry(store: store)

        await store.acquireToolOperation(.shared)
        let outcome = await registry.callToolDetailed(
            name: "list_courses",
            arguments: [:],
            access: .internalFullAccess
        )
        #expect(!outcome.isError)
        await store.releaseToolOperation()
    }

    @Test("Publishing tools share the gate; tools that write the cached connection hold it alone")
    func storeGateModeFollowsWhatAToolDoesToTheConnection() {
        #expect(MCPToolRegistry.storeGateMode(for: "list_teams") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "list_docs") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "read_site_file") == .shared)
        // A publish spends its time uploading and records the result through
        // the storage actor's own connection; a list_teams waited half a minute
        // behind one on 2026-09-18.
        #expect(MCPToolRegistry.storeGateMode(for: "publish_doc") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "unpublish_doc") == .shared)
        #expect(MCPToolRegistry.storeGateMode(for: "create_notebook") == .exclusive)
        #expect(MCPToolRegistry.storeGateMode(for: "end_review_session") == .exclusive)
        #expect(MCPToolRegistry.storeGateMode(for: "delete_source") == .exclusive)
        let registered = Set(MCPToolRegistry.shared.tools.map(\.name))
        for name in MCPToolRegistry.sharedGateWritingToolNames.union(MCPToolRegistry.selfGatedToolNames) {
            #expect(registered.contains(name), "\(name) is not a registered tool")
        }
        // A tool is held by the dispatcher, exempt, or gated by itself: never two.
        #expect(MCPToolRegistry.selfGatedToolNames.isDisjoint(with: MCPToolRegistry.storeGateExemptToolNames))
        #expect(MCPToolRegistry.selfGatedToolNames.isDisjoint(with: MCPToolRegistry.sharedGateWritingToolNames))
        #expect(MCPToolRegistry.sharedGateWritingToolNames.isDisjoint(with: MCPToolRegistry.storeGateExemptToolNames))
    }

    /// On 2026-09-27 generate_course_quizzes held the gate alone for minutes of
    /// model calls, and an assistant could neither read a transcript nor save a
    /// quiz until it finished. Every paid tool is now off the dispatcher's gate
    /// except these, each of which writes back a whole row it read before its
    /// wait. Moving one off, or adding a paid tool, means checking what it does
    /// to the cached connection first.
    @Test("The long paid tools hold the store gate only around their own reads and writes")
    func paidToolsHoldTheGateOnlyAroundTheirStoreWork() {
        let offTheDispatcherGate = MCPToolRegistry.storeGateExemptToolNames
            .union(MCPToolRegistry.selfGatedToolNames)
            .union(MCPToolRegistry.settingsParityToolNames)
        #expect(MCPToolRegistry.paidWorkToolNames.subtracting(offTheDispatcherGate) == [
            "generate_source_audio", "import_teachable_course", "ingest_lecture_papers",
            "scan_meeting_for_mentioned_papers", "scan_article_for_linked_sources",
            "extract_paper_metadata", "extract_article_metadata",
            "import_paper_from_url", "import_connector_paper", "import_video_cited_paper",
            "make_article_reading_view",
        ])
        for name in [
            "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video", "close_day",
            "inspect_paper_figure", "generate_image",
        ] {
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name), "\(name) should never touch the cached connection")
        }
        for name in [
            "generate_course", "add_course_quiz_pictures", "add_textbook_to_course", "generate_explainer",
            "transcribe_meeting_recording", "fetch_video_transcript", "scan_video_for_cited_papers",
            "find_lecture_papers", "download_papers_needing_attention", "recheck_paywalled_papers",
            "import_local_pdf_as_paper", "import_local_file",
        ] {
            #expect(MCPToolRegistry.selfGatedToolNames.contains(name), "\(name) should gate only its own store stretches")
        }
    }

    @Test("Bulk quiz work is source-only until drawings are cost-confirmed")
    func bulkQuizPicturesDefaultToSourcePictures() throws {
        for (name, drawKey) in [
            ("add_course_quiz_pictures", "draw"),
            ("generate_course_quizzes", "draw_pictures"),
        ] {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name })
            let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
            let draw = try #require(properties[drawKey] as? [String: Any])
            let confirmation = try #require(properties["confirm_drawings"] as? [String: Any])

            #expect((draw["description"] as? String)?.contains("default false") == true)
            #expect((confirmation["description"] as? String)?.contains("explicitly agreed") == true)
            #expect(tool.description.contains("published maximum cost"))
            #expect(properties["approved_spend_usd"] != nil)
        }
    }

    @Test("A store stretch nested in a hold runs under it, and a read-only hold refuses a write")
    func storeGateStretchesNestUnderTheirHold() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // Inside a stretch held alone, a nested read or write runs at once
        // instead of queuing behind the stretch that holds the gate.
        let nested = try await store.withStoreGate(.exclusive) {
            try await store.withStoreGate(.shared) {
                try await store.withStoreGate(.exclusive) { 42 }
            }
        }
        #expect(nested == 42)

        // A reader that asks to write would wait on itself, so it is refused.
        await #expect(throws: MCPError.self) {
            try await store.withStoreGate(.shared) {
                try await store.withStoreGate(.exclusive) { 0 }
            }
        }

        // A task spawned inside a stretch inherits its hold; once the stretch
        // has ended, the task takes the gate itself rather than borrowing it.
        let stretchEnded = MCPTestSignal()
        let spawnedRan = MCPTestSignal()
        var spawned: Task<Bool, Never>?
        try await store.withStoreGate(.exclusive) {
            spawned = Task {
                await stretchEnded.wait()
                let ran = (try? await store.withStoreGate(.exclusive) { true }) ?? false
                await spawnedRan.signal()
                return ran
            }
        }
        // Both stretches released the gate, so a writer is admitted at once.
        await store.acquireToolOperation(.exclusive)
        await stretchEnded.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await spawnedRan.hasSignaled), "the spawned stretch ran on a hold that had ended")
        await store.releaseToolOperation()
        #expect(await spawned?.value == true)
    }

    @Test("A read and a quiz save both answer while a long paid writer waits on its model")
    func readsAndWritesRunBesideALongPaidWriter() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir.path) }
        let writerEntered = MCPTestSignal()
        let releaseWriter = MCPTestSignal()
        let store = MCPDataStore(
            dbPath: tmpDir.appendingPathComponent("knowledge.db").path,
            explainerBackend: HeldMCPExplainerBackend(
                entered: writerEntered,
                release: releaseWriter,
                draft: ExplainerDraft(title: "Why mitochondria matter", script: "They make the energy.\n\nAnd more.")
            )
        )
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore, id: "mito-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article,
            content: "The full text of the article, long enough for a writer to work with."
        )
        let learningPoint = "The proton circuit couples respiration to ATP synthesis through the membrane potential."
        try kstore.saveCourseGroup(name: "bioenergetics", metadata: CourseMetadata(title: "Bioenergetics"))
        let lecture = CourseSession(courseName: "bioenergetics", number: 1, title: "Proton circuits")
        try kstore.saveCourseLecture(lecture)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Proton circuits",
            sourceType: .video, discoveryOrigin: .manual, id: "video-one"
        )
        video.content = "[0:00] \(learningPoint)"
        video.state = .ready
        try kstore.saveSource(video)
        _ = try kstore.saveCourseLectureItem(CourseLectureItem(lectureId: lecture.id, sourceId: video.id, role: .video, sortIndex: 0))
        let videoID = video.id
        let registry = MCPToolRegistry(store: store)

        // The paid writer: the explainer waits in its model call until released.
        let writerDone = MCPTestSignal()
        let writer = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(
                name: "generate_explainer",
                arguments: ["source_id": "mito-1", "length": "brief", "generate_audio": false]
            )
            await writerDone.signal()
            return outcome
        }
        for _ in 0..<500 {
            if await writerEntered.hasSignaled { break }
            if await writerDone.hasSignaled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await writerEntered.hasSignaled else {
            await releaseWriter.signal()
            let early = await writer.value
            Issue.record("generate_explainer never reached its model call: \(early.text)")
            return
        }

        // The two calls the assistant could not make on 2026-09-27: reading a
        // transcript, and saving a quiz, which writes the cached connection.
        let readDone = MCPTestSignal()
        let read = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(name: "get_source_content", arguments: ["source_id": videoID])
            await readDone.signal()
            return outcome
        }
        let saveDone = MCPTestSignal()
        let save = Task { () -> MCPToolRegistry.ToolCallOutcome in
            let outcome = await registry.callToolDetailed(name: "save_course_quiz", arguments: [
                "course_id": "bioenergetics",
                "learning_points": [learningPoint],
                "kind": "practice",
                "title": "Proton circuits",
                "lecture_ids": [lecture.id],
                "questions": [[
                    "question": "What couples respiration to ATP synthesis?",
                    "answer": "The membrane potential.",
                    "key_points": ["membrane potential"],
                    "points": [1],
                    "source_id": videoID,
                    "quote": "couples respiration to ATP synthesis through the membrane potential",
                ] as [String: Any]],
            ])
            await saveDone.signal()
            return outcome
        }
        // Behind a writer holding the gate for its whole run, neither would
        // answer before the writer is released below.
        var answeredWhileWriterWaited = false
        for _ in 0..<500 {
            if await readDone.hasSignaled, await saveDone.hasSignaled {
                answeredWhileWriterWaited = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let writerFinishedFirst = await writerDone.hasSignaled
        await releaseWriter.signal()
        let readOutcome = await read.value
        let saveOutcome = await save.value
        let writerOutcome = await writer.value

        #expect(answeredWhileWriterWaited, "a read and a write queued behind the paid writer")
        #expect(!writerFinishedFirst)
        #expect(!readOutcome.isError, "\(readOutcome.text)")
        #expect(readOutcome.text.contains("proton circuit"))
        #expect(!saveOutcome.isError, "\(saveOutcome.text)")
        #expect(try kstore.loadCourseQuizzes(courseID: "bioenergetics").count == 1)
        #expect(!writerOutcome.isError, "\(writerOutcome.text)")
        #expect(try kstore.loadSourceForSync(GeneratedExplainer.sourceID(explaining: "mito-1")) != nil)
    }

    @Test("Cached-store reads wait for atomic review completion")
    func cachedStoreReadWaitsForAtomicReviewCompletion() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let now = Date()
        let notebook = try knowledge.createCompanionGoal(
            title: "Isolation notebook",
            topic: "transaction isolation",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Isolation goal",
            topic: "transaction isolation",
            startAt: now,
            endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )
        let sessionID = "read-isolation-session"
        try knowledge.createReviewSession(
            id: sessionID,
            topic: "Read isolation",
            sourceIDs: [],
            startedAt: now,
            goalID: goal.id
        )
        let gapSummary = "Distinguish committed state from an in-flight review."
        let gap = LearningGoalGap(
            id: "read-isolation-gap",
            goalID: goal.id,
            summary: gapSummary,
            sourceID: nil,
            status: "open",
            severity: 0.5,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: nil,
            sessionID: sessionID
        )
        let registry = MCPToolRegistry(store: store)

        // Hold the same operation boundary that end_review_session owns, then
        // start a declared read which uses the cached KnowledgeStore connection.
        // It must remain queued until the complete SQLite transaction commits.
        await store.acquireToolOperation()
        let readStarted = MCPTestSignal()
        let readFinished = MCPTestSignal()
        let readTask = Task {
            await readStarted.signal()
            let outcome = await registry.callToolDetailed(
                name: "get_goal",
                arguments: ["goal_id": goal.id],
                access: .internalFullAccess
            )
            await readFinished.signal()
            return outcome
        }
        await readStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        let readFinishedBeforeCommit = await readFinished.hasSignaled
        #expect(!readFinishedBeforeCommit)

        do {
            try knowledge.completeReviewSessionAndRecordMemoryAttempts(
                sessionID: sessionID,
                overallScore: 0.8,
                summary: "Atomic completion committed.",
                endedAt: now.addingTimeInterval(60),
                sessionSourceIDs: [],
                companionGoalID: goal.id,
                companionQuizDate: "2026-08-10",
                companionGaps: [gap],
                attempts: []
            )
        } catch {
            await store.releaseToolOperation()
            throw error
        }
        await store.releaseToolOperation()

        let outcome = await readTask.value
        #expect(!outcome.isError)
        #expect(outcome.text.contains(gapSummary))
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.status == "completed")
    }

    @Test("endReviewSession atomically links MCP memory attempts to exact exchanges")
    func endReviewSessionLinksMemoryAttempts() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "A retrieval cue must be answered before feedback strengthens the trace."
        try insertSource(dbPath: dbPath, id: "source-memory", title: "Memory", content: content)
        try insertSource(
            dbPath: dbPath,
            id: "source-memory-untouched",
            title: "Untouched memory source",
            content: "This source is attached to the session but never attempted."
        )
        let item = MemoryItem(
            id: "memory-item",
            kind: .concept,
            target: "Explain retrieval-before-feedback",
            rubricJSON: #"{"criteria":["Explains effortful retrieval"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor",
                    memoryItemID: "memory-item",
                    sourceID: "source-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ]
        )
        try store.knowledgeStore().saveMemoryItem(item)
        let id = "memory-review-linkage"
        try store.knowledgeStore().createReviewSession(
            id: id,
            topic: "Memory review",
            sourceIDs: ["source-memory", "source-memory-untouched"],
            cardIDs: [store.mcpMemoryItemCardID(item)]
        )

        let transcript = "Tutor: Why retrieve first?\nLearner: Effort exposes what I can actually access."
        let memoryAttempts: [[String: Any]] = [[
            "item_id": "memory-item",
            "prompt": "Why retrieve before seeing feedback?",
            "learner_answer": "Effort exposes what I can actually access.",
            "evaluation": "Correct; retrieval diagnoses and strengthens access.",
            "score": 0.8,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
        ]]
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.8,
            summary: "Understood retrieval before feedback.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        let exchangeID = try scalarString(
            dbPath: dbPath,
            "SELECT exchange_id FROM memory_attempts WHERE memory_item_id = 'memory-item'"
        )
        #expect(exchangeID != nil)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT question FROM review_exchanges WHERE id = '\(exchangeID ?? "")'"
        ) == "Why retrieve before seeing feedback?")
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT user_answer FROM review_exchanges WHERE id = '\(exchangeID ?? "")'"
        ) == "Effort exposes what I can actually access.")
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "completed")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-memory' AND completed_at IS NOT NULL"
        ) == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-memory-untouched'"
        ) == 0)

        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'")
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = 'memory-item'"
        )

        // Simulate the client losing the successful response and replaying the
        // exact end call. Durable history and scheduler state remain unchanged.
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.8,
            summary: "Understood retrieval before feedback.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = 'memory-item'"
        ) == schedule)
    }

    @Test("memoryReview never reintroduces a source anchored by a future active item")
    func memoryReviewExcludesAllActiveAnchors() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "An active concept already represents this source even when its next review is tomorrow."
        try insertSource(
            dbPath: dbPath,
            id: "source-future-memory",
            title: "Future concept",
            content: content
        )
        let knowledge = try store.knowledgeStore()
        let old = Date().addingTimeInterval(-90 * 86_400)
        try knowledge.createReviewSession(
            id: "legacy-review",
            topic: "Legacy source review",
            sourceIDs: ["source-future-memory"],
            startedAt: old
        )
        _ = try knowledge.addReviewExchange(
            sessionID: "legacy-review",
            question: "What did this source argue?",
            answer: "I barely remember.",
            evaluation: "Needs review.",
            score: 0.2,
            knowledgeNote: nil,
            sourceRefs: ["source-future-memory"],
            answeredAt: old
        )
        try knowledge.completeReviewSession(
            sessionID: "legacy-review",
            overallScore: 0.2,
            summary: "Weak legacy review.",
            endedAt: old
        )
        let future = Date().addingTimeInterval(86_400)
        let item = MemoryItem(
            id: "future-memory-item",
            kind: .concept,
            target: "Explain the represented concept",
            rubricJSON: #"{"criteria":["Explains the concept"]}"#,
            sources: [
                MemoryItemSource(
                    id: "future-memory-anchor",
                    memoryItemID: "future-memory-item",
                    sourceID: "source-future-memory",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: future,
            updatedAt: future
        )
        try knowledge.saveMemoryItem(item)

        let output = try await store.memoryReview(
            goalID: nil,
            limit: 5,
            startSession: false
        )
        let payload = try parseJSON(output)

        #expect((payload["memory_items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["new_items"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("memoryReview excludes an item whose source has not arrived in the library")
    func memoryReviewExcludesDanglingMemoryAnchors() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let content = "An out-of-order memory anchor is not proof that canonical source text exists."
        let item = MemoryItem(
            id: "dangling-memory-item",
            kind: .concept,
            target: "Explain why source availability is authoritative",
            rubricJSON: #"{"criteria":["Requires a persisted library source"]}"#,
            sources: [
                MemoryItemSource(
                    id: "dangling-memory-anchor",
                    memoryItemID: "dangling-memory-item",
                    sourceID: "source-not-delivered-yet",
                    excerpt: content,
                    sourceSHA256: PaperContentPreparationService.sha256(content),
                    sortIndex: 0
                ),
            ],
            createdAt: old,
            updatedAt: old
        )
        try store.knowledgeStore().saveMemoryItem(item)
        // Reviewed and due again: only the missing source keeps it out.
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "dangling-memory-attempt",
                memoryItemID: item.id,
                attemptType: .review,
                prompt: "Why must the source exist?",
                learnerAnswer: "The text is what grounds the question.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(60)
            )
        )

        let payload = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 5, startSession: false)
        )
        #expect((payload["memory_items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["items"] as? [[String: Any]])?.isEmpty == true)
        #expect((payload["new_items"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test("memoryReview keeps a multi-anchor item when one of its sources is hidden; hiding is visual only")
    func memoryReviewKeepsPartiallyHiddenMemoryItems() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let visible = "Visible canonical evidence for a relationship."
        let hidden = "Hidden canonical evidence for the same relationship."
        try insertSource(
            dbPath: dbPath,
            id: "visible-anchor-source",
            title: "Visible anchor",
            content: visible
        )
        try insertSource(
            dbPath: dbPath,
            id: "hidden-anchor-source",
            title: "Hidden anchor",
            content: hidden
        )
        try execSQL(
            dbPath: dbPath,
            "INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('hidden-anchor-source', 1)"
        )
        let old = Date().addingTimeInterval(-30 * 86_400)
        try store.knowledgeStore().saveMemoryItem(
            MemoryItem(
                id: "partially-hidden-memory-item",
                kind: .relationship,
                target: "Relate the visible and hidden evidence",
                rubricJSON: #"{"criteria":["Uses both sources"]}"#,
                sources: [
                    MemoryItemSource(
                        id: "visible-memory-anchor",
                        memoryItemID: "partially-hidden-memory-item",
                        sourceID: "visible-anchor-source",
                        excerpt: visible,
                        sourceSHA256: PaperContentPreparationService.sha256(visible),
                        sortIndex: 0
                    ),
                    MemoryItemSource(
                        id: "hidden-memory-anchor",
                        memoryItemID: "partially-hidden-memory-item",
                        sourceID: "hidden-anchor-source",
                        excerpt: hidden,
                        sourceSHA256: PaperContentPreparationService.sha256(hidden),
                        sortIndex: 1
                    ),
                ],
                createdAt: old,
                updatedAt: old
            )
        )
        _ = try store.knowledgeStore().recordMemoryAttempt(
            MemoryAttempt(
                id: "partially-hidden-memory-attempt",
                memoryItemID: "partially-hidden-memory-item",
                attemptType: .review,
                prompt: "How does the visible evidence bear on the hidden evidence?",
                learnerAnswer: "They describe one relationship from two sides.",
                feedback: "Good.",
                score: 0.8,
                scheduleRating: .good,
                gradeState: .graded,
                attemptedAt: old.addingTimeInterval(60)
            )
        )

        let payload = try parseJSON(
            try await store.memoryReview(goalID: nil, limit: 5, startSession: false)
        )
        // Hiding takes a source off the sources list and nowhere else
        // (product owner, 2026-09-11), so the item anchored on it is still due.
        let itemIDs = (payload["memory_items"] as? [[String: Any]])?
            .compactMap { $0["item_id"] as? String } ?? []
        #expect(itemIDs == ["partially-hidden-memory-item"])
    }

    @Test("endReviewSession turns a grounded first review into one durable memory trace across retries")
    func endReviewSessionCreatesFirstReviewMemoryTraceIdempotently() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval before feedback reveals what the learner can access and gives correction a specific error to update."
        try insertSource(
            dbPath: dbPath,
            id: "source-first-review",
            title: "Retrieval before feedback",
            content: content
        )
        let started = try await store.startReviewSession(
            topic: "First memory review",
            sourceID: "source-first-review"
        )
        let id = parsedSessionID(from: started)
        let transcript = "Tutor: Why retrieve before feedback?\nLearner: It exposes the gap that feedback should correct."
        let memoryAttempts: [[String: Any]] = [[
            "source_id": "source-first-review",
            "semantic_target": "Explain why feedback should follow an effortful retrieval attempt",
            "rubric": [
                "Retrieval exposes the learner's current access",
                "Feedback can then update a specific error or omission",
            ],
            "evidence_excerpt": content,
            "prompt": "Why should feedback come after you first try to retrieve the idea?",
            "learner_answer": "It exposes the gap that feedback should correct.",
            "evaluation": "Correct: the attempted retrieval diagnoses access and makes the correction specific.",
            "score": 0.82,
            "retrieval_quality": "independent",
            "missing_rubric_elements": ["Explicitly name current access"],
            "misconception": "Initially described feedback as useful without explaining the retrieval attempt.",
        ]]

        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.82,
            summary: "Connected effortful retrieval to targeted correction.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        let knowledge = try store.knowledgeStore()
        let items = try knowledge.loadMemoryItems()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.id == MemoryTutorIdentity.firstReviewItemID(
            portableSourceKey: try knowledge.portableMemorySourceKey(
                sourceID: "source-first-review"
            )
        ))
        #expect(item.kind == .concept)
        #expect(item.target == "Explain why feedback should follow an effortful retrieval attempt")
        #expect(item.rubricJSON == #"{"criteria":["Retrieval exposes the learner's current access","Feedback can then update a specific error or omission"]}"#)
        #expect(item.learnerContext == "Initially described feedback as useful without explaining the retrieval attempt.")
        #expect(item.sources.count == 1)
        #expect(item.sources.first?.sourceID == "source-first-review")
        #expect(item.sources.first?.excerpt == content)
        #expect(item.sources.first?.sourceSHA256 == PaperContentPreparationService.sha256(content))

        let attempts = try knowledge.loadMemoryAttempts(sessionID: id)
        let attempt = try #require(attempts.first)
        #expect(attempts.count == 1)
        #expect(attempt.id.hasPrefix("mcp-memory-attempt-"))
        #expect(attempt.memoryItemID == item.id)
        #expect(attempt.sessionID == id)
        #expect(attempt.exchangeID != nil)
        #expect(attempt.attemptType == .discovery)
        #expect(attempt.scheduleRating == .good)
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "completed")

        let itemCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items")
        let anchorCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources")
        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'")
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        )

        // The assistant may retry after its successful response was lost. The
        // app owns stable identities, so the identical call is a no-op rather
        // than a second curriculum item or scheduler advancement.
        _ = try store.endReviewSession(
            sessionID: id,
            overallScore: 0.82,
            summary: "Connected effortful retrieval to targeted correction.",
            transcript: transcript,
            memoryAttempts: memoryAttempts
        )

        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == itemCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources") == anchorCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d|%.17g', due_at, stability, repetition_count, lapse_count, difficulty) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        ) == schedule)
    }

    @Test("first-review Socratic retries share one curriculum item and replay exactly")
    func endReviewSessionCoalescesRepeatedFirstReviewAttempts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let content = "Retrieval before feedback reveals accessible knowledge, while the correction updates a specific omission."
        try insertSource(
            dbPath: dbPath,
            id: "repeated-intake-source",
            title: "Repeated intake",
            content: content
        )
        let started = try await store.startReviewSession(
            topic: "Repeated first review",
            sourceID: "repeated-intake-source"
        )
        let sessionID = parsedSessionID(from: started)
        let curriculum: [String: Any] = [
            "source_id": "repeated-intake-source",
            "semantic_target": "Explain why retrieval should precede feedback",
            "rubric": [
                "Retrieval reveals currently accessible knowledge",
                "Feedback updates a specific error or omission",
            ],
            "evidence_excerpt": content,
        ]
        var first = curriculum
        first.merge([
            "prompt": "Why try to retrieve before looking at feedback?",
            "learner_answer": "It makes memory stronger.",
            "evaluation": "That misses the diagnostic role of the attempt.",
            "score": 0.45,
            "retrieval_quality": "hinted",
            "missing_rubric_elements": ["Names currently accessible knowledge"],
            "misconception": "Treated retrieval only as strengthening.",
        ]) { _, new in new }
        var second = curriculum
        second.merge([
            "prompt": "What does the unaided attempt tell feedback to correct?",
            "learner_answer": "It exposes the exact omission, so feedback can update it.",
            "evaluation": "Correct; the retry now connects diagnosis to correction.",
            "score": 0.84,
            "retrieval_quality": "independent",
            "missing_rubric_elements": [] as [String],
            "misconception": "The strengthening-only misconception was corrected.",
        ]) { _, new in new }
        let attempts = [first, second]
        let transcript = "Tutor: Why retrieve first?\nLearner: It strengthens memory.\nTutor: What does it diagnose?\nLearner: The exact omission."

        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.84,
            summary: "Corrected the strengthening-only explanation.",
            transcript: transcript,
            memoryAttempts: attempts
        )
        let knowledge = try store.knowledgeStore()
        let item = try #require(try knowledge.loadMemoryItems().first)
        let storedAttempts = try knowledge.loadMemoryAttempts(sessionID: sessionID)
        #expect(try knowledge.loadMemoryItems().count == 1)
        #expect(storedAttempts.count == 2)
        #expect(Set(storedAttempts.map(\.memoryItemID)) == [item.id])
        #expect(storedAttempts.map(\.attemptType) == [.discovery, .review])
        #expect(item.learnerContext == "Treated retrieval only as strengthening.")

        let itemCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items")
        let attemptCount = try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts")
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'"
        )
        let schedule = try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d', due_at, stability, repetition_count, lapse_count) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        )
        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.84,
            summary: "Corrected the strengthening-only explanation.",
            transcript: transcript,
            memoryAttempts: attempts
        )
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == itemCount)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == attemptCount)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(sessionID)'"
        ) == exchangeCount)
        #expect(try scalarString(
            dbPath: dbPath,
            "SELECT printf('%.17g|%.17g|%d|%d', due_at, stability, repetition_count, lapse_count) FROM memory_schedules WHERE memory_item_id = '\(item.id)'"
        ) == schedule)
    }

    @Test("endReviewSession rejects an ungrounded first review without partial writes")
    func endReviewSessionRejectsUngroundedFirstReview() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-first-review",
            title: "Canonical evidence",
            content: "Canonical text says retrieval should precede corrective feedback."
        )
        let started = try await store.startReviewSession(
            topic: "First memory review",
            sourceID: "source-first-review"
        )
        let id = parsedSessionID(from: started)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: id,
                overallScore: 0.8,
                summary: "This must remain open.",
                transcript: "A review happened, but its evidence was invented.",
                memoryAttempts: [[
                    "source_id": "source-first-review",
                    "semantic_target": "Explain retrieval before feedback",
                    "rubric": ["Names effortful retrieval"],
                    "evidence_excerpt": "This plausible sentence does not occur anywhere in the canonical source.",
                    "prompt": "Why retrieve first?",
                    "learner_answer": "To reveal gaps.",
                    "evaluation": "Mostly correct.",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                ]]
            )
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_items") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_item_sources") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges WHERE session_id = '\(id)'") == 0)
    }

    @Test("endReviewSession leaves the review open when a memory attempt is malformed")
    func endReviewSessionRejectsMalformedMemoryAttempt() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-memory", title: "Memory", content: "Grounded source text.")
        let started = try await store.startReviewSession(topic: "Memory review", sourceID: "source-memory")
        let id = parsedSessionID(from: started)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: id,
                overallScore: 0.8,
                summary: "Should not complete.",
                memoryAttempts: [[
                    "item_id": "invented-item",
                    "prompt": "Question",
                    "learner_answer": "Answer",
                    "evaluation": "Feedback",
                    "score": 0.8,
                    "retrieval_quality": "independent",
                    "missing_rubric_elements": [] as [String],
                ]]
            )
        }
        #expect(try scalarString(dbPath: dbPath, "SELECT status FROM review_sessions WHERE id = '\(id)'") == "active")
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM memory_attempts") == 0)
    }

    @Test("endReviewSession stores exported chat transcript")
    func endReviewSessionStoresTranscript() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "AI for Bio fuzzy API problem drug discovery",
            content: "Drug discovery source content."
        )

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Please quiz me on AI for Bio fuzzy API problem drug discovery")
        let sessionID = started
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .components(separatedBy: "ID: ")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let ended = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.82,
            summary: "Understands the fuzzy API issue and needs more work on assays.",
            transcript: "Claude: What makes the API fuzzy?\nMe: The endpoints are underspecified."
        )
        let transcript = try store.getReviewSessionTranscript(sessionID: sessionID)
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")

        #expect(ended.contains("Transcript exported to ForeverLM"))
        #expect(transcript.contains("Assistant: What makes the API fuzzy?"))
        #expect(transcript.contains("Learner: The endpoints are underspecified."))
        #expect(transcript.contains("Exported from an MCP review."))
        #expect(sessions.contains("1 exchanges"))
    }

    @Test("A session_id argument may be the chat link the app's Copy Link copies")
    func sessionIDArgumentAcceptsChatLink() throws {
        let id = "4B6E2C1A-0F3D-4E2B-9C8A-1D2E3F4A5B6C"
        #expect(MCPDataStore.reviewSessionID(from: id) == id)
        #expect(MCPDataStore.reviewSessionID(from: "  \(id)\n") == id)
        #expect(MCPDataStore.reviewSessionID(from: "foreverlm://chat/\(id)") == id)
        #expect(MCPDataStore.reviewSessionID(from: "\(ForeverLMRuntimeIdentity.urlScheme)://chat/\(id)") == id)
        #expect(MCPDataStore.reviewSessionID(from: "<foreverlm://chat/\(id)>") == id)
        #expect(MCPDataStore.reviewSessionID(from: "[Membrane potential](foreverlm://chat/\(id))") == id)
        // Other addresses are not sessions and pass through untouched, so the
        // not-found error names what was actually sent.
        #expect(MCPDataStore.reviewSessionID(from: "foreverlm://doc/\(id)") == "foreverlm://doc/\(id)")
        #expect(MCPDataStore.reviewSessionID(from: nil) == "")
        #expect(MCPDataStore.reviewSessionID(from: 42) == "")
    }

    @Test("getReviewSessionTranscript reads a chat by its copied link, mid-conversation")
    func transcriptByChatLink() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "source-a", title: "Membrane potential", content: "TMRM content.")

        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(topic: "Measuring mitochondrial membrane potential")
        let sessionID = started
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("Session ID: ") }?
            .components(separatedBy: "ID: ")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(!sessionID.isEmpty)

        // Still active: the link reads the session as it stands, not an export.
        let link = StudioEntityLink.chat(sessionID).markdownDestination
        let live = try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: link))
        #expect(live.contains("Review session: Measuring mitochondrial membrane potential"))
        #expect(live.contains("Status: active"))

        _ = try store.endReviewSession(
            sessionID: MCPDataStore.reviewSessionID(from: link),
            overallScore: 0.9,
            summary: "Knows TMRM in non-quench mode.",
            transcript: "Claude: Which dye?\nMe: TMRM, non-quench."
        )
        let done = try store.getReviewSessionTranscript(sessionID: MCPDataStore.reviewSessionID(from: link))
        #expect(done.contains("Assistant: Which dye?"))
        #expect(done.contains("Learner: TMRM, non-quench."))
    }

    @Test("endReviewSession stores a role-labelled export as separate turns")
    func endReviewSessionStoresRoleLabelledTurns() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-role-turns",
            title: "Mitochondrial sodium",
            content: "Sodium and calcium alter mitochondrial metabolism."
        )
        let store = MCPDataStore(dbPath: dbPath)
        let started = try await store.startReviewSession(
            topic: "Mitochondrial sodium",
            sourceID: "source-role-turns"
        )
        let sessionID = parsedSessionID(from: started)
        let exported = """
        Learner: Please quiz me on this week's reading.
        Assistant: Why can elevated sodium impair mitochondrial metabolism?
        Learner: I am not sure. Please explain it.
        Assistant: It removes calcium from mitochondria. Why can blocking that exchanger help?
        Learner: It keeps calcium-sensitive metabolism active.
        """

        _ = try store.endReviewSession(
            sessionID: sessionID,
            overallScore: 0.7,
            summary: "Reviewed sodium handling.",
            transcript: exported
        )
        let exchanges = try store.knowledgeStore().loadReviewSessionExchanges(sessionID: sessionID)

        #expect(exchanges.count == 3)
        #expect(exchanges[0].question.isEmpty)
        #expect(exchanges[0].userAnswer == "Please quiz me on this week's reading.")
        #expect(exchanges[1].question == "Why can elevated sodium impair mitochondrial metabolism?")
        #expect(exchanges[1].userAnswer == "I am not sure. Please explain it.")
        #expect(exchanges[2].question == "It removes calcium from mitochondria. Why can blocking that exchanger help?")
        #expect(exchanges[2].userAnswer == "It keeps calcium-sensitive metabolism active.")
    }

    @Test("endReviewSession saves the review when the session id is unknown")
    func endReviewSessionSavesWhenSessionUnknown() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path

        try insertSource(
            dbPath: dbPath,
            id: "source-a",
            title: "Mitochondrial energetics and aging",
            content: "Energy budgets and disease."
        )

        let store = MCPDataStore(dbPath: dbPath)
        // A session id that was never created (lost across a long chat, or another window).
        let ended = try store.endReviewSession(
            sessionID: "00000000-DEAD-BEEF-0000-000000000000",
            overallScore: 0.9,
            summary: "Strong on finite-budget logic; weaker on demand overshoot.",
            transcript: "Claude: Why isn't a hard cap enough?\nMe: Because demand can still overshoot it.",
            sourceIDs: ["source-a"],
            topic: "Mitochondrial energetics review"
        )

        // The review is preserved, not discarded, and linked to the source.
        #expect(ended.contains("was not found"))
        #expect(ended.contains("imported review"))
        let sessions = try store.getReviewSessions(topic: nil, sourceId: "source-a")
        #expect(sessions.contains("Mitochondrial energetics review"))
        #expect(sessions.contains("[completed]"))
        let transcript = try store.searchReviewSessions(queryText: "demand can still overshoot", limit: 5)
        #expect(transcript.contains("Mitochondrial energetics review"))
    }

    @Test("missing-session review recovery is idempotent after a lost response")
    func endReviewSessionRecoveryRetryDoesNotDuplicate() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "recovery-source",
            title: "Recovery source",
            content: "A recovered review must remain one durable transcript."
        )
        let arguments = (
            sessionID: "missing-provider-session",
            score: 0.84,
            summary: "Recovered exact review.",
            transcript: "Tutor: Why retrieve before feedback?\nLearner: It exposes what I can access.",
            topic: "Recovery review"
        )

        let first = try store.endReviewSession(
            sessionID: arguments.sessionID,
            overallScore: arguments.score,
            summary: arguments.summary,
            transcript: arguments.transcript,
            sourceIDs: ["recovery-source"],
            topic: arguments.topic
        )
        let sessionCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        )
        let exchangeCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_exchanges"
        )
        let scheduleCount = try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'recovery-source'"
        )

        // Simulate a successful import whose tool response never reached the
        // caller. The exact replay resolves to the same content-addressed
        // recovery session and re-applies only idempotent Schedule completion.
        let second = try store.endReviewSession(
            sessionID: arguments.sessionID,
            overallScore: arguments.score,
            summary: arguments.summary,
            transcript: arguments.transcript,
            sourceIDs: ["recovery-source"],
            topic: arguments.topic
        )

        #expect(second == first)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == sessionCount)
        #expect(sessionCount == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == exchangeCount)
        #expect(exchangeCount == 1)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'recovery-source'"
        ) == scheduleCount)
        #expect(scheduleCount == 1)
    }

    @Test("missing-session recovery rolls back transcript and completion when Schedule fails")
    func endReviewSessionRecoveryRetriesAfterAtomicFailure() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "recovery-rollback-source",
            title: "Recovery rollback",
            content: "A failed Schedule write must not leave a completed transcript behind."
        )
        try execSQL(dbPath: dbPath, """
            CREATE TRIGGER fail_recovery_schedule
            BEFORE INSERT ON scheduled_sources
            BEGIN
                SELECT RAISE(ABORT, 'forced recovery Schedule failure');
            END;
        """)
        do {
            _ = try store.endReviewSession(
                sessionID: "missing-recovery-rollback",
                overallScore: 0.79,
                summary: "Recovered after a transactional failure.",
                transcript: "Tutor: Why atomic?\nLearner: Partial completion would consume review state.",
                sourceIDs: ["recovery-rollback-source"],
                topic: "Recovery rollback"
            )
            Issue.record("Expected the forced Schedule failure")
        } catch {
            #expect(error.localizedDescription.contains("forced recovery Schedule failure"))
        }
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'active'"
        ) == 0)
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions"
        ) == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == 0)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources") == 0)

        try execSQL(dbPath: dbPath, "DROP TRIGGER fail_recovery_schedule")
        _ = try store.endReviewSession(
            sessionID: "missing-recovery-rollback",
            overallScore: 0.79,
            summary: "Recovered after a transactional failure.",
            transcript: "Tutor: Why atomic?\nLearner: Partial completion would consume review state.",
            sourceIDs: ["recovery-rollback-source"],
            topic: "Recovery rollback"
        )
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM review_sessions WHERE status = 'completed'"
        ) == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM review_exchanges") == 1)
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources") == 1)
    }

    @Test("endReviewSession errors clearly when no session id and no transcript")
    func endReviewSessionErrorsWithNothingToSave() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)

        #expect(throws: MCPError.self) {
            _ = try store.endReviewSession(
                sessionID: "unknown-session",
                overallScore: 0.5,
                summary: "No transcript supplied."
            )
        }
    }

    @Test("transcript parser strips orphaned emphasis from bolded role labels")
    func parserStripsBoldRoleLabelEmphasis() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let store = MCPDataStore(dbPath: dbPath)

        // Claude/ChatGPT exports often bold the role label as "**Assistant:** …",
        // which used to leave a leading "** " glued to the message content.
        let turns = store.parseReviewTranscript(
            "**Assistant:** Q1. State the two premises.\n**You:** There is a finite energy budget."
        )

        #expect(turns.count == 1)
        #expect(turns.first?.question == "Q1. State the two premises.")
        #expect(turns.first?.answer == "There is a finite energy budget.")
    }

    @Test("getSchedule returns the active week plan")
    func getScheduleReturnsPlan() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        // The schedule is a continuous calendar whose rendered week is always the
        // live week containing today, so placements must land on current-week days.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Mechanistic Biology", content: "Cells and mechanisms.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Aging Clocks", content: "Biomarkers and methylation.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )
        try insertCompletedReviewSession(dbPath: dbPath, sessionID: "session-a", sourceID: "source-a", endedAt: today.addingTimeInterval(600))

        let store = MCPDataStore(dbPath: dbPath)
        // The `goal` key is only present when the Schedule is scoped to a goal.
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let goal = payload["goal"] as? [String: Any]
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let firstSource = allItems.first { ($0["source_id"] as? String) == "source-a" }
        let secondSource = allItems.first { ($0["source_id"] as? String) == "source-b" }

        #expect(goal?["id"] as? String == "goal-1")
        #expect(days?.count == 7)
        #expect(allItems.count == 2)
        #expect(firstSource?["title"] as? String == "Mechanistic Biology")
        #expect(firstSource?["has_linked_review_session"] as? Bool == true)
        #expect(firstSource?["can_mark_done"] as? Bool == true)
        #expect(secondSource?["has_linked_review_session"] as? Bool == false)
        #expect(secondSource?["can_mark_done"] as? Bool == true)
    }

    @Test("getSchedule recognizes source ids stored on session rows")
    func getScheduleRecognizesSessionSourceIDs() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Session Row Source", content: "Cells and mechanisms.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [(id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil)]
        )
        try execSQL(dbPath: dbPath, """
            INSERT INTO review_sessions (id, topic, started_at, ended_at, status, overall_score, summary, source_ids)
            VALUES ('session-a', 'Review', \(today.timeIntervalSinceReferenceDate), \(today.addingTimeInterval(600).timeIntervalSinceReferenceDate), 'completed', 0.9, 'Reviewed', '["source-a"]');
        """)

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule())
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let source = allItems.first { ($0["source_id"] as? String) == "source-a" }

        #expect(source?["has_linked_review_session"] as? Bool == true)
        #expect(source?["can_mark_done"] as? Bool == true)
    }

    @Test("getSchedule can omit completed items")
    func getScheduleOmitsCompletedItems() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Done Source", content: "Done.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Pending Source", content: "Pending.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: today),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule(includeCompleted: false))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.count == 1)
        #expect(allItems.first?["source_id"] as? String == "source-b")
    }

    @Test("getTodaySources returns content for today's pending sources only")
    func getTodaySourcesReturnsContent() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-today", title: "Today Source", content: "Spaced repetition fundamentals.")
        try insertSource(dbPath: dbPath, id: "source-other", title: "Other Day Source", content: "Tomorrow material.")
        try insertSource(dbPath: dbPath, id: "source-done", title: "Done Source", content: "Already reviewed.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-today", sourceID: "source-today", addedAt: today, completedAt: nil),
                (id: "item-other", sourceID: "source-other", addedAt: otherDay, completedAt: nil),
                (id: "item-done", sourceID: "source-done", addedAt: today, completedAt: today),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources()

        #expect(result.contains("source_id: source-today"))
        #expect(result.contains("Spaced repetition fundamentals."))
        #expect(result.contains("start_review_session"))
        #expect(!result.contains("source_id: source-other"))
        #expect(!result.contains("source_id: source-done"))
    }

    @Test("getTodaySources truncates long content per source")
    func getTodaySourcesTruncatesContent() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        let longContent = String(repeating: "alpha beta gamma ", count: 200)
        try insertSource(dbPath: dbPath, id: "source-long", title: "Long Source", content: longContent)
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [(id: "item-long", sourceID: "source-long", addedAt: today, completedAt: nil)]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources(maxCharsPerSource: 1_000)

        #expect(result.contains("Truncated at 1000 characters"))
        #expect(result.contains("get_source_content with source_id source-long"))
    }

    @Test("getTodaySources loads any Schedule day, including completed sources and past weeks")
    func getTodaySourcesSupportsDateAndPastWeeks() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        let lastWeekDay = calendar.date(byAdding: .day, value: 1, to: lastWeekStart)!

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-other", title: "Other Day Source", content: "Other day content.")
        try insertSource(dbPath: dbPath, id: "source-done", title: "Done Source", content: "Completed source content.")
        try insertSource(dbPath: dbPath, id: "source-lastweek", title: "Last Week Source", content: "Last week content.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-current",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-other", sourceID: "source-other", addedAt: otherDay, completedAt: nil),
                (id: "item-done", sourceID: "source-done", addedAt: today, completedAt: today),
            ]
        )
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-past",
            startAt: lastWeekStart,
            endAt: weekStart,
            items: [(id: "item-lastweek", sourceID: "source-lastweek", addedAt: lastWeekDay, completedAt: lastWeekDay)]
        )

        let store = MCPDataStore(dbPath: dbPath)

        // Another day of the current week, by date.
        let otherResult = try store.getTodaySources(dateString: formatter.string(from: otherDay))
        #expect(otherResult.contains("Other day content."))
        #expect(!otherResult.contains("Completed source content."))

        // Today's completed sources load with include_completed.
        let completedResult = try store.getTodaySources(includeCompleted: true)
        #expect(completedResult.contains("Completed source content."))

        // A day in a past week loads from the continuous calendar directly; the
        // shared-placement model no longer resolves (or names) a per-week goal.
        let lastWeekResult = try store.getTodaySources(
            dateString: formatter.string(from: lastWeekDay),
            includeCompleted: true
        )
        #expect(lastWeekResult.contains("Last week content."))
        #expect(lastWeekResult.contains("source_id: source-lastweek"))
    }

    @Test("getTodaySources can load actual completion activity independently of planned day")
    func getTodaySourcesSupportsCompletionDateBasis() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let weekStart = calendar.date(
            byAdding: .day,
            value: -((calendar.component(.weekday, from: today) + 5) % 7),
            to: today
        )!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-listened",
            title: "Listened Source",
            content: "The source completed by listening."
        )
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-activity",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (
                    id: "item-listened",
                    sourceID: "source-listened",
                    addedAt: tomorrow,
                    completedAt: yesterday.addingTimeInterval(3_600)
                ),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let result = try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "completed"
        )

        #expect(result.contains("Sources completed in ForeverLM"))
        #expect(result.contains("source_id: source-listened"))
        #expect(result.contains("already marked finished"))
    }

    @Test("getTodaySources uses daily activity rather than planned or completed dates")
    func getTodaySourcesSupportsActivityDateBasis() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-chatted",
            title: "Chatted Source",
            content: "The source used in yesterday's chat."
        )
        let store = MCPDataStore(dbPath: dbPath)
        let knowledge = try store.knowledgeStore()
        try knowledge.setScheduledSourcePlannedDate(
            sourceID: "source-chatted",
            plannedAt: tomorrow
        )
        _ = try knowledge.recordScheduledSourceActivity(
            sourceID: "source-chatted",
            on: yesterday.addingTimeInterval(600),
            kind: .chat
        )
        let result = try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "activity",
            activityKind: "chat"
        )

        #expect(result.contains("Sources used for chat in ForeverLM"))
        #expect(result.contains("source_id: source-chatted"))
        #expect(result.contains("yesterday's chat"))
        #expect(try store.getTodaySources(
            dateString: formatter.string(from: yesterday),
            dateBasis: "activity",
            activityKind: "reading"
        ).contains("No reading activity"))
    }

    /// The chat's "quiz me on the podcasts I listened to last week" reads
    /// listening activity by day; an episode played in Apple Podcasts must be
    /// in it on the day it was played, not only ForeverLM's own player's log.
    @Test("getTodaySources lists an episode played in Apple Podcasts as that day's listening")
    func getTodaySourcesListsApplePodcastsListening() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(
            dbPath: dbPath,
            id: "source-played-elsewhere",
            title: "Bioelectric Fields",
            content: "An episode about bioelectric fields in development.",
            sourceType: "podcast",
            discoveryOrigin: "applePodcasts",
            url: "apple-podcast://episode/1000700001"
        )
        let store = MCPDataStore(dbPath: dbPath)
        let recorded = try store.knowledgeStore().recordExternalListening([
            ExternalListen(
                url: "apple-podcast://episode/1000700001",
                title: "Bioelectric Fields",
                showName: "example.com",
                playedAt: fourDaysAgo.addingTimeInterval(14 * 3_600)
            ),
        ])
        #expect(recorded == ["source-played-elsewhere"])

        let result = try store.getTodaySources(
            dateString: formatter.string(from: fourDaysAgo),
            dateBasis: "activity",
            activityKind: "listening"
        )
        #expect(result.contains("Sources used for listening in ForeverLM"))
        #expect(result.contains("source_id: source-played-elsewhere"))
        // Heard, not finished: a play is never a completion.
        #expect(try store.getTodaySources(
            dateString: formatter.string(from: fourDaysAgo),
            dateBasis: "completed"
        ).contains("No sources were completed"))
    }

    @Test("Loading source content for an external chat records today's chat activity")
    func getSourceContentRecordsChatActivityWhenRequested() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "source-chat-activity",
            title: "Chat Activity",
            content: "Loaded into the external assistant."
        )

        _ = try await store.getSourceContent("source-chat-activity", recordChatActivity: true)

        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(*) FROM source_activity_days WHERE source_id = 'source-chat-activity' AND (kinds & 8) != 0"
        ) == 1)
    }

    /// get_source_content shares the store gate as a reader. Until 2026-09-27 it
    /// recorded its chat activity in a transaction on the cached connection, so
    /// an assistant reading sources in parallel could have one read begin its
    /// transaction inside another's and fail.
    @Test("Source reads that record chat activity run together without failing inside each other")
    func parallelSourceReadsRecordTheirActivity() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let count = 8
        for index in 0..<count {
            try insertSource(
                dbPath: dbPath,
                id: "parallel-read-\(index)",
                title: "Parallel read \(index)",
                content: "Loaded beside the other reads."
            )
        }
        let registry = MCPToolRegistry(store: store)

        let failures = await withTaskGroup(of: String?.self) { group in
            for index in 0..<count {
                group.addTask {
                    let outcome = await registry.callToolDetailed(
                        name: "get_source_content",
                        arguments: ["source_id": "parallel-read-\(index)"]
                    )
                    return outcome.isError ? outcome.text : nil
                }
            }
            var failed: [String] = []
            for await failure in group {
                if let failure { failed.append(failure) }
            }
            return failed
        }

        #expect(failures.isEmpty, "\(failures)")
        #expect(try scalarInt(
            dbPath: dbPath,
            "SELECT COUNT(DISTINCT source_id) FROM source_activity_days WHERE source_id LIKE 'parallel-read-%' AND (kinds & 8) != 0"
        ) == count)
    }

    @Test("getSchedule tags placements with their Goals and Notebooks, never a plain goal")
    func getScheduleTagsGoalsAndNotebooks() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Tagged Source", content: "Tagged.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-now",
            startAt: today,
            endAt: weekEnd,
            items: [(id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil)]
        )
        // A plain goal an older build left behind, tagged to the same placement.
        try execSQL(dbPath: dbPath, """
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status)
            VALUES ('goal-plain', 'This Week', \(today.timeIntervalSinceReferenceDate), \(weekEnd.timeIntervalSinceReferenceDate), 0, 0, 'active');
            INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
            VALUES ('item-a', 'goal-plain', 0);
        """)

        let store = MCPDataStore(dbPath: dbPath)
        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let tags = items.first { ($0["source_id"] as? String) == "source-a" }?["goal_tags"] as? [[String: Any]]

        #expect(payload["schedules"] == nil)
        #expect(tags?.compactMap { $0["id"] as? String } == ["goal-now"])
        #expect(try store.getSchedule(goalID: "goal-plain") == "Goal or Notebook not found: goal-plain")
    }

    @Test("Google Docs interface placeholders are not exposed as source content")
    func googleDocsInterfacePlaceholderIsRejected() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let placeholder = """
        Google Docs
        JavaScript isn't enabled in your browser, so this file can't be opened.
        Enable and reload.
        """

        try insertSource(
            dbPath: dbPath,
            id: "google-doc",
            title: "Feedback",
            content: placeholder
        )
        try execSQL(
            dbPath: dbPath,
            """
            UPDATE articles
            SET url = 'https://docs.google.com/document/d/document-123/edit',
                normalized_url = 'https://docs.google.com/document/d/document-123/edit',
                domain = 'docs.google.com'
            WHERE source_id = 'google-doc'
            """
        )

        let result = try store.getSourceContent("google-doc")

        #expect(result.contains("Google Doc content is not loaded"))
        #expect(!result.contains("JavaScript isn't enabled"))
    }

    @Test("assignSourcesToDay moves existing items")
    func assignSourcesToDayMovesExistingItems() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        // Pick a same-week day that is not today (yesterday when today is Sunday).
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-a", title: "Movable Source", content: "Move me.")
        // Seeding the goal places source-a on the Schedule; only placed sources can move.
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(
            goalID: "goal-1",
            sourceIDs: ["source-a"],
            dateString: formatter.string(from: otherDay)
        )
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let movedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }

        #expect(movedItem?["planned_date"] as? String == formatter.string(from: otherDay))
    }

    /// Slotting a source in part-way through a plan. Adding a source to a Goal
    /// writes only `learning_goal_items`, so it has no placement and used to be
    /// unreachable from the calendar without a full re-plan — which is exactly the
    /// destructive operation. It now gets placed and tagged in one call.
    @Test("assignSourcesToDay places a pool source that has no placement yet")
    func assignSourcesToDayPlacesUnscheduledPoolSource() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-late", title: "Found while reading", content: "Discovered mid-plan.")
        // A goal with no items at all: the source exists in the library but is on
        // neither the pool nor the calendar.
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-1", startAt: weekStart, endAt: weekEnd, items: [])

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(
            goalID: "goal-1",
            sourceIDs: ["source-late"],
            dateString: formatter.string(from: today)
        )

        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let placed = allItems.first { ($0["source_id"] as? String) == "source-late" }

        // Tagged to the goal, not just placed — an untagged placement would be
        // invisible to a goal-scoped Schedule read and treated as an orphan.
        #expect(placed != nil)
        #expect(placed?["planned_date"] as? String == formatter.string(from: today))
    }

    /// The report of 2026-09-19: two sources already on the Schedule for one
    /// goal, assigned to a day with another goal's id — "Assigned 2 sources",
    /// and that goal's own Schedule read still at zero items, because only a
    /// source with no placement at all joined the goal; a placed one was moved
    /// and never tagged, so a second call had to do what the first had
    /// promised.
    @Test("assignSourcesToDay tags a source already on the Schedule for another goal")
    func assignSourcesToDayTagsSourcePlacedForAnotherGoal() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-shared", title: "Read for two goals", content: "Placed once, wanted twice.")
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-first", startAt: weekStart, endAt: weekEnd, items: [])
        try insertScheduleGoal(dbPath: dbPath, goalID: "goal-second", startAt: weekStart, endAt: weekEnd, items: [])

        let store = MCPDataStore(dbPath: dbPath)
        // On the Schedule already, for the first goal.
        _ = try await store.assignSourcesToDay(goalID: "goal-first", sourceIDs: ["source-shared"], dateString: formatter.string(from: today))
        _ = try await store.assignSourcesToDay(
            goalID: "goal-second",
            sourceIDs: ["source-shared"],
            dateString: formatter.string(from: today)
        )

        func placed(in goalID: String) throws -> [String: Any]? {
            let payload = try parseJSON(try store.getSchedule(goalID: goalID, includeCompleted: true))
            let days = payload["days"] as? [[String: Any]]
            return days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
                .first { ($0["source_id"] as? String) == "source-shared" }
        }
        // The second goal owns it now — tagged and pooled, not just moved —
        // and the first keeps it: one placement, two tags.
        let second = try placed(in: "goal-second")
        #expect(second != nil)
        #expect(second?["planned_date"] as? String == formatter.string(from: today))
        #expect(try placed(in: "goal-first") != nil)
        let knowledge = try store.knowledgeStore()
        #expect(try knowledge.scheduledSourceGoalIDs(sourceID: "source-shared").sorted() == ["goal-first", "goal-second"])
        #expect(try knowledge.loadLearningGoal("goal-second")?.items.map(\.sourceID) == ["source-shared"])
    }

    /// A source that isn't on the Schedule yet is now *placed* rather than rejected
    /// (that used to be a dead end — the advice was "add them to a goal first", but
    /// adding to a goal never created a placement). A source that doesn't exist at
    /// all is still refused, now by `validateSourcesExist`, which also stops a typo
    /// creating a placement pointing at nothing: `scheduled_sources.source_id` has
    /// no foreign key by design.
    @Test("assignSourcesToDay rejects sources that do not exist")
    func assignSourcesToDayRejectsUnknownSource() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar(identifier: .gregorian)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4))!
        let end = calendar.date(byAdding: .day, value: 7, to: monday)!

        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: monday,
            endAt: end,
            items: []
        )

        let store = MCPDataStore(dbPath: dbPath)
        do {
            _ = try await store.assignSourcesToDay(
                goalID: "goal-1",
                sourceIDs: ["missing-source"],
                dateString: "2026-05-06"
            )
            Issue.record("Assigning a source that does not exist should fail")
        } catch {
            #expect(error.localizedDescription.contains("Source IDs not found"))
        }
    }

    @Test("assignSourcesToDay places a source untagged when no goal is named")
    func assignSourcesToDayPlacesUntaggedWithoutGoal() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-loose", title: "No Goal Yet", content: "Loose.")

        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(sourceIDs: ["source-loose"], dateString: formatter.string(from: today))

        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let placed = items.first { ($0["source_id"] as? String) == "source-loose" }
        #expect(placed?["planned_date"] as? String == formatter.string(from: today))
        #expect((placed?["goal_tags"] as? [[String: Any]])?.isEmpty == true)
        // Nothing stands in for the missing goal.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM learning_goals") == 0)
    }

    @Test("unscheduleSources with a goal removes that goal's items")
    func unscheduleSourcesFromGoal() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Keep Source", content: "Keep.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Remove Source", content: "Remove.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: otherDay, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.unscheduleSources(goalID: "goal-1", sourceIDs: ["source-b"])
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.count == 1)
        #expect(allItems.first?["source_id"] as? String == "source-a")
    }

    @Test("clearScheduleDay with a goal removes its pending sources on that day")
    func clearScheduleDayForGoal() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-a", title: "Clear Source", content: "Clear.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Other Source", content: "Other.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        let before = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let beforeItems = (before["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        #expect(beforeItems.count == 2)

        _ = try store.clearScheduleDay(goalID: "goal-1", dateString: formatter.string(from: today))
        let payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        let days = payload["days"] as? [[String: Any]]
        let allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []

        #expect(allItems.isEmpty)
    }

    @Test("setSourceCompletion marks done and reopens")
    func setSourceCompletionMarksDoneAndReopens() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Reviewed Source", content: "Reviewed.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Schedule Reviewed Source", content: "Schedule reviewed.")
        // Seeding the goal places both sources on the Schedule; completion can only
        // be toggled for sources that already have a placement.
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )
        try insertCompletedReviewSession(dbPath: dbPath, sessionID: "session-a", sourceID: "source-a", endedAt: today.addingTimeInterval(600))

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-a", isCompleted: true)
        var payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        var days = payload["days"] as? [[String: Any]]
        var allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        var reviewedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }
        #expect(reviewedItem?["is_completed"] as? Bool == true)

        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-b", isCompleted: true)
        payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        days = payload["days"] as? [[String: Any]]
        allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        let scheduleReviewedItem = allItems.first { ($0["source_id"] as? String) == "source-b" }
        #expect(scheduleReviewedItem?["is_completed"] as? Bool == true)
        #expect(scheduleReviewedItem?["latest_review_at"] as? String != nil)
        #expect(scheduleReviewedItem?["has_linked_review_session"] as? Bool == false)

        _ = try store.setSourceCompletion(goalID: "goal-1", sourceID: "source-a", isCompleted: false)
        payload = try parseJSON(try store.getSchedule(goalID: "goal-1"))
        days = payload["days"] as? [[String: Any]]
        allItems = days?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        reviewedItem = allItems.first { ($0["source_id"] as? String) == "source-a" }
        #expect(reviewedItem?["is_completed"] as? Bool == false)
    }

    @Test("unscheduleSources with no goal takes the placement off the Schedule, whatever serves it")
    func unscheduleSourcesWithoutGoal() throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today)!

        try insertSource(dbPath: dbPath, id: "source-a", title: "Keep Source", content: "Keep.")
        try insertSource(dbPath: dbPath, id: "source-b", title: "Remove Source", content: "Remove.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: today,
            endAt: weekEnd,
            items: [
                (id: "item-a", sourceID: "source-a", addedAt: today, completedAt: nil),
                (id: "item-b", sourceID: "source-b", addedAt: today, completedAt: nil),
            ]
        )

        let store = MCPDataStore(dbPath: dbPath)
        _ = try store.unscheduleSources(sourceIDs: ["source-b"])

        let payload = try parseJSON(try store.getSchedule())
        let items = (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        #expect(items.map { $0["source_id"] as? String } == ["source-a"])
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM scheduled_sources WHERE source_id = 'source-b'") == 0)
        // The goal and its pool are untouched: only the plan went.
        #expect(try scalarInt(dbPath: dbPath, "SELECT COUNT(*) FROM learning_goal_items WHERE source_id = 'source-b'") == 1)
        #expect(throws: MCPError.self) {
            _ = try store.unscheduleSources(sourceIDs: ["source-b"])
        }
    }

    @Test("clearScheduleDay and markScheduleDayDone with no goal cover every source on the day")
    func dayToolsWithoutGoalCoverTheWholeDay() async throws {
        let (_, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        let otherDay = weekday == 1
            ? calendar.date(byAdding: .day, value: -1, to: today)!
            : calendar.date(byAdding: .day, value: 1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"

        try insertSource(dbPath: dbPath, id: "source-goal", title: "Goal Source", content: "Tagged.")
        try insertSource(dbPath: dbPath, id: "source-loose", title: "Loose Source", content: "Untagged.")
        try insertSource(dbPath: dbPath, id: "source-later", title: "Later Source", content: "Another day.")
        try insertScheduleGoal(
            dbPath: dbPath,
            goalID: "goal-1",
            startAt: weekStart,
            endAt: weekEnd,
            items: [
                (id: "item-goal", sourceID: "source-goal", addedAt: today, completedAt: nil),
                (id: "item-later", sourceID: "source-later", addedAt: otherDay, completedAt: nil),
            ]
        )
        let store = MCPDataStore(dbPath: dbPath)
        _ = try await store.assignSourcesToDay(sourceIDs: ["source-loose"], dateString: formatter.string(from: today))

        func items() throws -> [[String: Any]] {
            let payload = try parseJSON(try store.getSchedule())
            return (payload["days"] as? [[String: Any]])?.flatMap { ($0["items"] as? [[String: Any]]) ?? [] } ?? []
        }

        _ = try store.markScheduleDayDone(dateString: formatter.string(from: today))
        let done = try items().filter { ($0["is_completed"] as? Bool) == true }.compactMap { $0["source_id"] as? String }
        #expect(Set(done) == ["source-goal", "source-loose"])

        _ = try store.clearScheduleDay(dateString: formatter.string(from: today), includeCompleted: true)
        #expect(try items().compactMap { $0["source_id"] as? String } == ["source-later"])
    }

    @Test("semantic source search tool is exposed in MCP registry")
    func semanticSourceSearchToolIsRegistered() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "search_sources_semantic" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(properties["notebook_id"] != nil)
        #expect(properties["exclude_notebook_id"] != nil)
        #expect(properties["source_type"] != nil)
        // The advertised names carry the axis these filters are on. `date_from`
        // read as the source's own date, and models spent whole turns handing a
        // publication year to a filter on the day a source was saved.
        #expect(properties["added_from"] != nil)
        #expect(properties["added_to"] != nil)
        #expect(properties["date_from"] == nil)
        #expect(properties["date_to"] == nil)
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(required.isEmpty)

        // A client holding the schema this tool shipped with keeps working.
        let legacy = MCPToolRegistry.searchAddedWindow(["date_from": "2026-08-01", "date_to": "2026-08-31"])
        #expect(legacy.from == "2026-08-01")
        #expect(legacy.to == "2026-08-31")
        let current = MCPToolRegistry.searchAddedWindow(["added_from": "2026-08-02", "date_from": "2026-08-01"])
        #expect(current.from == "2026-08-02")
        #expect(MCPToolRegistry.searchAddedWindow([:]).from == nil)
    }

    @Test("in-app tool schemas drop the caller-owned idempotency key")
    func inAppSchemasDropHostOwnedArguments() throws {
        let remoteNames = MCPToolRegistry.shared.tools.filter {
            ($0.inputSchema["properties"] as? [String: Any])?["operation_id"] != nil
        }.map(\.name)
        // The remote schema still offers it to clients with no session of their own.
        #expect(Set(remoteNames) == Set(["start_review_session", "memory_review"]))

        for tool in MCPToolRegistry.shared.tools {
            let properties = tool.inAppInputSchema["properties"] as? [String: Any] ?? [:]
            #expect(properties["operation_id"] == nil, "\(tool.name) still offers operation_id in-app")
            // Everything else is untouched, so the in-app schema is the remote one minus that key.
            let remoteProperties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            #expect(Set(properties.keys) == Set(remoteProperties.keys).subtracting(["operation_id"]))
        }
    }

    @Test("pre-generated source review guide tool is exposed with revision binding")
    func sourceReviewGuideToolIsRegistered() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "save_source_review_guide" })
        let required = try #require(tool.inputSchema["required"] as? [String])
        #expect(Set(required) == Set(["source_id", "content_sha256", "guide"]))
        #expect(MCPToolRegistry.annotations(for: tool.name)["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.annotations(for: tool.name)["destructiveHint"] as? Bool == false)
        #expect(!MCPToolRegistry.isToolAllowed(tool.name, scope: .ingest))
    }

    @Test("MCP status tool is exposed first in MCP registry")
    func mcpStatusToolIsRegisteredFirst() {
        #expect(MCPToolRegistry.shared.tools.first?.name == "get_mcp_status")
    }

    @Test("MCP status tool returns active JSON")
    func mcpStatusToolReturnsActiveJSON() async throws {
        let result = await MCPToolRegistry.shared.callTool(name: "get_mcp_status", arguments: [:], access: .internalFullAccess)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])

        #expect(payload["status"] as? String == "active")
        #expect(payload["server"] as? String == "ForeverLM MCP")
        #expect(payload["tool_count"] as? Int == MCPToolRegistry.shared.tools.count)
        #expect((payload["message"] as? String)?.contains("responding to tool calls") == true)
        // Which iCloud account the library syncs with, for the gateway's web
        // identity check: the test host syncs with no iCloud, so no account.
        let account = try #require(payload["icloud_account"] as? [String: Any])
        #expect(account["syncs_with_icloud"] as? Bool == CloudRuntimeAvailability.isEnabled)
        #expect(account["environment"] as? String == CloudRuntimeAvailability.containerEnvironment.rawValue)
        if !CloudRuntimeAvailability.isEnabled { #expect(account["user_record_name"] == nil) }
    }

    @Test("MCP status names the iCloud account only when the Mac syncs with one and CloudKit said which")
    func mcpStatusICloudAccount() {
        let known = MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: "_0123abcd", environment: "production")
        #expect(known["syncs_with_icloud"] as? Bool == true)
        #expect(known["user_record_name"] as? String == "_0123abcd")
        #expect(known["environment"] as? String == "production")
        // Not known yet, or no iCloud at all: no name, which the gateway reads
        // as unverified and never as a match.
        #expect(MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: nil, environment: "production")["user_record_name"] == nil)
        #expect(MCPDataStore.iCloudAccountStatus(syncs: true, userRecordName: "", environment: "production")["user_record_name"] == nil)
        let signedOut = MCPDataStore.iCloudAccountStatus(syncs: false, userRecordName: "_stale", environment: "development")
        #expect(signedOut["syncs_with_icloud"] as? Bool == false)
        #expect(signedOut["user_record_name"] == nil)
        // The first lookup for an account can wait on CloudKit for seconds:
        // the call holds the store gate only for its index read, never for
        // that wait.
        #expect(MCPToolRegistry.selfGatedToolNames.contains("get_mcp_status"))
    }

    @Test("Notebook source tools are exposed in MCP registry")
    func notebookSourceToolsAreRegistered() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("list_notebooks"))
        #expect(toolNames.contains("create_notebook"))
        #expect(toolNames.contains("get_notebook"))
        #expect(toolNames.contains("add_notebook_sources"))
        #expect(toolNames.contains("list_notebook_sources"))
        #expect(toolNames.contains("reorder_notebook_sources"))
        #expect(toolNames.contains("set_notebook_source_selection"))
        #expect(toolNames.contains("get_notebook_context"))
        #expect(toolNames.contains("list_notebook_files"))
        #expect(toolNames.contains("read_notebook_markdown_file"))
        #expect(toolNames.contains("write_notebook_markdown_file"))
        #expect(toolNames.contains("list_docs"))
        #expect(toolNames.contains("create_doc"))
        #expect(toolNames.contains("read_doc"))
        #expect(toolNames.contains("write_doc"))
        #expect(toolNames.contains("edit_doc"))
        #expect(toolNames.contains("update_doc"))
        #expect(toolNames.contains("delete_doc"))
        #expect(toolNames.contains("link_page"))
        #expect(toolNames.contains("unlink_page"))
        #expect(toolNames.contains("link_google_doc"))
        #expect(toolNames.contains("unlink_google_doc"))
        #expect(toolNames.contains("publish_doc"))
        #expect(toolNames.contains("unpublish_doc"))
        // A chat asked to "make a site" makes a site, not a Doc (2026-09-09).
        #expect(toolNames.contains("save_site"))
        #expect(toolNames.contains("read_site_file"))
        // Lifecycle actions the UI had and MCP did not, closed 2026-09-05.
        #expect(toolNames.contains("update_review_session"))
        #expect(toolNames.contains("set_source_read"))
        #expect(toolNames.contains("merge_meeting_groups"))
        #expect(toolNames.contains("delete_meeting_group"))
        #expect(toolNames.contains("list_open_questions"))
        #expect(toolNames.contains("create_open_question"))
        #expect(toolNames.contains("update_open_question"))
        #expect(toolNames.contains("split_notebook"))
        #expect(toolNames.contains("merge_notebooks"))
        // The day is the Mac's Calendar (docs/planner-design.md); the Planner's
        // own tools went with it on 2026-09-30.
        for name in ["get_calendar_events", "create_calendar_event", "update_calendar_event", "delete_calendar_event", "get_day_activity", "get_day_settings", "set_day_settings"] {
            #expect(toolNames.contains(name), "\(name) is not registered")
        }
        for name in ["get_day_plan", "add_time_block", "update_time_block", "delete_time_block", "revise_day_plan", "update_day_plan", "get_planner_settings", "set_planner_settings"] {
            #expect(!toolNames.contains(name), "\(name) is still registered")
        }
        #expect(!toolNames.contains("set_notebook_slide_sources"))
        #expect(!toolNames.contains("list_notebook_slide_sources"))
        // Slide-specific notebook tools remain retired. Notebook-native Markdown
        // files and global artifacts provide the two editable document surfaces.
        #expect(!toolNames.contains("read_notebook_file"))
        // The notebook canvas tools stay retired; the only tools named for a
        // canvas are the Canvas's own (docs/sensemaking-design.md): reading
        // it, editing it on the learner's word (docs/knowledge-map-design.md),
        // and the learner's canvases in the Space ("Canvases in the Space").
        let canvasOwn = ["ask_canvas", "get_canvas_memory", "make_cards_from_canvas", "lint_canvas", "screenshot_canvas"]
            + MCPToolRegistry.canvasEditToolNames.filter { $0.contains("canvas") }
            + MCPToolRegistry.canvasCatalogToolNames
        #expect(toolNames.filter { $0.contains("canvas") }.sorted() == canvasOwn.sorted())
    }

    @Test("create_notebook stays open-ended and refuses a deadline before writing")
    func createNotebookCannotBecomeInvisibleGoal() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        let created = try await store.createNotebook(
            title: "Conference prep",
            description: nil,
            topic: nil,
            endDateString: "",
            sourceIDs: [],
            dailyTarget: nil,
            discover: false
        )
        let notebookID = try #require(createdNotebookID(in: created))
        let knowledge = try store.knowledgeStore()
        let notebook = try #require(try knowledge.loadLearningGoal(notebookID))
        #expect(notebook.isNotebook)
        #expect(try store.listNotebooks(includeCompleted: false).contains("Conference prep"))

        do {
            _ = try await store.createNotebook(
                title: "Timed notebook",
                description: nil,
                topic: nil,
                endDateString: "2099-12-31",
                sourceIDs: [],
                dailyTarget: nil,
                discover: false
            )
            Issue.record("create_notebook accepted a deadline and created a Goal")
        } catch {
            #expect(error.localizedDescription.contains("create_learning_goal"))
        }
        #expect(try knowledge.loadLearningGoals().allSatisfy { $0.title != "Timed notebook" })

        let createTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_notebook" })
        let updateTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "update_notebook" })
        let createProperties = try #require(createTool.inputSchema["properties"] as? [String: Any])
        let updateProperties = try #require(updateTool.inputSchema["properties"] as? [String: Any])
        #expect(createProperties["end_date"] == nil)
        #expect(updateProperties["end_date"] == nil)
        #expect(updateProperties["open_ended"] == nil)
    }

    @Test("MCP creates and revision-safely edits Notebook Markdown artifacts")
    func mcpEditsNotebookMarkdownArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Writing notebook",
            topic: "articles",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let createdPayload = try parseJSON(try await store.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md",
            markdown: "# Article\n\nFirst draft.",
            expectedRevision: nil
        ))
        let firstRevision = try #require(createdPayload["revision"] as? String)

        let listing = try parseJSON(try await store.listNotebookFiles(notebookID: notebook.id))
        let files = try #require(listing["files"] as? [[String: Any]])
        #expect(files.count == 1)
        #expect(files[0]["path"] as? String == "Article.md")
        #expect(files[0]["editable_markdown"] as? Bool == true)

        let readPayload = try parseJSON(try await store.readNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md"
        ))
        #expect(readPayload["markdown"] as? String == "# Article\n\nFirst draft.")
        #expect(readPayload["revision"] as? String == firstRevision)

        let updatedPayload = try parseJSON(try await store.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Article.md",
            markdown: "# Article\n\nRevised draft.",
            expectedRevision: firstRevision
        ))
        let secondRevision = try #require(updatedPayload["revision"] as? String)
        #expect(secondRevision != firstRevision)

        await #expect(throws: NotebookMarkdownFileError.self) {
            _ = try await store.writeNotebookMarkdownFile(
                notebookID: notebook.id,
                relativePath: "Article.md",
                markdown: "Stale overwrite",
                expectedRevision: firstRevision
            )
        }
    }

    @Test("MCP edits one canonical artifact across linked Notebooks")
    func mcpEditsGlobalArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let first = try knowledge.createCompanionGoal(
            title: "Research",
            topic: "research",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let second = try knowledge.createCompanionGoal(
            title: "Writing",
            topic: "writing",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let created = try parseJSON(try await store.createArtifact(
            title: "Shared article",
            homeNotebookID: first.id,
            notebookIDs: [first.id, second.id],
            markdown: "# Shared\n\nFirst draft.",
            isDraft: true
        ))
        let artifactPayload = try #require(created["doc"] as? [String: Any])
        let artifactID = try #require(artifactPayload["id"] as? String)
        let revision = try #require(created["revision"] as? String)
        #expect(artifactPayload["is_draft"] as? Bool == true)

        let secondListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(secondListing["doc_count"] as? Int == 1)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: artifactID,
            markdown: "# Shared\n\nRevised once.",
            expectedRevision: revision
        ))
        #expect((saved["revision"] as? String) != revision)
        let read = try parseJSON(try await store.readArtifact(artifactID: artifactID))
        #expect(read["markdown"] as? String == "# Shared\n\nRevised once.")
        #expect(read["is_complete"] as? Bool == true)
        let range = try parseJSON(try await store.readArtifact(
            artifactID: artifactID,
            start: 2,
            length: 6
        ))
        #expect(range["markdown"] as? String == "Shared")
        #expect(range["range_start"] as? Int == 2)
        #expect(range["range_end"] as? Int == 8)
        #expect(range["is_complete"] as? Bool == false)
        #expect(range["revision"] as? String == read["revision"] as? String)

        _ = try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: [second.id],
            isDraft: false
        )
        let firstListing = try parseJSON(try await store.listArtifacts(notebookID: first.id))
        #expect(firstListing["doc_count"] as? Int == 0)
        let globalListing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        #expect(globalListing["doc_count"] as? Int == 1)
        let globalArtifacts = try #require(globalListing["docs"] as? [[String: Any]])
        #expect(globalArtifacts.first?["is_draft"] as? Bool == false)
        #expect(globalArtifacts.first?["is_archived"] as? Bool == false)
        #expect(globalArtifacts.first?["archived_at"] is NSNull)

        // Archive over MCP: the Doc stays listed with its links, marked and dated.
        let archived = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isArchived: true
        ))
        let archivedDoc = try #require(archived["doc"] as? [String: Any])
        #expect(archivedDoc["is_archived"] as? Bool == true)
        #expect(archivedDoc["archived_at"] is String)
        #expect(archivedDoc["notebook_ids"] as? [String] == [second.id])
        let archivedListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(archivedListing["doc_count"] as? Int == 1)

        let restored = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isArchived: false
        ))
        let restoredDoc = try #require(restored["doc"] as? [String: Any])
        #expect(restoredDoc["is_archived"] as? Bool == false)
        #expect(restoredDoc["archived_at"] is NSNull)
        #expect(restoredDoc["is_hidden"] as? Bool == false)
        #expect(restoredDoc["hidden_at"] is NSNull)

        // Hide over MCP: this Mac's view only. The Doc stays listed with its
        // links, marked and dated, and its own date does not move — a call
        // that only hides never runs the record update.
        let hidden = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isHidden: true
        ))
        let hiddenDoc = try #require(hidden["doc"] as? [String: Any])
        #expect(hiddenDoc["is_hidden"] as? Bool == true)
        #expect(hiddenDoc["hidden_at"] is String)
        #expect(hiddenDoc["is_archived"] as? Bool == false)
        #expect(hiddenDoc["updated_at"] as? String == restoredDoc["updated_at"] as? String)
        #expect(hiddenDoc["notebook_ids"] as? [String] == [second.id])
        let hiddenListing = try parseJSON(try await store.listArtifacts(notebookID: second.id))
        #expect(hiddenListing["doc_count"] as? Int == 1)

        let shown = try parseJSON(try await store.updateArtifact(
            artifactID: artifactID,
            title: nil,
            homeNotebookID: nil,
            notebookIDs: nil,
            isHidden: false
        ))
        let shownDoc = try #require(shown["doc"] as? [String: Any])
        #expect(shownDoc["is_hidden"] as? Bool == false)
        #expect(shownDoc["hidden_at"] is NSNull)
    }

    @Test("MCP moves a Doc to the Trash and removes a linked Google Doc from Docs")
    func mcpDeletesDocs() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Working notes", homeNotebookID: nil, notebookIDs: [], markdown: "# Notes"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let url = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/d/1Del/edit")
        let linked = try await store.notebookFileStorage.createLinkedArtifact(
            url: url, title: "Shared plan", homeNotebookID: nil, linkedNotebookIDs: []
        )
        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 2)

        let deleted = try parseJSON(try await store.deleteArtifact(artifactID: docID))
        #expect(deleted["status"] as? String == "deleted")
        #expect((deleted["message"] as? String)?.contains("Trash") == true)
        #expect((deleted["doc"] as? [String: Any])?["title"] as? String == "Working notes")

        // A linked doc is only taken out of Docs, and the answer says so.
        let removed = try parseJSON(try await store.deleteArtifact(artifactID: linked.id))
        #expect(removed["status"] as? String == "removed")
        #expect((removed["message"] as? String)?.contains("Google Doc itself was not touched") == true)

        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 0)
        await #expect(throws: (any Error).self) { _ = try await store.readArtifact(artifactID: docID) }
        // Deleting what is already gone is a clear not-found, not a silent success.
        await #expect(throws: (any Error).self) { _ = try await store.deleteArtifact(artifactID: docID) }
        await #expect(throws: (any Error).self) { _ = try await store.deleteArtifact(artifactID: "  ") }
    }

    @Test("MCP links a Google Doc into Docs and unlinks it into a Markdown doc")
    func mcpLinksAndUnlinksGoogleDocs() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        await #expect(throws: (any Error).self) {
            _ = try await store.linkGoogleDocArtifact(
                urlString: "https://example.com/not-a-doc", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }

        let linked = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Lnk/edit?usp=sharing",
            title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(linked["status"] as? String == "linked")
        let linkedDoc = try #require(linked["doc"] as? [String: Any])
        let docID = try #require(linkedDoc["id"] as? String)
        #expect(linkedDoc["kind"] as? String == "google_doc")
        #expect(linkedDoc["read_only"] as? Bool == true)
        #expect(linkedDoc["title"] as? String == LinkedGoogleDoc.placeholderTitle)
        #expect(linkedDoc["linked_url"] as? String == "https://docs.google.com/document/d/1Lnk/edit")

        // The same Google Doc, by another form of its link, is the same entry.
        let again = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Lnk/view", title: "Ignored", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(again["status"] as? String == "already_linked")
        #expect((again["doc"] as? [String: Any])?["id"] as? String == docID)
        #expect(try parseJSON(try await store.listArtifacts(notebookID: nil))["doc_count"] as? Int == 1)

        // A passed title is kept.
        let titled = try parseJSON(try await store.linkGoogleDocArtifact(
            urlString: "https://docs.google.com/document/d/1Ttl/edit", title: "Q3 plan", homeNotebookID: nil, notebookIDs: []
        ))
        #expect((titled["doc"] as? [String: Any])?["title"] as? String == "Q3 plan")

        // Unlinking: the export becomes the editable body and write_doc works again.
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: docID, text: "Exported text."
        )
        let unlinked = try parseJSON(try await store.unlinkGoogleDocArtifact(artifactID: docID))
        #expect(unlinked["status"] as? String == "unlinked")
        let unlinkedDoc = try #require(unlinked["doc"] as? [String: Any])
        #expect(unlinkedDoc["kind"] as? String == "markdown")
        #expect(unlinkedDoc["read_only"] as? Bool == false)
        let revision = try #require(unlinked["revision"] as? String)
        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "Exported text.")
        #expect(read["revision"] as? String == revision)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Mine now", expectedRevision: revision
        ))
        #expect((saved["revision"] as? String) != revision)
        // A Markdown doc cannot be unlinked.
        await #expect(throws: (any Error).self) { _ = try await store.unlinkGoogleDocArtifact(artifactID: docID) }
    }

    @Test("MCP links a Claude artifact and a Codex site, with an initial text copy, and reports their kinds")
    func mcpLinksClaudeArtifactsAndCodexSites() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        // Any other website, and a site on its own domain, is refused.
        await #expect(throws: (any Error).self) {
            _ = try await store.linkPageArtifact(
                urlString: "https://landscape.example.org/", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.linkPageArtifact(
                urlString: "https://claude.ai/code/artifacts", title: nil, homeNotebookID: nil, notebookIDs: []
            )
        }

        // A Claude artifact, with the content the caller could read itself.
        let artifactURL = "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d"
        let linked = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL + "?v=2",
            title: nil, text: "# Landscape\n\n\n\nFirst finding.  \n", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(linked["status"] as? String == "linked")
        let doc = try #require(linked["doc"] as? [String: Any])
        let docID = try #require(doc["id"] as? String)
        #expect(doc["kind"] as? String == "claude_artifact")
        #expect(doc["read_only"] as? Bool == true)
        #expect(doc["title"] as? String == LinkedPageKind.claudeArtifact.placeholderTitle)
        #expect(doc["linked_url"] as? String == artifactURL)
        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# Landscape\n\nFirst finding.")
        #expect(read["kind"] as? String == "claude_artifact")
        #expect((read["guidance"] as? String)?.contains("Claude Artifact") == true)
        // The same artifact by another form of its link is the same entry.
        let again = try parseJSON(try await store.linkPageArtifact(
            urlString: "claude.ai/code/artifact/A1B2C3D4-1E2F-4A5B-8C6D-7E8F9A0B1C2D#top",
            title: "Ignored", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(again["status"] as? String == "already_linked")
        #expect((again["doc"] as? [String: Any])?["id"] as? String == docID)

        // A Codex site, with no copy yet.
        let site = try parseJSON(try await store.linkPageArtifact(
            urlString: "techbio-companies-landscape.learner-1234.chatgpt.site/?ref=x",
            title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteDoc = try #require(site["doc"] as? [String: Any])
        #expect(siteDoc["kind"] as? String == "codex_site")
        #expect(siteDoc["title"] as? String == "Codex Site")
        #expect(siteDoc["linked_url"] as? String == "https://techbio-companies-landscape.learner-1234.chatgpt.site/")
        #expect((site["message"] as? String)?.contains("read_doc returns an empty body") == true)
        let siteID = try #require(siteDoc["id"] as? String)
        let listed = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let kinds = Set(((listed["docs"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String })
        #expect(kinds == ["claude_artifact", "codex_site"])

        // Neither can be edited or published here; both unlink into Markdown.
        // The refusal names the way a copy follows an edit made in the product.
        do {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "x", expectedRevision: "")
            Issue.record("write_doc accepted a linked page")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Claude Artifact"))
            #expect(message.contains("link_page"))
            #expect(message.contains("unlink_page"))
        }
        do {
            _ = try await store.editArtifact(
                artifactID: docID, edits: [.init(find: "First", replace: "Second")], append: nil, expectedRevision: ""
            )
            Issue.record("edit_doc accepted a linked page")
        } catch {
            #expect(error.localizedDescription.contains("link_page"))
        }
        // Linking the same page again with text is how the copy is refreshed
        // after the page changed where it lives.
        let refreshed = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL, title: nil, text: "# Landscape\n\nSecond finding.", homeNotebookID: nil, notebookIDs: []
        ))
        #expect(refreshed["status"] as? String == "already_linked")
        #expect(refreshed["text_copy_refreshed"] as? Bool == true)
        let reread = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(reread["markdown"] as? String == "# Landscape\n\nSecond finding.")
        let unchanged = try parseJSON(try await store.linkPageArtifact(
            urlString: artifactURL, title: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(unchanged["text_copy_refreshed"] as? Bool == false)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nSecond finding.")
        let removed = try parseJSON(try await store.deleteArtifact(artifactID: siteID))
        #expect(removed["status"] as? String == "removed")
        #expect((removed["message"] as? String)?.contains("Codex Site itself was not touched") == true)
        let unlinked = try parseJSON(try await store.unlinkPageArtifact(artifactID: docID))
        #expect((unlinked["doc"] as? [String: Any])?["kind"] as? String == "markdown")
        #expect((unlinked["message"] as? String)?.contains("Claude Artifact itself was not touched") == true)
    }

    @Test("write_doc and edit_doc with publish save the Doc and say when there is no page to update")
    func mcpPublishFlagWithoutAPage() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Landscape", homeNotebookID: nil, notebookIDs: [], markdown: "# Landscape\n\nDraft."
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String)

        // Not signed in, so no page can be known: the body is saved and the
        // result says the page was not updated, without failing the write.
        let written = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nWritten.", expectedRevision: revision, publish: true
        ))
        #expect(written["page_updated"] as? Bool == false)
        #expect((written["guidance"] as? String)?.contains("publish_doc") == true)
        let revision2 = try #require(written["revision"] as? String)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nWritten.")

        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID, edits: [.init(find: "Written.", replace: "Edited.")], append: nil,
            expectedRevision: revision2, publish: true
        ))
        #expect(edited["page_updated"] as? Bool == false)
        #expect(edited["replacements"] as? Int == 1)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nEdited.")

        // Without the flag nothing about the result changes for an unpublished Doc.
        let revision3 = try #require(edited["revision"] as? String)
        let plain = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nPlain.", expectedRevision: revision3
        ))
        #expect(plain["page_updated"] == nil)
        #expect(plain["page_stale"] == nil)
    }

    @Test("A Doc write never saves a picture line the Doc cannot show, and an older such line never blocks an edit")
    func mcpDocWriteKeepsOnlyPicturesItCanShow() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let picture = "![Figure 1](foreverlm://image/src_missing/page/1)"

        // create_doc: refused, and no Doc is left behind.
        let before = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).count
        do {
            _ = try await store.createArtifact(title: "Paper", homeNotebookID: nil, notebookIDs: [], markdown: "# Paper\n\n\(picture)\n")
            Issue.record("create_doc saved a picture it cannot show")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Nothing was saved"))
            #expect(message.contains("foreverlm://image/src_missing/page/1: no source src_missing is in this library."))
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).count == before)

        // write_doc: refused, body unchanged.
        let created = try parseJSON(try await store.createArtifact(
            title: "Paper", homeNotebookID: nil, notebookIDs: [], markdown: "# Paper\n\nText."
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(created["revision"] as? String)
        await #expect(throws: MCPError.self) {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "# Paper\n\n\(picture)\n", expectedRevision: revision)
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Paper\n\nText.")

        // A line the Doc already carried — saved before Docs kept their
        // pictures — stays as it was while the rest of the Doc is edited.
        let legacy = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: docID, markdown: "# Paper\n\n\(picture)\n\nText.", expectedRevision: revision
        )
        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID, edits: [.init(find: "Text.", replace: "Edited.")], append: nil,
            expectedRevision: legacy.revision
        ))
        #expect(edited["replacements"] as? Int == 1)
        let notShown = try #require(edited["pictures_not_shown"] as? [[String: Any]])
        #expect(notShown.first?["address"] as? String == "foreverlm://image/src_missing/page/1")
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String
            == "# Paper\n\n\(picture)\n\nEdited.")
    }

    @Test("MCP renames a chat and files it under a Notebook")
    func mcpUpdatesReviewSession() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Metabolism", topic: "metabolism", startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt, dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let sessionID = "session-rename-\(UUID().uuidString)"
        try knowledge.saveReviewSessionRecord(
            CloudKitReviewSessionPayload(
                id: sessionID, topic: "Untitled chat", startedAt: Date(), endedAt: nil, status: "active",
                overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, goalID: nil,
                exchanges: [], sourceIdentities: []
            )
        )

        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: "   ", notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: "missing-session", title: "X", notebookID: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: "no-such-notebook")
        }

        let renamed = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: "Mitochondria biotechs", notebookID: notebook.id
        ))
        #expect(renamed["title"] as? String == "Mitochondria biotechs")
        #expect(renamed["notebook_id"] as? String == notebook.id)
        let filed = try #require(try knowledge.loadReviewSessionForSync(sessionID))
        #expect(filed.topic == "Mitochondria biotechs")
        #expect(filed.goalID == notebook.id)

        // "" moves the chat out of every Notebook; the title is kept.
        let ungrouped = try parseJSON(try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: ""))
        #expect(ungrouped["notebook_id"] is NSNull)
        #expect(ungrouped["title"] as? String == "Mitochondria biotechs")
        #expect(ungrouped["is_hidden"] as? Bool == false)
        #expect(ungrouped["hidden_at"] is NSNull)
        #expect(try knowledge.loadReviewSessionForSync(sessionID)?.goalID == nil)
    }

    @Test("MCP hides a chat from the sidebar on every Mac and shows it again")
    func mcpHidesReviewSession() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let sessionID = "session-hide-\(UUID().uuidString)"
        let payload = CloudKitReviewSessionPayload(
            id: sessionID, topic: "Uncoupler pharmacology", startedAt: Date(), endedAt: nil, status: "active",
            overallScore: nil, summary: nil, sourceIDs: [], cardIDs: [], exchangeCount: 0, goalID: nil,
            exchanges: [], sourceIdentities: []
        )
        try knowledge.saveReviewSessionRecord(payload)
        let sessionSavesBefore = try knowledge.pendingSyncChanges().filter { $0.entity == .reviewSession }.count

        // Hide over MCP: the row is marked and dated, nothing else about the
        // chat moves, and the chat itself is not republished — hiding is the
        // learner's view of the chat, not a record change. The hide travels
        // as a record of its own, so the learner's other Macs fold it too.
        let hidden = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: nil, notebookID: nil, isHidden: true
        ))
        #expect(hidden["is_hidden"] as? Bool == true)
        #expect(hidden["hidden_at"] is String)
        #expect(hidden["title"] as? String == "Uncoupler pharmacology")
        #expect((hidden["message"] as? String)?.contains("hidden from the sidebar") == true)
        let queued = try knowledge.pendingSyncChanges()
        #expect(queued.filter { $0.entity == .reviewSession }.count == sessionSavesBefore)
        #expect(queued.contains { $0.entity == .hiddenReviewSession && $0.logicalKey == sessionID && $0.operation == .save })
        let hiddenLink = try #require(try knowledge.loadReviewSessionLinks().first { $0.id == sessionID })
        #expect(hiddenLink.isHidden)
        let hiddenAt = try #require(hiddenLink.hiddenAt)
        // Still the learner's chat: the listing keeps it, marked, so an
        // assistant can find it and show it again.
        let listing = try store.getReviewSessions(topic: "Uncoupler")
        #expect(listing.contains("(id: \(sessionID))"))
        #expect(listing.contains("[hidden from the sidebar]"))

        // Re-hiding keeps the original date; a CloudKit merge of the same
        // chat leaves the learner's choice standing.
        _ = try store.updateReviewSession(sessionID: sessionID, title: nil, notebookID: nil, isHidden: true)
        try knowledge.saveReviewSessionRecord(payload)
        #expect(try knowledge.reviewSessionHiddenAt(sessionID: sessionID) == hiddenAt)

        // A rename while hidden keeps it hidden.
        let renamed = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: "Uncouplers", notebookID: nil
        ))
        #expect(renamed["title"] as? String == "Uncouplers")
        #expect(renamed["is_hidden"] as? Bool == true)

        let shown = try parseJSON(try store.updateReviewSession(
            sessionID: sessionID, title: nil, notebookID: nil, isHidden: false
        ))
        #expect(shown["is_hidden"] as? Bool == false)
        #expect(shown["hidden_at"] is NSNull)
        #expect(try knowledge.loadReviewSessionLinks().first { $0.id == sessionID }?.isHidden == false)
        #expect(!(try store.getReviewSessions(topic: "Uncouplers")).contains("[hidden"))
        // Showing it again tombstones the hide for the other Macs.
        #expect(try knowledge.pendingSyncChanges().contains { $0.entity == .hiddenReviewSession && $0.logicalKey == sessionID && $0.operation == .delete })

        // A hide of a chat that does not exist is refused, and is_hidden alone
        // is a complete request.
        await #expect(throws: (any Error).self) {
            _ = try store.updateReviewSession(sessionID: "missing-session", title: nil, notebookID: nil, isHidden: true)
        }
    }

    @Test("MCP marks a source read and unread, only where the app tracks it")
    func mcpSetsSourceRead() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        _ = try store.addSource(
            url: "https://example.com/read-me", title: "Read me", sourceType: "article",
            content: "Body", parentGroup: nil, author: nil
        )
        let articleID = try sourceID(in: store, url: "https://example.com/read-me")
        _ = try store.addSource(
            url: "https://example.com/podcast/1", title: "Episode", sourceType: "podcast",
            content: "Transcript", parentGroup: "Show", author: nil
        )
        let podcastID = try sourceID(in: store, url: "https://example.com/podcast/1")
        let knowledge = try store.knowledgeStore()

        let marked = try parseJSON(try store.setSourceRead(sourceID: articleID, read: true))
        #expect(marked["is_read"] as? Bool == true)
        #expect(marked["read_at"] is String)
        #expect(try knowledge.loadSourceForSync(articleID)?.readAt != nil)

        let cleared = try parseJSON(try store.setSourceRead(sourceID: articleID, read: false))
        #expect(cleared["is_read"] as? Bool == false)
        #expect(cleared["read_at"] is NSNull)
        #expect(try knowledge.loadSourceForSync(articleID)?.readAt == nil)

        // A podcast has no read state in the app, so the tool refuses rather
        // than stamping a field nothing shows.
        await #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: podcastID, read: true) }
        await #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: "missing", read: true) }
    }

    @Test("MCP marks a video not watched and watched, as the Sources sidebar does")
    func mcpSetsVideoWatched() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=mcp-watched",
            title: "Lecture",
            sourceType: .video,
            id: "mcp-watched-video"
        )
        video.readingPositionLocator = VideoWatchProgress(
            positionSeconds: 3500,
            watchedSeconds: 3550,
            durationSeconds: 3600
        ).encoded
        video.readAt = Date(timeIntervalSinceNow: -3600)
        try knowledge.saveSource(video)
        // The seed's own full save is pending too, and a full save rightly
        // outranks the progress-only mark in sync_changes; clear it so the
        // mark's row is the one asked about, as the storage suite does.
        try knowledge.clearPendingSyncChange(entity: .source, logicalKey: video.id)

        // read: false is Mark as Not Watched: the progress and the read stamp go.
        let cleared = try parseJSON(try store.setSourceRead(sourceID: video.id, read: false))
        #expect(cleared["status"] as? String == "updated")
        #expect(cleared["is_watched"] as? Bool == false)
        #expect(cleared["read_at"] is NSNull)
        let reloaded = try #require(try knowledge.loadSourceForSync(video.id))
        #expect(reloaded.readAt == nil)
        #expect(VideoWatchProgress.isUnwatchedMarker(reloaded.readingPositionLocator))
        // Generation 1 queues the mark as a source change. Under generation 2 it is the video's
        // ReadingState row, which the outbox triggers send once the store is activated (the
        // reading-state suites pin that), so a store that never activated queues nothing.
        if knowledge.syncGeneration == .one {
            #expect(try knowledge.hasPendingTutorOnlySyncChange(entity: .source, logicalKey: video.id))
        }

        let again = try parseJSON(try store.setSourceRead(sourceID: video.id, read: false))
        #expect(again["status"] as? String == "unchanged")

        // read: true is Mark as Watched, which the known length makes possible.
        let finished = try parseJSON(try store.setSourceRead(sourceID: video.id, read: true))
        #expect(finished["status"] as? String == "updated")
        #expect(finished["is_watched"] as? Bool == true)
        #expect(
            VideoWatchProgress(encoded: try knowledge.loadSourceReadingLocator(sourceID: video.id))?
                .isEssentiallyWatched == true
        )

        // A video that has never played has no length to finish it with.
        let unplayed = StudioArticle(
            url: "https://www.youtube.com/watch?v=mcp-unplayed",
            title: "Unplayed",
            sourceType: .video,
            id: "mcp-unplayed-video"
        )
        try knowledge.saveSource(unplayed)
        #expect(throws: (any Error).self) { _ = try store.setSourceRead(sourceID: unplayed.id, read: true) }
    }

    @Test("MCP merges meeting series and deletes one with its sessions")
    func mcpMergesAndDeletesMeetingGroups() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        try knowledge.saveMeetingGroup(name: "Lab Meeting", metadata: MeetingMetadata())
        try knowledge.saveMeetingGroup(name: "Lab meeting (old)", metadata: MeetingMetadata())
        try knowledge.saveMeetingGroup(name: "Journal Club", metadata: MeetingMetadata())
        _ = try store.addSource(
            url: "meeting://old/1", title: "Lab 2026-08-24", sourceType: "meeting",
            content: "Transcript one", parentGroup: "Lab meeting (old)", author: nil
        )
        _ = try store.addSource(
            url: "meeting://club/1", title: "Club 2026-08-25", sourceType: "meeting",
            content: "Transcript two", parentGroup: "Journal Club", author: nil
        )
        let oldSessionID = try sourceID(in: store, url: "meeting://old/1")
        let clubSessionID = try sourceID(in: store, url: "meeting://club/1")

        await #expect(throws: (any Error).self) {
            _ = try store.mergeMeetingGroups(sourceGroupID: "Lab meeting (old)", targetGroupID: "Lab meeting (old)")
        }
        await #expect(throws: (any Error).self) {
            _ = try store.mergeMeetingGroups(sourceGroupID: "Nope", targetGroupID: "Lab Meeting")
        }
        let merged = try parseJSON(try store.mergeMeetingGroups(
            sourceGroupID: "Lab meeting (old)", targetGroupID: "Lab Meeting"
        ))
        #expect(merged["status"] as? String == "merged")
        #expect(merged["sessions_moved"] as? Int == 1)
        #expect(merged["sessions_in_target"] as? Int == 1)
        #expect(try knowledge.loadSourceForSync(oldSessionID)?.parentGroup == "Lab Meeting")
        // The folded folder is gone from the list; its id still resolves.
        let groups = try parseJSON(try store.listMeetingGroups())
        let groupIDs = try #require(groups["meeting_groups"] as? [[String: Any]]).compactMap { $0["group_id"] as? String }
        #expect(groupIDs.contains("Lab Meeting"))
        #expect(!groupIDs.contains("Lab meeting (old)"))
        #expect(try knowledge.canonicalMeetingGroupID("Lab meeting (old)") == "Lab Meeting")

        let deleted = try parseJSON(try await store.deleteMeetingGroup(groupID: "Journal Club"))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["deleted_session_ids"] as? [String] == [clubSessionID])
        #expect(try knowledge.loadSourceForSync(clubSessionID) == nil)
        #expect(try knowledge.loadSourceForSync(oldSessionID) != nil)
        await #expect(throws: (any Error).self) { _ = try await store.deleteMeetingGroup(groupID: "Journal Club") }
    }

    @Test("MCP folds a series' same-day sessions into one, and answers nothing_to_merge the second time")
    func mcpMergesSameDayMeetingSessions() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let group = "Robin <> Zara standup"
        try knowledge.saveMeetingGroup(name: group, metadata: MeetingMetadata(title: group))

        // Filed the way import_meeting_transcript_files and the Zoom watcher
        // key a session: the start to the minute in the key, occurred_at set.
        let dayStart = try #require(DayPlan.startOfDay("2026-09-19"))
        func file(minutes: Int, text: String) throws -> String {
            let start = dayStart.addingTimeInterval(TimeInterval(minutes * 60))
            let key = StudioViewModel.readAISessionKey(title: group, date: start, includeTime: true)
            let url = "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(key))"
            _ = try store.addSource(
                url: url, title: key, sourceType: "meeting", content: "# \(key)\n\n## Transcript\n\n\(text)",
                parentGroup: group, author: nil, occurredAt: MCPDataStore.iso8601String(start)
            )
            return try sourceID(in: store, url: url)
        }
        let first = try file(minutes: 510, text: "Part one.")
        let second = try file(minutes: 550, text: "Part two, after the drop.")
        let nextDayStart = try #require(DayPlan.startOfDay("2026-09-20"))
        let nextKey = StudioViewModel.readAISessionKey(title: group, date: nextDayStart.addingTimeInterval(510 * 60), includeTime: true)
        _ = try store.addSource(
            url: "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(nextKey))", title: nextKey,
            sourceType: "meeting", content: "Another day.", parentGroup: group, author: nil,
            occurredAt: MCPDataStore.iso8601String(nextDayStart.addingTimeInterval(510 * 60))
        )

        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: "Nope", date: nil, sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: group, date: "19 Sep", sourceIDs: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: [first])
        }

        // A day the series met once has nothing to fold.
        let quiet = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: "2026-09-20", sourceIDs: nil))
        #expect(quiet["status"] as? String == "nothing_to_merge")

        let merged = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: nil, sourceIDs: nil))
        #expect(merged["status"] as? String == "merged")
        #expect(merged["sessions_folded"] as? Int == 1)
        let merges = try #require(merged["merges"] as? [[String: Any]])
        #expect(merges.count == 1)
        #expect(merges.first?["survivor_id"] as? String == first)
        #expect(merges.first?["absorbed_ids"] as? [String] == [second])
        #expect(merges.first?["date"] as? String == "2026-09-19")

        // The survivor holds both parts; the reconnect's row is archived and
        // still answers for its URL, so a re-push is "already exists", never a
        // second session.
        let content = try #require(try knowledge.loadSourceContent(first))
        #expect(content.contains("Part one."))
        #expect(content.contains("—— Reconnected at 09:10 ——"))
        #expect(content.contains("Part two, after the drop."))
        #expect(try knowledge.loadSourceForSync(second)?.status == .archived)
        #expect(try knowledge.loadActiveSources().filter { $0.sourceType == .meeting }.count == 2)
        let secondKey = StudioViewModel.readAISessionKey(title: group, date: dayStart.addingTimeInterval(550 * 60), includeTime: true)
        let repush = try store.addSource(
            url: "meeting://\(group)/\(StudioViewModel.percentEncodedMeetingPathComponent(secondKey))", title: secondKey,
            sourceType: "meeting", content: "Part two, after the drop.", parentGroup: group, author: nil
        )
        #expect(repush.hasPrefix("Source already exists"))

        // Idempotent.
        let again = try parseJSON(try await store.mergeMeetingSessions(groupID: group, date: nil, sourceIDs: nil))
        #expect(again["status"] as? String == "nothing_to_merge")

        // Explicit ids: a different series' session is refused as input.
        try knowledge.saveMeetingGroup(name: "Other", metadata: MeetingMetadata(title: "Other"))
        _ = try store.addSource(
            url: "meeting://Other/1", title: "Other - 2026/09/19 08:30", sourceType: "meeting",
            content: "Elsewhere.", parentGroup: "Other", author: nil
        )
        let other = try sourceID(in: store, url: "meeting://Other/1")
        await #expect(throws: (any Error).self) {
            _ = try await store.mergeMeetingSessions(groupID: nil, date: nil, sourceIDs: [first, other])
        }
    }

    @Test("A linked Google Doc is read-only through the doc tools")
    func mcpLinkedDocIsReadOnly() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let url = try LinkedGoogleDoc.canonicalEditURL(from: "https://docs.google.com/document/d/1AbC/edit?usp=sharing")
        let linked = try await store.notebookFileStorage.createLinkedArtifact(
            url: url,
            title: "Shared plan",
            homeNotebookID: nil,
            linkedNotebookIDs: []
        )
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: linked.id,
            text: "Q3 planning\n\nShip the linked doc."
        )

        let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let docs = try #require(listing["docs"] as? [[String: Any]])
        let listed = try #require(docs.first { $0["id"] as? String == linked.id })
        #expect(listed["kind"] as? String == "google_doc")
        #expect(listed["read_only"] as? Bool == true)
        #expect(listed["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")

        let read = try parseJSON(try await store.readArtifact(artifactID: linked.id))
        #expect(read["markdown"] as? String == "Q3 planning\n\nShip the linked doc.")
        #expect(read["read_only"] as? Bool == true)
        #expect(read["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")
        #expect((read["guidance"] as? String)?.contains("Google Doc") == true)
        let revision = try #require(read["revision"] as? String)

        // Refused with the route: edit it in Google Docs, refresh the copy with
        // link_page, or unlink it into a Doc of ForeverLM's own.
        do {
            _ = try await store.writeArtifact(
                artifactID: linked.id,
                markdown: "# Rewritten",
                expectedRevision: revision
            )
            Issue.record("write_doc accepted a linked Google Doc")
        } catch {
            #expect(error.localizedDescription.contains("Google Docs"))
            #expect(error.localizedDescription.contains("unlink_page"))
        }
        // Metadata is still the learner's to change: the title and Notebook links
        // describe where the doc sits in ForeverLM, not what it says.
        let renamed = try parseJSON(try await store.updateArtifact(
            artifactID: linked.id,
            title: "Q3 plan",
            homeNotebookID: nil,
            notebookIDs: nil
        ))
        let renamedDoc = try #require(renamed["doc"] as? [String: Any])
        #expect(renamedDoc["title"] as? String == "Q3 plan")
        #expect(renamedDoc["linked_url"] as? String == "https://docs.google.com/document/d/1AbC/edit")
        // A Markdown doc reports itself as one, with no link.
        let created = try parseJSON(try await store.createArtifact(
            title: "Own words", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine"
        ))
        let createdDoc = try #require(created["doc"] as? [String: Any])
        #expect(createdDoc["kind"] as? String == "markdown")
        #expect(createdDoc["read_only"] as? Bool == false)
        #expect(createdDoc["linked_url"] is NSNull)
    }

    @Test("save_site keeps the files in the library with a text copy, and nothing goes on the web")
    func mcpSaveSite() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // The files are checked before anything is stored.
        for (html, files, message) in [
            (nil as String?, nil as [Any]?, "Pass the site's files"),
            (nil, [["path": "about.html", "content": "<p>"]] as [Any], "needs an index.html"),
            ("<h1>", [["path": "../x.css", "content": "p{}"]] as [Any], "not a file path"),
            ("<h1>", [["path": "index.html", "content": "<p>"]] as [Any], "entry page once"),
            ("<h1>", [["path": "a.css", "content": "p{}", "content_base64": "cHt9"]] as [Any], "exactly one of"),
        ] {
            do {
                _ = try await store.saveSite(site: nil, title: "Mito", html: html, files: files, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
                Issue.record("save_site accepted \(message)")
            } catch {
                #expect(error.localizedDescription.contains(message), "\(error.localizedDescription)")
            }
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).isEmpty)

        // Saving needs no account: the site is the library's. html
        // becomes index.html, the entry is a ForeverLM site at its library
        // address, and the visible text is its copy.
        let saved = try parseJSON(try await store.saveSite(
            site: nil, title: "  Mito   Landscape ", html: "<!doctype html><html><head><title>Mito</title><style>h1{}</style></head><body><h1>Mito Landscape</h1><p>Forty &amp; one companies.</p><script>x()</script></body></html>",
            files: [["path": "./css/site.css", "content": "h1{color:red}"], ["path": "img/dot.png", "content_base64": "iVBORw0KGgo="]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(saved["status"] as? String == "saved")
        let docID = try #require(saved["site_id"] as? String)
        #expect(saved["url"] as? String == "foreverlm-site://\(docID)/")
        #expect(saved["files"] as? Int == 3)
        #expect(saved["file_paths"] as? [String] == ["index.html", "css/site.css", "img/dot.png"])
        #expect((saved["message"] as? String)?.contains("never puts a site on the web") == true)
        let doc = try #require(saved["doc"] as? [String: Any])
        #expect(doc["id"] as? String == docID)
        #expect(doc["kind"] as? String == "foreverlm_site")
        #expect(doc["linked_url"] as? String == "foreverlm-site://\(docID)/")
        #expect(doc["read_only"] as? Bool == true)
        #expect(doc["title"] as? String == "Mito Landscape")
        let onDisk = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: docID))
        #expect(onDisk.map(\.path) == ["css/site.css", "img/dot.png", "index.html"])
        #expect(onDisk.first { $0.path == "img/dot.png" }?.data == Data(base64Encoded: "iVBORw0KGgo=")!)
        let copy = try parseJSON(try await store.readArtifact(artifactID: docID))
        let body = try #require(copy["markdown"] as? String)
        #expect(body.contains("Mito Landscape"))
        #expect(body.contains("Forty & one companies."))
        #expect(!body.contains("x()"))
        let artifacts = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.section == .sites)
        #expect(artifacts.first?.linkedKind == .foreverlmSite)

        // An update by id or by its library address changes only the files it
        // passes; the rest are kept from the library.
        for handle in [docID, "foreverlm-site://\(docID)/css/site.css"] {
            let updated = try parseJSON(try await store.saveSite(
                site: handle, title: nil, html: "<h1>Version two</h1>", files: nil,
                repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
            ))
            #expect(updated["status"] as? String == "updated", Comment(rawValue: handle))
            #expect(updated["site_id"] as? String == docID, Comment(rawValue: handle))
            #expect(updated["kept_files"] as? [String] == ["css/site.css", "img/dot.png"], Comment(rawValue: handle))
            #expect((updated["message"] as? String)?.contains("2 stored files were kept unchanged: css/site.css, img/dot.png") == true, Comment(rawValue: handle))
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).first?.title == "Mito Landscape", "an update without a title keeps the entry's")
        #expect((try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String)?.contains("Version two") == true)
        do {
            _ = try await store.saveSite(site: "nowhere-at-all", title: nil, html: "<h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
            Issue.record("an unknown site was updated")
        } catch {
            #expect(error.localizedDescription.contains("No site of yours is named nowhere-at-all"))
        }

        // Files from a repository: read through the injected reader, the
        // commit recorded, skipped files named; no index.html is a refusal.
        let reader: MCPDataStore.SiteRepositoryReader = { repository, path, ref in
            #expect(repository == "acme/site")
            #expect(path == "public")
            #expect(ref == "main")
            return MCPDataStore.SiteRepositoryRead(
                files: [SiteFile(path: "index.html", data: Data("<h1>From git</h1>".utf8)), SiteFile(path: "app.js", data: Data("1".utf8))],
                source: SiteRepositorySource(repository: "acme/site", ref: "main", path: "public", commit: "abc123abc123"),
                skipped: ["public/logo.png (binary)"]
            )
        }
        let fromRepo = try parseJSON(try await store.saveSite(
            site: nil, title: "Acme", html: nil, files: nil, repository: "acme/site", repositoryPath: "public", ref: "main",
            homeNotebookID: nil, notebookIDs: [], readRepository: reader
        ))
        #expect(fromRepo["status"] as? String == "saved")
        #expect((fromRepo["source"] as? [String: Any])?["commit"] as? String == "abc123abc123")
        #expect((fromRepo["skipped"] as? [String]) == ["public/logo.png (binary)"])
        #expect((fromRepo["message"] as? String)?.contains("commit abc123abc123") == true)
        do {
            _ = try await store.saveSite(
                site: nil, title: "Acme", html: "<h1>", files: nil, repository: "acme/site", repositoryPath: nil, ref: nil,
                homeNotebookID: nil, notebookIDs: [], readRepository: reader
            )
            Issue.record("files and a repository were both accepted")
        } catch {
            #expect(error.localizedDescription.contains("not both"))
        }
        let noIndex: MCPDataStore.SiteRepositoryReader = { _, _, _ in
            MCPDataStore.SiteRepositoryRead(files: [SiteFile(path: "README.md", data: Data("x".utf8))], source: SiteRepositorySource(repository: "acme/site"), skipped: [])
        }
        do {
            _ = try await store.saveSite(
                site: nil, title: "Acme", html: nil, files: nil, repository: "acme/site", repositoryPath: nil, ref: nil,
                homeNotebookID: nil, notebookIDs: [], readRepository: noIndex
            )
            Issue.record("a repository without index.html was saved")
        } catch {
            #expect(error.localizedDescription.contains("No index.html"))
        }

        // read_site_file reads the library.
        let read = try parseJSON(try await store.readSiteFile(site: docID, path: "/css/site.css"))
        #expect(read["content"] as? String == "h1{color:red}")
        #expect(read["content_type"] as? String == "text/css")

        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.isSuperset(of: ["save_site", "read_site_file", "replace_site_text"]))
        #expect(toolNames.isDisjoint(with: ["publish_site", "unpublish_site"]), "sites are not put on the web")
    }

    /// `list_source_artifacts`, the tool behind the app's Linked in menu.
    @Test("list_source_artifacts lists the Docs and animations linked to a source, and how")
    func mcpListSourceArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "paper-1", title: "The paper", content: "Body of the paper.", url: "https://doi.org/10.1000/paper-1")
        try insertSource(dbPath: dbPath, id: "other-1", title: "Other", content: "Body.", url: "https://example.com/other")
        SourceArtifactCitationCache.shared.removeAll()

        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://anim/")!, title: "The animation",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation, sourceIDs: ["paper-1"]
        )
        let citing = try await store.notebookFileStorage.createArtifact(
            title: "Citing Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "- [The paper](https://doi.org/10.1000/paper-1) — cited"
        ).artifact
        _ = try await store.notebookFileStorage.createArtifact(
            title: "Unrelated", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "Nothing linked."
        )

        let payload = try parseJSON(try await store.listSourceArtifacts(sourceID: "paper-1"))
        #expect(payload["source_id"] as? String == "paper-1")
        #expect(payload["source_title"] as? String == "The paper")
        #expect(payload["artifact_count"] as? Int == 2)
        let entries = try #require(payload["artifacts"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0["artifact_id"] as? String ?? "", $0) })
        #expect(Set(byID.keys) == [animation.id, citing.id])
        #expect(byID[animation.id]?["linked_by"] as? [String] == ["grounded"])
        #expect(byID[animation.id]?["kind"] as? String == "animation")
        #expect(byID[animation.id]?["url"] as? String == "foreverlm-site://anim/")
        #expect(byID[citing.id]?["linked_by"] as? [String] == ["cited"])
        #expect(byID[citing.id]?["kind"] as? String == "markdown")

        // By the paper's own address, and an empty answer for a source nothing links to.
        let byAddress = try parseJSON(try await store.listSourceArtifacts(sourceID: "https://doi.org/10.1000/paper-1"))
        #expect(byAddress["artifact_count"] as? Int == 2)
        let none = try parseJSON(try await store.listSourceArtifacts(sourceID: "other-1"))
        #expect(none["artifact_count"] as? Int == 0)
        #expect((none["guidance"] as? String)?.contains("Nothing links") == true)
        do {
            _ = try await store.listSourceArtifacts(sourceID: "no-such-source")
            Issue.record("an unknown source went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_sources"))
        }
    }

    /// `replace_site_text`, the tool behind the app's Change action on a
    /// selection in an open Site: the passage is found in the page's source in
    /// the library, changed in place, and saved with every other file kept; a
    /// passage the page has twice, or not at all, is refused.
    @Test("replace_site_text changes one passage of a page in the library and keeps every other file")
    func mcpReplaceSiteText() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let saved = try parseJSON(try await store.saveSite(
            site: nil, title: "Atlas",
            html: "<!doctype html><html><body><p class=\"kicker\">COMPOUNDS WITHOUT A DEVELOPER</p><h2>Real pharmacology, no one carrying it</h2><p>the atlas</p><p>the atlas</p></body></html>",
            files: [["path": "about.html", "content": "<h1>About &amp; more</h1>"], ["path": "css/site.css", "content": "h1{}"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(saved["site_id"] as? String)
        func page(_ path: String) async throws -> String {
            let data = try #require(try await store.notebookFileStorage.readLocalSiteFile(artifactID: siteID, path: path))
            return try #require(String(data: data, encoding: .utf8))
        }

        // The screenshot case: a kicker and the heading under it, two elements.
        // No account is needed: the site is the library's.
        let changed = try parseJSON(try await store.replaceSiteText(
            site: siteID, find: "COMPOUNDS WITHOUT A DEVELOPER\nReal pharmacology, no one carrying it",
            replace: "COMPOUNDS WITHOUT AN OWNER\nReal pharmacology, nobody carrying it", path: nil
        ))
        #expect(changed["status"] as? String == "changed")
        #expect(changed["path"] as? String == "index.html")
        #expect(changed["url"] as? String == "foreverlm-site://\(siteID)/")
        #expect((changed["diff"] as? String)?.hasPrefix("- COMPOUNDS WITHOUT A DEVELOPER / Real pharmacology, no one carrying it") == true)
        #expect(try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID)?.filter { !SiteSourceCards.isGenerated($0) } == ["about.html", "css/site.css", "index.html"], "every other file is kept")
        let html = try await page("index.html")
        #expect(html.contains("<p class=\"kicker\">COMPOUNDS WITHOUT AN OWNER</p><h2>Real pharmacology, nobody carrying it</h2>"))
        #expect(html.contains("<p>the atlas</p><p>the atlas</p>"), "nothing else moved")

        // Another page by its library address, with an entity in the source.
        let about = try parseJSON(try await store.replaceSiteText(
            site: siteID, find: "About & more", replace: "About & less", path: "foreverlm-site://\(siteID)/about.html"
        ))
        #expect(about["path"] as? String == "about.html")
        #expect(about["url"] as? String == "foreverlm-site://\(siteID)/about.html")
        #expect(try await page("about.html") == "<h1>About &amp; less</h1>")

        // Twice on the page: refused with the count; absent: refused; a missing file: refused.
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "the atlas", replace: "an atlas", path: nil)
            Issue.record("an ambiguous passage went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("appears 2 times"))
        }
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "Not on the page", replace: "x", path: nil)
            Issue.record("an absent passage went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("not found in the page's source"))
        }
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "the atlas", replace: "x", path: "missing.html")
            Issue.record("a missing file went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("has no file missing.html"))
        }

    }

    @Test("An update carries only the files that change: stored files are kept, remove_files drops, replace_all replaces, and read_site_file without a path lists the files")
    func mcpSaveSitePartialUpdate() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let first = try parseJSON(try await store.saveSite(
            site: nil, title: "Mitochondrial Therapeutics Atlas", html: "<h1>Atlas</h1>",
            files: [["path": "interventions.html", "content": "<table></table>"], ["path": "css/site.css", "content": "h1{}"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(first["site_id"] as? String)
        func paths() async throws -> [String] {
            (try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID) ?? []).filter { !SiteSourceCards.isGenerated($0) }
        }

        // One page changes; the others are kept from the library.
        let updated = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: nil,
            files: [["path": "interventions.html", "content": "<table><tr><td>Elamipretide</td></tr></table>"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["css/site.css", "index.html", "interventions.html"])
        #expect(updated["kept_files"] as? [String] == ["css/site.css", "index.html"])
        #expect(updated["title"] as? String == "Mitochondrial Therapeutics Atlas")
        let message = try #require(updated["message"] as? String)
        #expect(message.contains("2 stored files were kept unchanged: css/site.css, index.html"))
        #expect(message.contains("only the files that change"))

        // remove_files drops a stored file; a file both passed and removed is
        // refused, and so is removing the entry page without passing one.
        let removed = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: nil, files: [["path": "about.html", "content": "<p>About</p>"]],
            repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["/css/site.css"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["about.html", "index.html", "interventions.html"])
        #expect(removed["removed_files"] as? [String] == ["css/site.css"])
        #expect((removed["message"] as? String)?.contains("Removed: css/site.css.") == true)
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: "<h1>New</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["index.html"], homeNotebookID: nil, notebookIDs: [])
            Issue.record("a file both passed and removed was accepted")
        } catch {
            #expect(error.localizedDescription.contains("do one or the other"))
        }
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "x.css", "content": "p{}"]], repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["index.html"], homeNotebookID: nil, notebookIDs: [])
            Issue.record("a site without index.html was saved")
        } catch {
            #expect(error.localizedDescription.contains("would have no index.html"))
        }

        // replace_all: the passed files are the whole site.
        let replaced = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: "<h1>Fresh</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil,
            replaceAll: true, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["index.html"])
        #expect(replaced["kept_files"] == nil)
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "a.css", "content": "p{}"]], repository: nil, repositoryPath: nil, ref: nil, replaceAll: true, homeNotebookID: nil, notebookIDs: [])
            Issue.record("replace_all without index.html was accepted")
        } catch {
            #expect(error.localizedDescription.contains("needs an index.html"))
        }

        // A new site needs a title.
        do {
            _ = try await store.saveSite(site: nil, title: nil, html: "<h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
            Issue.record("a new site without a title was accepted")
        } catch {
            #expect(error.localizedDescription.contains("title is required"))
        }

        // read_site_file without a path lists the files — not ForeverLM's own.
        _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "pages/two.html", "content": "<p>Two</p>"]], repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
        let listing = try parseJSON(try await store.readSiteFile(site: siteID, path: nil))
        #expect(listing["file_paths"] as? [String] == ["index.html", "pages/two.html"])
        #expect(listing["files"] as? Int == 2)
        #expect(listing["site"] as? String == siteID)
        #expect((listing["message"] as? String)?.contains("only the files that change") == true)
        do {
            _ = try await store.readSiteFile(site: "gone", path: "  ")
            Issue.record("a site the library does not hold was listed")
        } catch {
            #expect(error.localizedDescription.contains("No site or animation of yours is named gone"))
        }
    }

    @Test("save_site draws the library's banner cards: each linked source's thumbnail and one card script join the files, every page loads it once, a source linked by its web address gets the same card, and a copy passed back is remade")
    func mcpSaveSiteSourceCards() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()

        // A paper with its PDF on disk: the first page is the picture the
        // Sources row draws, and the metadata line is author · venue · year.
        let pdfURL = URL(fileURLWithPath: tmpPath).appendingPathComponent("levin.pdf")
        let page = NSImage(size: NSSize(width: 120, height: 160), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        let pdf = PDFDocument()
        pdf.insert(try #require(PDFPage(image: page)), at: 0)
        #expect(pdf.write(to: pdfURL))
        var paper = StudioArticle(
            url: "https://www.mdpi.com/2409-9287/11/1/1", title: "Ingressing Minds", sourceType: .paper,
            localFilePath: pdfURL.path, author: "Michael Levin", journal: "Philosophies", publishedYear: "2026", id: "src-levin-1"
        )
        paper.content = "Patterns in form."
        paper.wordCount = 3
        // Metadata attested, cleanup still queued: the card does not need a
        // finished import, only a source the library holds.
        let attested = paper.attestPaperMetadataExtractionAfterLLM()
        #expect(attested)
        try kstore.saveSource(paper)
        // A post with no file and no artwork: a card with the family glyph that opens its address.
        try Self.seedReadySource(kstore, id: "src-post-1", url: "https://example.com/post", title: "A post", sourceType: .article)


        let html = """
        <!doctype html><html><head><title>Crosswalk</title></head><body>
        <table><tr><td><a href="foreverlm://source/src-levin-1">Ingressing Minds</a></td><td>Primary</td></tr>
        <tr><td><a href="foreverlm://source/src-post-1">A post</a></td><td>Supporting</td></tr>
        <tr><td><a href="foreverlm://source/nope">Missing</a></td><td>Predicted</td></tr></table>
        <p>An inline <a href="foreverlm://source/src-levin-1">citation</a> stays a link.</p>
        <nav><a href="https://example.com/post">Post (menu)</a></nav>
        <p><a href="http://mdpi.com/2409-9287/11/1/1/">Ingressing Minds, by its address</a></p>
        <ul><li><a href='https://example.com/post'>A post, by address</a></li>
        <li><a href="https://example.com/elsewhere">Not in the library</a></li>
        <li><a href="pages/two.html">Own page</a></li></ul>
        </body></html>
        """
        // The cards are drawn at the save.
        let result = try parseJSON(try await store.saveSite(
            site: nil, title: "Crosswalk", html: html,
            files: [
                ["path": "pages/two.html", "content": "<p><a href=\"foreverlm://source/src-levin-1\">Again</a></p>"],
                ["path": "pages/plain.html", "content": "<p>No sources here.</p>"],
                // A stale copy of ForeverLM's own files, as a model passes read_site_file output back.
                ["path": "foreverlm/thumbnails/stale.jpg", "content_base64": "/9j/AAAA"],
                ["path": "foreverlm/source-cards.js", "content": "// old"],
            ],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(result["source_cards"] as? Int == 2)
        #expect(result["unresolved_sources"] as? [String] == ["nope"], "an address the library does not hold is a link, not a missing source")
        // The web addresses the library answered to, as the pages wrote them:
        // the paper under a spelling that only normalizes to its saved address,
        // the post under its own. The site's own page and an unknown address
        // are not sources.
        #expect(result["linked_addresses"] as? [String] == ["https://example.com/post", "http://mdpi.com/2409-9287/11/1/1/"])
        #expect((result["message"] as? String)?.contains("2 of the pages' web links point at a library source") == true)
        #expect((result["message"] as? String)?.contains("2 library sources are drawn as the app's banner card") == true)
        #expect((result["message"] as? String)?.contains("No library source answers to nope") == true)
        let siteID = try #require(result["site_id"] as? String)

        // The library keeps the pages, the picture and the card script.
        let kept = try #require(try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID))
        #expect(kept == ["foreverlm/source-cards.js", "foreverlm/thumbnails/src-levin-1.jpg", "index.html", "pages/plain.html", "pages/two.html"])
        let savedFiles = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: siteID))
        let byPath = Dictionary(uniqueKeysWithValues: savedFiles.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == Set(kept))
        let index = try #require(byPath["index.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        let tag = "<script defer src=\"foreverlm/source-cards.js\" data-foreverlm-source-cards></script>"
        #expect(index.components(separatedBy: tag).count == 2, "the entry page loads the card script once")
        #expect(index.contains(tag + "\n</head>"), "before </head>")
        #expect(index.contains("href=\"foreverlm://source/src-levin-1\""), "the links themselves are left for the script")
        let two = try #require(byPath["pages/two.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(two.contains("<script defer src=\"../foreverlm/source-cards.js\" data-foreverlm-source-cards></script>"), "a page in a folder reaches the script relatively")
        #expect(two.hasPrefix("<p>"), "a page without a head or body gets the tag at its end")
        let plain = try #require(byPath["pages/plain.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(plain == "<p>No sources here.</p>", "a page that links no source is untouched")
        let jpeg = try #require(byPath["foreverlm/thumbnails/src-levin-1.jpg"]).data
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]), "the thumbnail is a JPEG rendered from the PDF's first page")
        #expect(jpeg.count > 200)
        let script = try #require(byPath["foreverlm/source-cards.js"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(script.contains("\"src-levin-1\":{"))
        #expect(script.contains("\"subtitle\":\"Michael Levin · Philosophies · 2026\""))
        #expect(script.contains("\"thumbnail\":\"foreverlm/thumbnails/src-levin-1.jpg\""))
        #expect(script.contains("\"url\":\"https://www.mdpi.com/2409-9287/11/1/1\""))
        #expect(script.contains("\"src-post-1\":{"))
        #expect(script.contains("\"glyph\":\"A\""))
        #expect(script.contains("\"url\":\"https://example.com/post\""))
        #expect(!script.contains("\"nope\""))
        // A card found by address is keyed by the address and opens it — the
        // author's spelling, not the library's public page — with the same
        // picture as the card found by id.
        #expect(script.contains("\"http://mdpi.com/2409-9287/11/1/1/\":{"))
        #expect(script.contains("\"https://example.com/post\":{"))
        #expect(!script.contains("elsewhere"))
        let addressCard = try #require(script.range(of: "\"http://mdpi.com/2409-9287/11/1/1/\":{").map { script[$0.upperBound...] }.map { String($0.prefix(while: { $0 != "}" })) })
        #expect(addressCard.contains("\"url\":\"http://mdpi.com/2409-9287/11/1/1/\""))
        #expect(addressCard.contains("\"thumbnail\":\"foreverlm/thumbnails/src-levin-1.jpg\""))
        #expect(script.contains("scheme === 'http:' || scheme === 'https:'"), "the served script draws a card for a linked address too")
        #expect(script.contains("closest('nav, header, footer')"), "but never inside the page's navigation")
        #expect(script.contains("messageHandlers.linkedPageSourceLinks"), "in the app the script yields to the app's own card")
        #expect(script.contains(SiteSourceCards.cardStyle.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)))
        #expect(!script.contains("__FOREVERLM_"))

        // The saved files passed back as the next save: one tag per page,
        // one picture per source, the script remade — nothing doubles.
        let passedBack: [Any] = savedFiles.map { file -> [String: Any] in
            var entry: [String: Any] = ["path": file.path]
            if let text = String(data: file.data, encoding: .utf8), !SiteFile.looksBinary(file.data) {
                entry["content"] = text
            } else {
                entry["content_base64"] = file.data.base64EncodedString()
            }
            return entry
        }
        _ = try await store.saveSite(
            site: siteID, title: nil, html: nil, files: passedBack,
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        )
        let again = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: siteID))
        #expect(Set(again.map(\.path)) == Set(byPath.keys))
        let indexAgain = try #require(again.first { $0.path == "index.html" }.flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(indexAgain.components(separatedBy: "data-foreverlm-source-cards").count == 2)
        #expect(indexAgain == index)

        // The pure pieces: link tokens, and the tag's placement.
        #expect(SiteSourceCards.tokens(inHTML: "<a href='foreverlm://source/a%2Db?t=4'>x</a> <a href=\"FOREVERLM://source/c#frag\">y</a> <a href=\"foreverlm://source/a-b\">z</a>") == ["a-b", "c"])
        #expect(SiteSourceCards.tokens(inHTML: "<a href=\"foreverlm://grounding/a\">x</a>") == [])
        // Web addresses: absolute http(s) hrefs as the browser reads them, once
        // each; the site's own pages and source tokens are not addresses.
        #expect(SiteSourceCards.webAddresses(inHTML: "<a href=\"https://a.com/x?y=1&amp;z=2\">x</a> <A HREF = 'HTTP://b.com/'>y</A> <a href=\"pages/two.html\">z</a> <a href=\"foreverlm://source/q\">q</a> <a class=\"k\"\n href=\"https://a.com/x?y=1&amp;z=2\">again</a> <a name=\"anchor\">no href</a>") == ["https://a.com/x?y=1&z=2", "HTTP://b.com/"])
        #expect(SiteSourceCards.injectingScript(into: "<h1>Hi</h1>", path: "a/b/c.html") == "<h1>Hi</h1>\n<script defer src=\"../../foreverlm/source-cards.js\" data-foreverlm-source-cards></script>\n")
        #expect(SiteSourceCards.injectingScript(into: "<html><body><p>x</p>\n</body></html>", path: "index.html") == "<html><body><p>x</p>\n<script defer src=\"foreverlm/source-cards.js\" data-foreverlm-source-cards></script>\n</body></html>")
        #expect(SiteSourceCards.thumbnailPath(forSourceID: "--src/α:1", taken: ["foreverlm/thumbnails/src---1.jpg"]) == "foreverlm/thumbnails/src---1-2.jpg")
        #expect(SiteSourceCards.isGenerated("FOREVERLM/Thumbnails/x.jpg"))
        #expect(!SiteSourceCards.isGenerated("foreverlm/logo.png"))

        func lookup(_ token: String) -> SiteSourceCards.Lookup? {
            let card = SiteSourceCards.Card(sourceID: token, title: token.uppercased(), subtitle: "Paper", kind: "paper", glyph: "P", url: "https://x/\(token)")
            return token == "a" ? .init(card: card, thumbnailJPEG: nil) : nil
        }

        // Addresses are asked together, once each; a match is a card that opens
        // the address the author wrote, and a miss is a link and nothing more.
        var addressed = [SiteFile(path: "index.html", data: Data("<p><a href=\"https://doi.org/10.1/x\">X</a></p><nav><a href=\"https://doi.org/10.1/x\">X</a></nav><p><a href=\"https://nowhere.example/\">N</a></p>".utf8))]
        let addressedAttachment = await SiteSourceCards.attach(to: &addressed, lookup: { _ in nil }, lookupAddresses: { addresses in
            #expect(addresses == ["https://doi.org/10.1/x", "https://nowhere.example/"])
            return ["https://doi.org/10.1/x": lookup("a")!]
        })
        #expect(addressedAttachment.addresses == ["https://doi.org/10.1/x"])
        #expect(addressedAttachment.unresolved.isEmpty)
        #expect(addressedAttachment.cards["https://doi.org/10.1/x"]?.url == "https://doi.org/10.1/x", "the card opens what the author linked, not the library's public page")
        #expect(addressedAttachment.cards["https://doi.org/10.1/x"]?.sourceID == "a")
        #expect(addressed.map(\.path) == ["index.html", SiteSourceCards.scriptPath])
        var unmatched = [SiteFile(path: "index.html", data: Data("<p><a href=\"https://nowhere.example/\">N</a></p>".utf8))]
        let unmatchedAttachment = await SiteSourceCards.attach(to: &unmatched, lookup: { _ in nil }, lookupAddresses: { _ in [:] })
        #expect(unmatchedAttachment == SiteSourceCards.Attachment())
        #expect(unmatched.map(\.path) == ["index.html"], "a site whose links are all ordinary is untouched")
    }

    @Test("adopt_page makes a linked Codex site ForeverLM's own published page, never reaching foreverlm.com in tests")
    func mcpAdoptPage() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let site = try parseJSON(try await store.linkPageArtifact(
            urlString: "mitochondrial-therapeutics-atlas.learner-1234.chatgpt.site",
            title: "Mitochondrial Therapeutics — Company Landscape", homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require((site["doc"] as? [String: Any])?["id"] as? String)
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: siteID, text: "MITO / LANDSCAPE\n\nCompanies."
        )

        actor Recorder {
            var calls: [(title: String, markdown: String, access: DocPageAccess, slug: String?)] = []
            func record(_ title: String, _ markdown: String, _ access: DocPageAccess, _ slug: String?) {
                calls.append((title, markdown, access, slug))
            }
        }
        let recorder = Recorder()
        let stub: @Sendable (String, String, String, DocPageAccess, String?) async throws -> PublishedDocStatus = { docID, title, markdown, access, slug in
            await recorder.record(title, markdown, access, slug)
            let address = slug ?? "abc123def456"
            return PublishedDocStatus(
                docID: docID, url: URL(string: "https://foreverlm.com/share/\(address)")!, slug: address,
                title: title, publishedAt: Date(), updatedAt: Date(), isProtected: !(access == .keep || access == .open),
                password: nil
            )
        }

        // Signed out: refused before anything changes.
        do {
            _ = try await store.adoptPageArtifact(artifactID: siteID, markdown: nil, readers: nil, slug: nil, isSignedIn: false, publish: stub)
            Issue.record("adopt_page ran signed out")
        } catch {
            #expect(error.localizedDescription.contains("Sign in with Apple"))
            #expect(error.localizedDescription.contains("still a linked Codex Site"))
        }
        let stillLinked = try parseJSON(try await store.readArtifact(artifactID: siteID))
        #expect(stillLinked["kind"] as? String == "codex_site")
        #expect(stillLinked["read_only"] as? Bool == true)
        #expect(await recorder.calls.isEmpty)

        // A Markdown Doc is not a page to adopt.
        let own = try parseJSON(try await store.createArtifact(title: "Own", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine"))
        let ownID = try #require((own["doc"] as? [String: Any])?["id"] as? String)
        do {
            _ = try await store.adoptPageArtifact(artifactID: ownID, markdown: nil, readers: nil, slug: nil, isSignedIn: true, publish: stub)
            Issue.record("adopt_page accepted a Markdown Doc")
        } catch {
            #expect(error.localizedDescription.contains("already a ForeverLM Doc"))
        }
        #expect(await recorder.calls.isEmpty)

        // Signed in, with the site's real Markdown: unlinked, rewritten, published.
        let markdown = "# Mitochondrial therapeutics\n\n## Landscape\n\n- Pharming"
        let adopted = try parseJSON(try await store.adoptPageArtifact(
            artifactID: siteID, markdown: markdown, readers: ["robin@example.com"], slug: "mito-landscape",
            isSignedIn: true, publish: stub
        ))
        #expect(adopted["status"] as? String == "adopted")
        #expect(adopted["url"] as? String == "https://foreverlm.com/share/mito-landscape")
        #expect(adopted["body"] as? String == "markdown")
        #expect(adopted["source_kind"] as? String == "codex_site")
        #expect(adopted["source_url"] as? String == "https://mitochondrial-therapeutics-atlas.learner-1234.chatgpt.site/")
        #expect(adopted["restricted"] as? Bool == true)
        #expect((adopted["message"] as? String)?.contains("edit_doc") == true)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.title == "Mitochondrial Therapeutics — Company Landscape")
        #expect(calls.first?.markdown == markdown)
        #expect(calls.first?.access == .readers(["robin@example.com"]))
        #expect(calls.first?.slug == "mito-landscape")
        let read = try parseJSON(try await store.readArtifact(artifactID: siteID))
        #expect(read["linked_url"] == nil)
        #expect((read["read_only"] as? Bool) != true)
        #expect(read["markdown"] as? String == markdown)
        #expect(read["revision"] as? String == adopted["revision"] as? String)

        // Without markdown the text copy is the body, and adopting twice is refused: it is a Doc now.
        let second = try parseJSON(try await store.linkPageArtifact(
            urlString: "claude.ai/code/artifact/A1B2C3D4-1E2F-4A5B-8C6D-7E8F9A0B1C2D",
            title: "Atlas", homeNotebookID: nil, notebookIDs: []
        ))
        let secondID = try #require((second["doc"] as? [String: Any])?["id"] as? String)
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(artifactID: secondID, text: "# Atlas\n\nCopy.")
        let adoptedCopy = try parseJSON(try await store.adoptPageArtifact(artifactID: secondID, markdown: "  ", readers: nil, slug: nil, isSignedIn: true, publish: stub))
        #expect(adoptedCopy["body"] as? String == "text_copy")
        #expect(adoptedCopy["source_kind"] as? String == "claude_artifact")
        #expect(await recorder.calls.last?.markdown == "# Atlas\n\nCopy.")
        #expect(await recorder.calls.last?.access == .keep)
        await #expect(throws: (any Error).self) {
            _ = try await store.adoptPageArtifact(artifactID: secondID, markdown: nil, readers: nil, slug: nil, isSignedIn: true, publish: stub)
        }
        // The tool is on the server's list.
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("adopt_page"))
    }

    @Test("A doc converted to a Google Doc reads as google_doc and read-only through the doc tools")
    func mcpConvertedDocIsReadOnly() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Own words", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine\n\nKept."
        ))
        let createdDoc = try #require(created["doc"] as? [String: Any])
        let docID = try #require(createdDoc["id"] as? String)
        #expect(createdDoc["kind"] as? String == "markdown")

        // What the conversion does once Drive has the copy: the doc becomes
        // a linked doc, the Markdown staying as its body.
        _ = try await store.notebookFileStorage.linkArtifactToGoogleDoc(
            artifactID: docID,
            url: LinkedGoogleDoc.editURL(documentID: "1Conv")
        )

        let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let docs = try #require(listing["docs"] as? [[String: Any]])
        let listed = try #require(docs.first { $0["id"] as? String == docID })
        #expect(listed["kind"] as? String == "google_doc")
        #expect(listed["read_only"] as? Bool == true)
        #expect(listed["linked_url"] as? String == "https://docs.google.com/document/d/1Conv/edit")

        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# Mine\n\nKept.")
        #expect(read["read_only"] as? Bool == true)
        #expect(read["linked_url"] as? String == "https://docs.google.com/document/d/1Conv/edit")
        #expect((read["guidance"] as? String)?.contains("Google Doc") == true)
        let revision = try #require(read["revision"] as? String)
        // Refused with the route: edit it in Google Docs, refresh the copy with
        // link_page, or unlink it into a Doc of ForeverLM's own.
        do {
            _ = try await store.writeArtifact(
                artifactID: docID,
                markdown: "# Rewritten",
                expectedRevision: revision
            )
            Issue.record("write_doc accepted a linked Google Doc")
        } catch {
            #expect(error.localizedDescription.contains("Google Docs"))
            #expect(error.localizedDescription.contains("unlink_page"))
        }

        // Unlinked, it is an ordinary doc again and the tools may write it.
        _ = try await store.notebookFileStorage.unlinkArtifact(artifactID: docID)
        let restored = try parseJSON(try await store.readArtifact(artifactID: docID))
        let restoredDoc = try #require(restored["doc"] as? [String: Any])
        #expect(restoredDoc["kind"] as? String == "markdown")
        #expect(restoredDoc["read_only"] as? Bool == false)
        #expect(restored["read_only"] == nil)
        let restoredRevision = try #require(restored["revision"] as? String)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: docID,
            markdown: "# Mine\n\nRevised.",
            expectedRevision: restoredRevision
        ))
        #expect((saved["revision"] as? String) != restoredRevision)
    }

    @Test("edit_doc changes passages of a Doc in place without carrying its body")
    func mcpEditDocReplacesPassagesInPlace() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "TechBio report",
            homeNotebookID: nil,
            notebookIDs: [],
            markdown: "# TechBio\n\n## Thesis\n\nOld thesis.\n\n## Companies\n\nAlpha and Beta.\n"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(created["revision"] as? String)

        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [
                .init(find: "Old thesis.", replace: "Measurement-led thesis."),
                .init(find: "Alpha and Beta.", replace: "Alpha, Beta and Gamma."),
            ],
            append: "## Open questions\n\n- Which assays predict clinical benefit?\n",
            expectedRevision: revision
        ))
        #expect(edited["replacements"] as? Int == 2)
        #expect(edited["appended"] as? Bool == true)
        let newRevision = try #require(edited["revision"] as? String)
        #expect(newRevision != revision)
        // The result carries no body — that is the point of the tool.
        #expect(edited["markdown"] == nil)

        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# TechBio\n\n## Thesis\n\nMeasurement-led thesis.\n\n## Companies\n\nAlpha, Beta and Gamma.\n\n## Open questions\n\n- Which assays predict clinical benefit?\n")
        #expect(read["revision"] as? String == newRevision)

        // A stale revision whose find still matches once is no refusal: the
        // edit names its own text (edit_doc applies to the newer body). The
        // rest of this test keeps to the current revision.
        #expect(edited["doc_changed_meanwhile"] == nil)
        // A find that matches nowhere, or in several places, changes nothing
        // and names the edit — a wrong guess at whitespace must not silently
        // rewrite something else.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [.init(find: "Old thesis.", replace: "x")],
                append: nil,
                expectedRevision: newRevision
            )
            Issue.record("a missing find was applied")
        } catch {
            #expect(error.localizedDescription.contains("edits[0] found no match"))
        }
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [
                    .init(find: "Alpha", replace: "Omega"),
                    .init(find: "##", replace: "#"),
                ],
                append: nil,
                expectedRevision: newRevision
            )
            Issue.record("an ambiguous find was applied")
        } catch {
            #expect(error.localizedDescription.contains("edits[1] matches 3 places"))
        }
        let unchanged = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(unchanged["revision"] as? String == newRevision)
        #expect((unchanged["markdown"] as? String)?.contains("Alpha, Beta and Gamma.") == true)

        // replace_all lifts the single-match rule on purpose.
        let headings = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [.init(find: "## ", replace: "### ", replaceAll: true)],
            append: nil,
            expectedRevision: newRevision
        ))
        #expect(headings["replacements"] as? Int == 3)
        let reread = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect((reread["markdown"] as? String)?.contains("### Companies") == true)

        // No edits and no append is a caller mistake, not an empty success.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [],
                append: nil,
                expectedRevision: try #require(headings["revision"] as? String)
            )
            Issue.record("an empty edit was accepted")
        } catch {
            #expect(error.localizedDescription.contains("at least one"))
        }
    }

    @Test("edit_doc lands on a Doc the learner is typing in, and refuses only an edit whose own passage changed")
    func mcpEditDocAppliesToTheNewerBody() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Engineered human resilience",
            homeNotebookID: nil,
            notebookIDs: [],
            markdown: "# Resilience\n\n## Summary\n\nOld summary.\n\n## Mitochondria\n\nOld mitochondria.\n"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let read = try #require(created["revision"] as? String)

        // 2026-09-29: the learner drafts the next paragraph in the editor,
        // which saves as they type, while the chat rewrites the Summary from
        // the revision it read. The edit goes onto the newer body and the
        // learner's draft stays.
        let typed = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: docID,
            markdown: "# Resilience\n\n## Summary\n\nOld summary.\n\n## Mitochondria\n\nMy own draft of this.\n",
            expectedRevision: read
        )
        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [.init(find: "Old summary.", replace: "New summary.")],
            append: nil,
            expectedRevision: read
        ))
        #expect(edited["replacements"] as? Int == 1)
        #expect(edited["doc_changed_meanwhile"] as? Bool == true)
        #expect((edited["doc_changed_guidance"] as? String)?.contains("read_doc") == true)
        let afterEdit = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(afterEdit["markdown"] as? String
            == "# Resilience\n\n## Summary\n\nNew summary.\n\n## Mitochondria\n\nMy own draft of this.\n")
        #expect(afterEdit["revision"] as? String == edited["revision"] as? String)
        #expect(edited["revision"] as? String != typed.revision)

        // An edit of the passage the learner rewrote is refused, says why, and
        // changes nothing.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [.init(find: "Old mitochondria.", replace: "Chat's mitochondria.")],
                append: nil,
                expectedRevision: read
            )
            Issue.record("an edit of a passage changed since it was read was applied")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("changed after you read it"))
            #expect(message.contains("edits[0] found no match"))
            #expect(!message.contains("Reload it"))
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String
            == edited["revision"] as? String)

        // write_doc replaces the whole body, so a stale revision still refuses,
        // in words that point at edit_doc, and nothing is saved.
        do {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "# Resilience\n\nGone.", expectedRevision: read)
            Issue.record("write_doc overwrote a newer body")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Nothing was saved"))
            #expect(message.contains("edit_doc"))
        }
        #expect((try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String)?
            .contains("My own draft of this.") == true)
    }

    @Test("MCP can archive and restore a Notebook without deleting its context")
    func mcpNotebookArchiveIsNonDestructive() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "archive-source",
            title: "Context that must survive",
            content: "Preserved source content."
        )
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Archive me",
            topic: "archiving",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["archive-source"]
        )

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil,
            status: LearningGoalStatus.archived.rawValue
        )

        let archived = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(archived.isArchived)
        #expect(archived.approvedSourceIDs == ["archive-source"])
        #expect(!((try store.listNotebooks(includeCompleted: false)).contains("Archive me")))
        let archivedListing = try parseJSON(try store.listNotebooks(includeCompleted: true))
        let archivedHeadlines = try #require(archivedListing["goals"] as? [[String: Any]])
        #expect(archivedHeadlines.contains {
            $0["id"] as? String == notebook.id && $0["status"] as? String == "archived"
        })

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil,
            status: LearningGoalStatus.active.rawValue
        )

        let restored = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(restored.lifecycleStatus == .active)
        #expect(restored.approvedSourceIDs == ["archive-source"])
        #expect((try store.listNotebooks(includeCompleted: false)).contains("Archive me"))
    }

    @Test("update_notebook summary sets, reports, and clears the card description")
    func updateNotebookSummary() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "GDF15",
            description: "Cite the assay used.",
            topic: "GDF15",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            summary: "A stress hormone and its receptor",
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        let updated = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(updated.summary == "A stress hormone and its receptor")
        // Instructions are a different field and stay put.
        #expect(updated.description == "Cite the assay used.")

        let detail = try parseJSON(try store.getNotebookDetail(notebookID: notebook.id))
        #expect(detail["summary"] as? String == "A stress hormone and its receptor")
        #expect(detail["instructions"] as? String == "Cite the assay used.")

        // Omitted keeps it; "" clears it.
        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: "GDF15 biology",
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        #expect(try #require(try knowledge.loadLearningGoal(notebook.id)).summary == "A stress hormone and its receptor")

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            summary: "",
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        let cleared = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(cleared.summary == nil)
        #expect(try parseJSON(try store.getNotebookDetail(notebookID: notebook.id))["summary"] == nil)
    }

    /// The Goals tab's Delete over MCP (product owner, 2026-09-19: "please give me a
    /// way to delete goals also"): the Goal goes, a Notebook is refused.
    @Test("delete_learning_goal removes a Goal, refuses a Notebook, and names a missing id")
    func deleteLearningGoalOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Understand the method", description: nil, topic: "method",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )

        let deleted = try parseJSON(try store.deleteLearningGoal(goalID: goal.id))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["goal_id"] as? String == goal.id)
        #expect(try knowledge.loadLearningGoal(goal.id) == nil)
        #expect(try knowledge.loadLearningGoal(notebook.id) != nil, "the Notebook it was tagged to stays")

        do {
            _ = try store.deleteLearningGoal(goalID: notebook.id)
            Issue.record("a Notebook went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("delete_notebook"))
        }
        #expect(try knowledge.loadLearningGoal(notebook.id) != nil)
        do {
            _ = try store.deleteLearningGoal(goalID: goal.id)
            Issue.record("a deleted Goal went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_goals"))
        }
    }

    // MARK: - Skills (docs/chat-design.md, "Skills")

    /// Skills over MCP: write one from a SKILL.md, read it back by
    /// name, rename it, refuse a taken or built-in name, and delete it.
    @Test("The skill tools write from a SKILL.md, read by name, refuse a taken name and delete")
    func skillToolsOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        for name in ["list_skills", "get_skill", "save_skill", "delete_skill"] {
            #expect(MCPToolRegistry.shared.tools.contains { $0.name == name }, "\(name) is not registered")
        }

        let empty = try parseJSON(try store.listSkills())
        #expect(empty["count"] as? Int == 0)

        let created = try parseJSON(try store.saveSkill(
            skillID: nil, name: nil, description: nil, instructions: nil,
            skillMarkdown: """
            ---
            name: Paper Walkthrough
            description: >
              Walk through a paper one point at a time,
              with recall questions after the points they test.
            ---

            # Walkthrough

            Read the whole paper before the first card.
            """
        ))
        #expect(created["status"] as? String == "created")
        #expect(created["name"] as? String == "paper-walkthrough", "the name becomes a / command")
        let skillID = try #require(created["skill_id"] as? String)

        let read = try parseJSON(try store.getSkill(name: "/paper-walkthrough", skillID: nil))
        #expect(read["skill_id"] as? String == skillID)
        #expect(read["description"] as? String == "Walk through a paper one point at a time, with recall questions after the points they test.")
        #expect(read["instructions"] as? String == "# Walkthrough\n\nRead the whole paper before the first card.")
        #expect((read["skill_markdown"] as? String)?.hasPrefix("---\nname: paper-walkthrough\n") == true)

        do {
            _ = try store.saveSkill(skillID: nil, name: "paper walkthrough", description: "Another", instructions: "Body", skillMarkdown: nil)
            Issue.record("a second skill took a name already held")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("/paper-walkthrough"))
        }
        do {
            _ = try store.saveSkill(skillID: nil, name: "plan", description: "Mine", instructions: "Body", skillMarkdown: nil)
            Issue.record("a skill took a built-in command's name")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("ForeverLM's own commands"))
        }

        let renamed = try parseJSON(try store.saveSkill(
            skillID: skillID, name: "walk", description: nil, instructions: nil, skillMarkdown: nil
        ))
        #expect(renamed["status"] as? String == "updated")
        #expect(try knowledge.loadSkill(skillID)?.name == "walk")
        #expect(try knowledge.loadSkill(skillID)?.instructions == "# Walkthrough\n\nRead the whole paper before the first card.", "a field not passed is kept")

        let listed = try parseJSON(try store.listSkills())
        let rows = try #require(listed["skills"] as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["walk"])
        #expect(rows[0]["instructions"] == nil, "the list carries no instructions")

        let deleted = try parseJSON(try store.deleteSkill(skillID: skillID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(try knowledge.loadSkills().isEmpty)
        do {
            _ = try store.getSkill(name: "walk", skillID: nil)
            Issue.record("a deleted skill was still found")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_skills"))
        }
    }

    // MARK: - Ideas (docs/ideas-design.md)

    /// The Ideas tab over MCP: jot one down, link what it draws on, read it
    /// back with the links resolved, and put it away rather than lose it.
    @Test("The Ideas tools jot, link, list, archive and delete, and refuse a link to nothing")
    func ideaToolsOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        for name in ["list_ideas", "create_idea", "update_idea", "link_idea", "unlink_idea", "delete_idea"] {
            #expect(MCPToolRegistry.shared.tools.contains { $0.name == name }, "\(name) is not registered")
        }

        try Self.seedReadySource(
            knowledge, id: "idea-source", url: "https://example.com/idea-source",
            title: "Mitochondrial origins of the pressure to sleep", sourceType: .article
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Write the sleep-pressure piece", description: nil, topic: "sleep pressure",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        let created = try parseJSON(try store.createIdea(
            title: "  Field effects might explain\n  the sleep pressure curve  ",
            notes: "Worth a look before the piece.",
            links: [["kind": "source", "target_id": "idea-source"]]
        ))
        #expect(created["status"] as? String == "created")
        #expect(created["title"] as? String == "Field effects might explain the sleep pressure curve", "the words are kept, collapsed to one line")
        #expect(created["linked"] as? Int == 1)
        let ideaID = try #require(created["idea_id"] as? String)

        let linked = try parseJSON(try store.linkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(linked["added"] as? Int == 1)
        let repeated = try parseJSON(try store.linkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(repeated["added"] as? Int == 0 && repeated["already_linked"] as? Int == 1)

        let listed = try parseJSON(try store.listIdeas(includeArchived: true))
        let rows = try #require(listed["ideas"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["notes"] as? String == "Worth a look before the piece.")
        let links = try #require(rows[0]["links"] as? [[String: Any]])
        #expect(links.count == 2)
        let sourceLink = try #require(links.first { $0["kind"] as? String == "source" })
        #expect(sourceLink["title"] as? String == "Mitochondrial origins of the pressure to sleep", "a link reads as what it points at")
        let goalLink = try #require(links.first { $0["kind"] as? String == "goal" })
        #expect(goalLink["title"] as? String == "Write the sleep-pressure piece")

        do {
            _ = try store.linkIdea(ideaID: ideaID, kindString: "source", targetIDs: ["no-such-source"])
            Issue.record("a link to nothing went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("no-such-source"))
        }
        do {
            _ = try store.linkIdea(ideaID: ideaID, kindString: "sculpture", targetIDs: ["idea-source"])
            Issue.record("an unknown kind went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("kind must be one of"))
        }
        #expect(try #require(try knowledge.loadIdea(ideaID)).links.count == 2, "a refused link writes nothing")

        let unlinked = try parseJSON(try store.unlinkIdea(ideaID: ideaID, kindString: "goal", targetIDs: [goal.id]))
        #expect(unlinked["removed"] as? Int == 1 && unlinked["links"] as? Int == 1)

        let archived = try parseJSON(try store.updateIdea(ideaID: ideaID, title: nil, notes: "", statusString: "archived"))
        #expect(archived["idea_status"] as? String == "archived")
        #expect(archived["has_notes"] as? Bool == false, "an empty note clears it")
        let openOnly = try parseJSON(try store.listIdeas(includeArchived: false))
        #expect((openOnly["ideas"] as? [[String: Any]])?.isEmpty == true)
        do {
            _ = try store.updateIdea(ideaID: ideaID, title: "   ", notes: nil, statusString: nil)
            Issue.record("an Idea was left without words")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("delete_idea"))
        }

        let deleted = try parseJSON(try store.deleteIdea(ideaID: ideaID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["links_dropped"] as? Int == 1)
        #expect(try knowledge.loadIdea(ideaID) == nil)
        #expect(try knowledge.sourceExists("idea-source"), "the source it named stays in the library")
        #expect(try knowledge.loadLearningGoal(goal.id) != nil, "so does the Goal")
        do {
            _ = try store.deleteIdea(ideaID: ideaID)
            Issue.record("a deleted Idea went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_ideas"))
        }
    }

    /// The knowledge boundary holds on an Idea's chips: an episode of a show
    /// the learner muted for the AI is still linked, but the listing does not
    /// name it.
    @Test("A source kept from AI is linked without its title")
    func ideaLinkRespectsTheKnowledgeBoundary() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        var episode = StudioArticle(
            url: "https://pod.example/muted-idea", title: "Kept out of the model's reach",
            sourceType: .podcast, id: "muted-idea"
        )
        episode.domain = "Muted Show"
        try knowledge.saveSource(episode)

        let created = try parseJSON(try store.createIdea(
            title: "Built on something private", notes: nil,
            links: [["kind": "source", "target_id": "muted-idea"]]
        ))
        let ideaID = try #require(created["idea_id"] as? String)

        let named = try parseJSON(try store.listIdeas(includeArchived: true))
        let namedLinks = try #require((named["ideas"] as? [[String: Any]])?.first?["links"] as? [[String: Any]])
        #expect(namedLinks.first?["title"] as? String == "Kept out of the model's reach", "an ordinary source reads as itself")

        try knowledge.setPodcastShowHidden("Muted Show", hidden: true)
        let listed = try parseJSON(try store.listIdeas(includeArchived: true))
        let rows = try #require(listed["ideas"] as? [[String: Any]])
        let links = try #require(rows.first { $0["idea_id"] as? String == ideaID }?["links"] as? [[String: Any]])
        let link = try #require(links.first)
        #expect(link["target_id"] as? String == "muted-idea", "the link is still there")
        #expect(link["title"] == nil, "its title is not")
        #expect(link["withheld_from_ai"] as? Bool == true)
    }

    // MARK: - Directions (docs/directions-design.md)

    /// A direction search over MCP: the brief, the proposals it saves, the
    /// learner's answers, and the brief again, which now leads with them.
    @Test("find_directions briefs a search, propose_directions saves it, update_direction records the answer the next brief reads")
    func directionToolsOverMCP() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_directions_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { cleanup(tmpDir.path) }
        let store = MCPDataStore(
            dbPath: tmpDir.appendingPathComponent("knowledge.db").path,
            sourceEmbeddingProvider: { _ in [1, 0, 0] }
        )
        let knowledge = try store.knowledgeStore()
        for name in ["find_directions", "search_literature", "propose_directions", "list_directions", "update_direction", "delete_direction"] {
            #expect(MCPToolRegistry.shared.tools.contains { $0.name == name }, "\(name) is not registered")
        }
        let proposeDef = try #require(MCPToolRegistry.shared.tools.first { $0.name == "propose_directions" })
        #expect(proposeDef.inputSchema["required"] as? [String] == ["home_id", "directions"])

        try Self.seedReadySource(
            knowledge, id: "jain-2016", url: "https://www.science.org/doi/10.1126/science.aad9642",
            title: "Hypoxia as a therapy for mitochondrial disease", sourceType: .article
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Find methods to target rare mitochondrial diseases", description: "Read it against a phenotyping-first startup.",
            topic: "rare mitochondrial disease therapeutics",
            startAt: Date(), endAt: Date().addingTimeInterval(14 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: ["jain-2016"], parentNotebookID: nil
        )
        _ = try knowledge.createIdea(title: "Pooled in vivo screening with an MMP readout")

        let first = try parseJSON(try await store.findDirections(homeID: goal.id, focus: "methods to target"))
        let home = try #require(first["home"] as? [String: Any])
        #expect(home["kind"] as? String == "goal")
        #expect(home["focus"] as? String == "methods to target")
        let instructions = try #require(first["standing_instructions"] as? [[String: Any]])
        #expect(instructions.first?["text"] as? String == "Read it against a phenotyping-first startup.")
        let sources = try #require(first["sources"] as? [[String: Any]])
        #expect(sources.map { $0["source_id"] as? String } == ["jain-2016"])
        let ideas = try #require(first["learner_ideas"] as? [[String: Any]])
        #expect(ideas.map { $0["title"] as? String } == ["Pooled in vivo screening with an MMP readout"])
        #expect((first["directions"] as? [[String: Any]])?.isEmpty == true)
        let steps = try #require(first["steps"] as? String)
        #expect(steps.contains("home_id \(goal.id)"))

        do {
            _ = try await store.findDirections(homeID: "nowhere", focus: nil)
            Issue.record("a brief for no home went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("create_idea"))
        }

        let evidence: [[String: Any]] = [[
            "citation": "Jain et al., Science 2016",
            "doi": "10.1126/science.aad9642",
            "url": "https://www.science.org/doi/10.1126/science.aad9642",
            "finding": "Hypoxia prevented disease in Ndufs4 knockout mice.",
        ]]
        do {
            _ = try store.proposeDirections(homeID: goal.id, rawDirections: [[
                "title": "Something", "rationale": "Because", "angle": "hunch", "evidence": evidence,
            ]], sessionID: nil, hostSessionID: nil)
            Issue.record("an unknown angle went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("angle"))
        }
        do {
            _ = try store.proposeDirections(homeID: goal.id, rawDirections: [[
                "title": "Uncited", "rationale": "Because", "angle": "gap", "evidence": [] as [[String: Any]],
            ]], sessionID: nil, hostSessionID: nil)
            Issue.record("a direction citing nothing went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("cites nothing"))
        }

        let proposed = try parseJSON(try store.proposeDirections(homeID: goal.id, rawDirections: [
            [
                "title": "Hypoxia or HIF activation for complex I deficiency",
                "rationale": "Hypoxia rescued the mouse model and a drug now mimics it.",
                "angle": "enabling",
                "evidence": evidence,
                "objection": "Hypoxia worsens some lesions.",
                "next_step": "Map which genotypes were rescued.",
            ],
            [
                "title": "Re-run a failed PMD trial in a phenotype-defined cohort",
                "rationale": "Heterogeneous cohorts diluted signals that subgroups showed.",
                "angle": "revival",
                "evidence": [["citation": "A registry page", "url": "https://clinicaltrials.gov/study/NCT05162768", "finding": "The follow-on trial enrolled one genetic subgroup."]],
            ],
        ], sessionID: nil, hostSessionID: nil))
        #expect(proposed["status"] as? String == "saved")
        let saved = try #require(proposed["saved"] as? [[String: Any]])
        #expect(saved.count == 2)
        let hypoxiaID = try #require(saved.first?["direction_id"] as? String)
        let revivalID = try #require(saved.last?["direction_id"] as? String)

        let again = try parseJSON(try store.proposeDirections(homeID: goal.id, rawDirections: [[
            "title": "hypoxia or HIF activation for complex-I deficiency", "rationale": "Same", "angle": "enabling", "evidence": evidence,
        ]], sessionID: nil, hostSessionID: nil))
        #expect(again["status"] as? String == "nothing_new")
        #expect(again["skipped_as_already_proposed"] as? [String] == ["hypoxia or HIF activation for complex-I deficiency"])

        let listed = try parseJSON(try store.listDirections(homeID: goal.id, statusString: nil))
        let rows = try #require(listed["directions"] as? [[String: Any]])
        #expect(rows.count == 2)
        let hypoxiaRow = try #require(rows.first { $0["direction_id"] as? String == hypoxiaID })
        let rowEvidence = try #require(hypoxiaRow["evidence"] as? [[String: Any]])
        #expect(rowEvidence.first?["in_library"] as? Bool == true, "the library's copy is found by its address")
        #expect(rowEvidence.first?["library_source_id"] as? String == "jain-2016")
        #expect(hypoxiaRow["objection"] as? String == "Hypoxia worsens some lesions.")

        let pursued = try parseJSON(try store.updateDirection(directionID: hypoxiaID, arguments: ["status": "pursued", "reason": "It fits the phenotyping angle"]))
        #expect(pursued["direction_status"] as? String == "pursued")
        _ = try store.updateDirection(directionID: revivalID, arguments: ["status": "set_aside", "reason": "Already knew about it"])
        do {
            _ = try store.updateDirection(directionID: revivalID, arguments: [:])
            Issue.record("an empty change went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("Nothing to change"))
        }

        let second = try parseJSON(try await store.findDirections(homeID: goal.id, focus: nil))
        let answered = try #require(second["directions"] as? [[String: Any]])
        #expect(answered.map { $0["status"] as? String } == ["pursued", "set_aside"], "pursued first, then set aside")
        #expect(answered.map { $0["learner_reason"] as? String } == ["It fits the phenotyping angle", "Already knew about it"])

        let otherGoal = try knowledge.createCompanionGoal(
            title: "Another aim", description: nil, topic: "another",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let elsewhere = try parseJSON(try await store.findDirections(homeID: otherGoal.id, focus: nil))
        let calibration = try #require(elsewhere["answers_elsewhere"] as? [[String: Any]])
        #expect(Set(calibration.compactMap { $0["learner_reason"] as? String }) == ["It fits the phenotyping angle", "Already knew about it"])

        let deleted = try parseJSON(try store.deleteDirection(directionID: revivalID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(try knowledge.loadResearchDirections().map(\.id) == [hypoxiaID])
    }

    /// The drop of sources onto a Goal's row, over MCP (product owner, 2026-09-19:
    /// "allow me to drag sources onto goals ... and via mcp").
    @Test("add_goal_sources puts sources on a Goal and the Notebook it is tagged to, skips repeats, and refuses a Notebook, an unknown source and an empty list")
    func addGoalSourcesOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let def = try #require(MCPToolRegistry.shared.tools.first { $0.name == "add_goal_sources" })
        #expect(def.inputSchema["required"] as? [String] == ["goal_id", "source_ids"])

        try Self.seedReadySource(knowledge, id: "src-a", url: "https://example.com/a", title: "A", sourceType: .article)
        try Self.seedReadySource(knowledge, id: "src-b", url: "https://example.com/b", title: "B", sourceType: .article)

        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let tagged = try knowledge.createCompanionGoal(
            title: "Understand the method", description: nil, topic: "method",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let standalone = try knowledge.createCompanionGoal(
            title: "Write the article", description: nil, topic: "article",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        let first = try parseJSON(try await store.addGoalSources(goalID: tagged.id, sourceIDs: ["src-a", "src-b"]))
        #expect(first["added"] as? Int == 2)
        #expect(first["skipped"] as? Int == 0)
        #expect(first["source_ids"] as? [String] == ["src-a", "src-b"])
        #expect(first["notebook_id"] as? String == notebook.id)
        #expect(try knowledge.loadLearningGoal(tagged.id)?.approvedSourceIDs == ["src-a", "src-b"])
        #expect(
            try knowledge.loadLearningGoal(notebook.id)?.approvedSourceIDs == ["src-a", "src-b"],
            "a tagged Goal hands its sources on to the Notebook's pool"
        )

        let again = try parseJSON(try await store.addGoalSources(goalID: tagged.id, sourceIDs: ["src-a"]))
        #expect(again["added"] as? Int == 0)
        #expect(again["skipped"] as? Int == 1)
        #expect(again["source_count"] as? Int == 2)

        let alone = try parseJSON(try await store.addGoalSources(goalID: standalone.id, sourceIDs: ["src-b"]))
        #expect(alone["source_count"] as? Int == 1)
        #expect(alone["notebook_id"] == nil, "a standalone Goal names no Notebook")
        let detail = try parseJSON(try store.getGoal(goalID: standalone.id))
        #expect((detail["seeds"] as? [[String: Any]])?.compactMap { $0["source_id"] as? String } == ["src-b"])

        do {
            _ = try await store.addGoalSources(goalID: notebook.id, sourceIDs: ["src-a"])
            Issue.record("a Notebook went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("Notebook"))
        }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: standalone.id, sourceIDs: ["src-missing"]) }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: standalone.id, sourceIDs: []) }
        await #expect(throws: MCPError.self) { _ = try await store.addGoalSources(goalID: "nope", sourceIDs: ["src-a"]) }
    }

    @Test("A goal the learner names is a Goal, never an open question: the open-question tool and both chat prompts send \"goal\" to create_learning_goal even without a date")
    func namedGoalIsNeverFiledAsOpenQuestion() throws {
        // The product owner (2026-09-20): "can you set up a goal where I want to
        // understand these cross-modality predictions" landed in a Notebook's
        // open questions because create_learning_goal needs an end_date the
        // learner had not given. The missing date changes nothing about what
        // the thing is; the assistant proposes a deadline instead.
        let openQuestion = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_open_question" })
        #expect(openQuestion.description.contains("NOT a Goal"))
        #expect(openQuestion.description.contains("use create_learning_goal instead"))
        #expect(openQuestion.description.contains("propose one and confirm it rather than filing the goal here"))
        #expect(Prompts.mcpServerInstructions.contains("A goal voiced without a date is still a Goal"))
        #expect(Prompts.mcpServerInstructions.contains("Never file it as an open question (create_open_question)"))
        #expect(Prompts.appAssistant.contains("or ask for a goal by name"))
        #expect(Prompts.appAssistant.contains("A missing date never changes what the thing is"))
    }

    @Test("A Goal is for a Doc or Site over MCP: create_learning_goal takes artifact_id, rows answer artifact, update_learning_goal unlinks, an unknown id is refused")
    func goalArtifactOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let create = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_learning_goal" })
        #expect((create.inputSchema["properties"] as? [String: Any])?["artifact_id"] != nil)
        let update = try #require(MCPToolRegistry.shared.tools.first { $0.name == "update_learning_goal" })
        #expect((update.inputSchema["properties"] as? [String: Any])?["artifact_id"] != nil)

        let created = try parseJSON(try await store.createArtifact(
            title: "Rare mitochondrial diseases", homeNotebookID: nil, notebookIDs: [], markdown: "# Rare mitochondrial diseases"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.string(from: Date().addingTimeInterval(7 * 86_400))

        let brief = try await store.createCompanionLearningGoal(
            title: "Make a site of the rare mitochondrial diseases", topic: nil,
            endDateString: endDate, startDateString: nil, sourceIDs: [],
            dailyTarget: nil, discover: false, notebookID: nil, artifactID: docID
        )
        #expect(brief.contains("For “Rare mitochondrial diseases”; the Goal's row opens it."))
        #expect(!brief.contains("Created timebound Goal \(docID)"))

        let listed = try parseJSON(try store.listNotebookGoals(notebookID: nil))
        let rows = try #require(listed["goals"] as? [[String: Any]])
        let row = try #require(rows.first)
        let goalID = try #require(row["id"] as? String)
        let artifact = try #require(row["artifact"] as? [String: Any])
        #expect(artifact["id"] as? String == docID)
        #expect(artifact["title"] as? String == "Rare mitochondrial diseases")
        #expect(artifact["kind"] as? String == "doc")
        #expect(try knowledge.loadLearningGoal(goalID)?.linkedArtifactID == docID)

        let detail = try parseJSON(try store.getGoal(goalID: goalID))
        #expect((detail["artifact"] as? [String: Any])?["id"] as? String == docID)

        do {
            _ = try await store.updateLearningGoal(
                goalID: goalID, title: nil, description: nil, topic: nil, endDateString: nil,
                dailyTarget: nil, discover: nil, notebookID: nil, statusString: nil, artifactID: "nope"
            )
            Issue.record("an unknown artifact id went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("No Doc, Site or animation"))
        }
        #expect(try knowledge.loadLearningGoal(goalID)?.linkedArtifactID == docID, "a refusal changes nothing")

        let unlinked = try await store.updateLearningGoal(
            goalID: goalID, title: nil, description: nil, topic: nil, endDateString: nil,
            dailyTarget: nil, discover: nil, notebookID: nil, statusString: nil, artifactID: ""
        )
        #expect(unlinked.contains("No longer for any Doc, Site or animation"))
        let cleared = try parseJSON(try store.getGoal(goalID: goalID))
        #expect(cleared["artifact"] is NSNull)
        #expect(try knowledge.loadLearningGoal(goalID)?.artifactID == "", "an unlink is an explicit clear")

        // A Notebook never answers the question: it is not for one artifact.
        _ = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let notebooks = try parseJSON(try store.listCompanionLearningGoals(topLevelOnly: true))
        let notebookRow = try #require((notebooks["goals"] as? [[String: Any]])?.first)
        #expect(notebookRow["artifact"] == nil)
    }

    @Test("A Goal stands on its own over MCP: no notebook_id to create it, list_goals has it, list_notebooks does not, and a tag can come and go")
    func standaloneGoalOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let create = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_learning_goal" })
        #expect(create.inputSchema["required"] as? [String] == ["title", "end_date"])

        let notebook = try knowledge.createCompanionGoal(
            title: "OxPhos", topic: "oxphos", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        let endDate = formatter.string(from: try #require(Calendar.current.date(byAdding: .day, value: 5, to: Date())))

        let created = try await store.createCompanionLearningGoal(
            title: "Understand Zara's thesis work", topic: nil, endDateString: endDate, startDateString: nil,
            sourceIDs: [], dailyTarget: nil, discover: false, notebookID: nil
        )
        #expect(!created.contains("Belongs to Notebook"), "no Notebook was invented to hold it")
        let goal = try #require(try knowledge.loadLearningGoals().first { $0.title == "Understand Zara's thesis work" })
        #expect(goal.isGoal && goal.isStandaloneGoal && !goal.isNotebook)

        func ids(_ json: String) throws -> [String] {
            ((try parseJSON(json))["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String ?? $0["goal_id"] as? String } ?? []
        }
        #expect(try ids(try store.listNotebookGoals(notebookID: nil)) == [goal.id], "list_goals lists a Goal that names no Notebook")
        #expect(try ids(try store.listCompanionLearningGoals(topLevelOnly: true)) == [notebook.id], "list_notebooks never lists a Goal")
        #expect(try store.listNotebookGoals(notebookID: notebook.id).contains("has no Goals yet"))

        // get_goal answers for it, and a Notebook is refused by the Goal tools.
        let detail = try parseJSON(try store.getGoal(goalID: goal.id))
        #expect(detail["notebook_id"] == nil)
        #expect(throws: MCPError.self) { _ = try store.getGoal(goalID: notebook.id) }

        // Tag it to a Notebook, then untag it with "".
        _ = try await store.updateLearningGoal(
            goalID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil, dailyTarget: nil, discover: nil,
            notebookID: notebook.id, statusString: nil
        )
        #expect(try knowledge.loadLearningGoal(goal.id)?.parentNotebookID == notebook.id)
        #expect(try ids(try store.listNotebookGoals(notebookID: notebook.id)) == [goal.id])
        _ = try await store.updateLearningGoal(
            goalID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil, dailyTarget: nil, discover: nil,
            notebookID: "", statusString: nil
        )
        let untagged = try #require(try knowledge.loadLearningGoal(goal.id))
        #expect(untagged.parentNotebookID == nil && untagged.isStandaloneGoal)
        #expect(untagged.endAt == goal.endAt, "untagging keeps the deadline")
        #expect(try ids(try store.listCompanionLearningGoals(topLevelOnly: true)) == [notebook.id])
    }

    @Test("list_goals counts the days a Goal has left the way the Goals tab does: 0 on the day it falls due, never one more")
    func goalDaysRemainingMatchTheRail() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()

        func goal(endingIn days: Int, _ title: String) async throws -> LearningGoalRecord {
            let end = formatter.string(from: try #require(calendar.date(byAdding: .day, value: days, to: now)))
            // A Goal must end after it starts, so one falling due today began yesterday.
            let start = formatter.string(from: try #require(calendar.date(byAdding: .day, value: -1, to: now)))
            _ = try await store.createCompanionLearningGoal(
                title: title, topic: nil, endDateString: end, startDateString: start,
                sourceIDs: [], dailyTarget: nil, discover: false, notebookID: nil
            )
            return try #require(try knowledge.loadLearningGoals().first { $0.title == title })
        }
        let dueToday = try await goal(endingIn: 0, "Due today")
        let inFive = try await goal(endingIn: 5, "In five days")

        let listed = (try parseJSON(try store.listNotebookGoals(notebookID: nil))["goals"] as? [[String: Any]]) ?? []
        func remaining(_ id: String) -> Int? {
            listed.first { ($0["id"] as? String ?? $0["goal_id"] as? String) == id }?["days_remaining"] as? Int
        }
        // Until 2026-09-20 the handler added one, so the rail's "due today" listed as a day left.
        #expect(remaining(dueToday.id) == 0)
        #expect(remaining(dueToday.id) == dueToday.daysRemaining(asOf: now, calendar: calendar))
        #expect(remaining(inFive.id) == 5)
        #expect(remaining(inFive.id) == inFive.daysRemaining(asOf: now, calendar: calendar))

        // get_goal reads the same figure, and the in-app quiz card plan too.
        let detail = try parseJSON(try store.getGoal(goalID: inFive.id))
        #expect(detail["days_remaining"] as? Int == 5)
        #expect(CompanionCardPlan(goal: dueToday).daysRemaining == 0)
        #expect(CompanionCardPlan(goal: inFive).daysRemaining == 5)
    }

    @Test("Goals reorder over MCP: reorder_goals places the listed first, the rest follow as they read, list_goals reads the order, an empty list is deadline order again, and a Notebook or a finished Goal is refused")
    func reorderGoalsOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "reorder_goals" })
        #expect((tool.inputSchema["required"] as? [String]) == ["goal_ids"])

        let now = Date()
        func goal(_ title: String, days: Double) throws -> LearningGoalRecord {
            try knowledge.createCompanionGoal(
                title: title, topic: title, startAt: now, endAt: now.addingTimeInterval(days * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
        }
        let soon = try goal("Due soon", days: 1)
        let week = try goal("Due in a week", days: 7)
        let month = try goal("Due in a month", days: 30)
        let done = try goal("Done already", days: 3)
        try knowledge.setLearningGoalStatus(goalID: done.id, status: .done)
        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )

        func listedIDs() throws -> [String] {
            let listed = try parseJSON(try store.listNotebookGoals(notebookID: nil))
            return (listed["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        #expect(try listedIDs() == [soon.id, week.id, month.id], "before any placement the list reads by deadline")

        // A subset: the one named goes first, the other two keep their order.
        let placed = try parseJSON(try store.reorderGoals(goalIDs: [month.id]))
        #expect((placed["goals"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [month.id, soon.id, week.id])
        #expect(try listedIDs() == [month.id, soon.id, week.id])
        #expect(try knowledge.loadLearningGoal(month.id)?.sortOrder == 0)
        #expect(try knowledge.loadLearningGoal(week.id)?.sortOrder == 2)

        // Back to deadline order.
        let cleared = try parseJSON(try store.reorderGoals(goalIDs: []))
        #expect((cleared["note"] as? String)?.contains("by deadline") == true)
        #expect(try listedIDs() == [soon.id, week.id, month.id])
        #expect(try knowledge.loadLearningGoal(month.id)?.sortOrder == nil)

        for refused in [notebook.id, done.id, "nope"] {
            do {
                _ = try store.reorderGoals(goalIDs: [refused])
                Issue.record("\(refused) was placed")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("Use list_goals"))
            }
        }
        #expect(try listedIDs() == [soon.id, week.id, month.id], "a refusal changes nothing")
    }

    @Test("Notebook-scoped tools require an explicit notebook id")
    func notebookScopedToolsRequireExplicitNotebookID() throws {
        let names = [
            "update_notebook",
            "get_notebook",
            "add_notebook_sources",
            "list_notebook_sources",
            "reorder_notebook_sources",
            "set_notebook_source_selection",
            "get_notebook_context",
            "list_notebook_files",
            "read_notebook_markdown_file",
            "write_notebook_markdown_file",
            "update_notebook_notes",
            "append_notebook_notes",
            "split_notebook",
            "list_open_questions",
            "create_open_question",
            "update_open_question",
        ]

        for name in names {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name })
            let required = try #require(tool.inputSchema["required"] as? [String])
            #expect(required.contains("notebook_id"), "Expected \(name) to require notebook_id")
        }
    }

    @Test("Each window's notebook is discoverable, frontmost first, but never an implicit tool target")
    func windowNotebooksAreNotImplicitToolTargets() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "front-source", title: "Front reading", content: "Front text.")
        try insertSource(dbPath: dbPath, id: "back-source", title: "Back reading", content: "Back text.")
        let knowledge = try store.knowledgeStore()
        func notebook(_ title: String, seeds: [String]) throws -> LearningGoalRecord {
            try knowledge.createCompanionGoal(
                title: title,
                topic: title,
                startAt: Date(),
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: seeds
            )
        }
        let front = try notebook("Open in front", seeds: ["front-source"])
        let back = try notebook("Open behind", seeds: ["back-source"])

        // The registry hands these over frontmost first.
        let windows = MCPAppWindows.ordered(notebookIDs: [back.id, nil, front.id], frontmost: 2)
        #expect(windows.map(\.notebookID) == [front.id, back.id, nil])
        #expect(windows.map(\.isFrontmost) == [true, false, false])

        let context = try store.getAppContext(windows: windows)
        let lines = context.components(separatedBy: "\n")
        #expect(lines.first == "3 ForeverLM windows are open, frontmost first. What they hold is never an implicit MCP default: pass notebook_id explicitly to Notebook tools.")
        #expect(lines.contains("- Frontmost window: Notebook 'Open in front' (notebook_id: \(front.id), 1 source)"))
        #expect(lines.contains("- Window: Notebook 'Open behind' (notebook_id: \(back.id), 1 source)"))
        #expect(lines.contains("- Window: no notebook open"))
        // The frontmost window's notebook's sources follow; the others' do not.
        #expect(context.contains("Front text."))
        #expect(!context.contains("Back text."))
        #expect(!context.contains("legacy"))

        #expect(try store.getAppContext(windows: []).hasPrefix("No ForeverLM window is open."))
        let homeOnly = try store.getAppContext(windows: MCPAppWindows.ordered(notebookIDs: [nil], frontmost: 0))
        #expect(homeOnly.contains("- Frontmost window: no notebook open"))

        // No tool falls back to a window's notebook.
        #expect(throws: MCPError.self) {
            _ = try store.listNotebookSources(notebookID: nil)
        }
        #expect(try store.listNotebookSources(notebookID: front.id).contains("Front reading"))
    }

    @Test("open question tools create, list, and update notebook gaps")
    func openQuestionToolsRoundTrip() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-1", title: "Paper A", content: "Mechanism details.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Immunology",
            topic: "B cells",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1"]
        )
        let created = try parseJSON(try store.createOpenQuestion(
            notebookID: goal.id,
            summary: "How do B cells present antigen?",
            sourceID: "src-1",
            severity: 0.8,
            status: nil
        ))
        let question = try #require(created["open_question"] as? [String: Any])
        let questionID = try #require(question["question_id"] as? String)
        #expect(question["summary"] as? String == "How do B cells present antigen?")
        #expect(question["status"] as? String == "open")

        let listed = try parseJSON(try store.listOpenQuestions(notebookID: goal.id, includeResolved: false, status: nil))
        let questions = try #require(listed["open_questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions.first?["question_id"] as? String == questionID)

        let updated = try parseJSON(try store.updateOpenQuestion(
            notebookID: goal.id,
            questionID: questionID,
            summary: "How do B cells present antigen to T cells?",
            sourceID: nil,
            severity: nil,
            status: "improving",
            clearSourceID: false
        ))
        let patched = try #require(updated["open_question"] as? [String: Any])
        #expect(patched["status"] as? String == "improving")
        #expect(patched["summary"] as? String == "How do B cells present antigen to T cells?")
    }

    @Test("list notebook sources includes derived understanding state")
    func listNotebookSourcesIncludesUnderstandingState() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-new", title: "Fresh", content: "Unread.")
        try insertSource(dbPath: dbPath, id: "src-read", title: "Started", content: "In progress.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "States",
            topic: "states",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-new", "src-read"]
        )
        var items = try #require(try ks.loadLearningGoal(goal.id)?.items)
        if let index = items.firstIndex(where: { $0.sourceID == "src-read" }) {
            items[index].lastQuizzedAt = Date()
            items[index].quizCount = 1
            items[index].lastScore = 0.4
            var record = try #require(try ks.loadLearningGoal(goal.id))
            record.items = items
            try ks.saveLearningGoalRecord(record)
        }

        let payload = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
        let sources = try #require(payload["sources"] as? [[String: Any]])
        let fresh = try #require(sources.first { ($0["id"] as? String) == "src-new" })
        let started = try #require(sources.first { ($0["id"] as? String) == "src-read" })
        #expect(fresh["understanding_state"] as? String == "to-read")
        #expect(started["understanding_state"] as? String == "reading")
        #expect(started["last_score"] as? Double == 0.4)
        // Each source carries the link a reply shows instead of its id.
        #expect(fresh["link"] as? String == "[Fresh](foreverlm://source/src-new)")
    }

    // MARK: Notebook chat checkboxes

    /// Runs `body` with the notebook rows in a throwaway defaults suite
    /// (`NotebookChatSelection.overrideDefaults`), never the shared standard
    /// defaults, and hands it the suite to assert on.
    private func withNotebookSelectionDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "NotebookChatSelectionMCP.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Generation 1's rows: the test host runs generation 2, where the same ticks live in the
        // member's NotebookState.
        try await ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(.one) {
            try await NotebookChatSelection.$overrideDefaults.withValue(NotebookChatSelection.DefaultsOverride(defaults: defaults)) {
                try await body(defaults)
            }
        }
    }

    /// A Notebook holding three readable sources, in study order.
    private func makeSelectionNotebook(store: MCPDataStore, tmpPath: String) throws -> LearningGoalRecord {
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src-1", "src-2", "src-3"] {
            try insertSource(dbPath: dbPath, id: id, title: "Paper \(id)", content: "Text of \(id).")
        }
        return try store.knowledgeStore().createCompanionGoal(
            title: "Selection",
            topic: "selection",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1", "src-2", "src-3"]
        )
    }

    @Test("set_notebook_source_selection ticks and unticks a Notebook's sources for its chats, never its membership")
    func notebookSourceSelectionSetsInChat() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let key = NotebookChatSelection.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            let excluded = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-2"], mode: "exclude")
            )
            #expect(excluded["updated"] as? Bool == true)
            #expect(excluded["in_chat_count"] as? Int == 2)
            #expect(excluded["in_chat_source_ids"] as? [String] == ["src-1", "src-3"])
            #expect(excluded["excluded_source_ids"] as? [String] == ["src-2"])
            #expect(defaults.stringArray(forKey: key) == ["src-2"])

            let listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            #expect(listed["source_count"] as? Int == 3)
            #expect(listed["in_chat_count"] as? Int == 2)
            let sources = try #require(listed["sources"] as? [[String: Any]])
            let inChat = Dictionary(uniqueKeysWithValues: sources.compactMap { source -> (String, Bool)? in
                guard let id = source["id"] as? String, let flag = source["in_chat"] as? Bool else { return nil }
                return (id, flag)
            })
            #expect(inChat == ["src-1": true, "src-2": false, "src-3": true])
            #expect(try store.notebookChatSourceIDs(goal: goal, store: store.knowledgeStore()) == ["src-1", "src-3"])

            let only = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-3"], mode: "only")
            )
            #expect(only["in_chat_source_ids"] as? [String] == ["src-3"])
            #expect(defaults.stringArray(forKey: key) == ["src-1", "src-2"])

            let included = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "include")
            )
            #expect(included["in_chat_source_ids"] as? [String] == ["src-1", "src-3"])

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "none")
            #expect(defaults.stringArray(forKey: key) == ["src-1", "src-2", "src-3"])

            let all = try parseJSON(
                try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "all")
            )
            #expect(all["in_chat_count"] as? Int == 3)
            #expect(defaults.object(forKey: key) == nil, "everything ticked is the default and has no row")

            let reloaded = try #require(try store.knowledgeStore().loadLearningGoal(goal.id))
            #expect(reloaded.approvedSourceIDs == ["src-1", "src-2", "src-3"], "membership is untouched")
        }
    }

    @Test("set_notebook_source_selection refuses a source outside the Notebook, a missing source_ids, and an unknown mode, writing nothing")
    func notebookSourceSelectionRefusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let key = NotebookChatSelection.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1", "elsewhere"], mode: "exclude")
                Issue.record("a source outside the Notebook was unticked")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("list_notebook_sources"))
            }
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], mode: "exclude")
                Issue.record("exclude without source_ids was accepted")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("source_ids is required"))
            }
            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "untick")
                Issue.record("an unknown mode was accepted")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("mode must be"))
            }
            #expect(defaults.object(forKey: key) == nil, "a refusal writes nothing")
        }
    }

    @Test("deleting a Notebook drops its chat selection row")
    func deleteNotebookForgetsChatSelection() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let key = NotebookChatSelection.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "exclude")
            #expect(defaults.stringArray(forKey: key) == ["src-1"])

            _ = try store.deleteNotebook(notebookID: goal.id)

            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test("split_notebook that empties its parent hands the parent's unticked boxes to the heir and drops the parent's row")
    func splitNotebookHandsChatSelectionToTheHeir() async throws {
        let (store, tmpPath) = try makeStore(syncGeneration: .one) // generation 1's hand-over of the preference rows; NotebookMergeSplitTests pin generation 2's
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let parentKey = NotebookChatSelection.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-2", "src-3"], mode: "exclude")
            #expect(defaults.stringArray(forKey: parentKey) == ["src-2", "src-3"])

            let split = try parseJSON(try store.splitNotebook(
                notebookID: goal.id,
                splits: [
                    ["title": "Heir", "source_ids": ["src-1", "src-2"]],
                    ["title": "Other", "source_ids": ["src-3"]],
                ],
                keepParent: false
            ))
            let heirID = try #require(split["parent_contents_moved_to_notebook_id"] as? String)
            let children = try #require(split["child_notebooks"] as? [[String: Any]])
            let otherID = try #require(children.compactMap { $0["notebook_id"] as? String }.first { $0 != heirID })

            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: heirID)) == ["src-2"])
            #expect(defaults.object(forKey: NotebookChatSelection.preferenceKey(notebookID: otherID)) == nil,
                    "a child that is not the heir starts with every box ticked")
            #expect(defaults.object(forKey: parentKey) == nil)
            #expect(try store.notebookChatSourceIDs(
                goal: try #require(try store.knowledgeStore().loadLearningGoal(heirID)),
                store: store.knowledgeStore()
            ) == ["src-1"])
        }
    }

    /// A context notebook holding src-3 (the selection Notebook's too), src-4
    /// and src-5, linked to `goal` when `linked` is true.
    private func makeContextNotebook(
        store: MCPDataStore,
        tmpPath: String,
        for goal: LearningGoalRecord,
        linked: Bool = true
    ) throws -> LearningGoalRecord {
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        for id in ["src-4", "src-5"] {
            try insertSource(dbPath: dbPath, id: id, title: "Paper \(id)", content: "Text of \(id).")
        }
        let context = try store.knowledgeStore().createCompanionGoal(
            title: "Context",
            topic: "context",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-3", "src-4", "src-5"]
        )
        if linked {
            try store.knowledgeStore().setRelatedNotebooks(notebookID: goal.id, relatedNotebookIDs: [context.id])
        }
        return context
    }

    @Test("list_notebook_sources lists a context notebook's sources after the Notebook's own, read by its chats only once put in")
    func listNotebookSourcesMarksContextNotebooks() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: goal)
        let contextKey = NotebookChatContext.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            var listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            var sources = try #require(listed["sources"] as? [[String: Any]])
            #expect(sources.compactMap { $0["id"] as? String } == ["src-1", "src-2", "src-3", "src-4", "src-5"],
                    "its own, then the context notebook's it does not hold")
            #expect(sources.compactMap { $0["via_context_notebook_id"] as? String } == [context.id, context.id])
            #expect(sources[3]["via_context_notebook_title"] as? String == "Context")
            #expect(sources.compactMap { $0["in_chat"] as? Bool } == [true, true, true, false, false], "linked alone reads nothing")
            #expect(listed["in_chat_count"] as? Int == 3)
            var notebooks = try #require(listed["context_notebooks"] as? [[String: Any]])
            #expect(notebooks.map { $0["notebook_id"] as? String } == [context.id])
            #expect(notebooks.first?["in_chat"] as? Bool == false)
            let linkedGoal = try #require(try store.knowledgeStore().loadLearningGoal(goal.id))
            #expect(try store.notebookChatSourceIDs(goal: linkedGoal, store: store.knowledgeStore()) == ["src-1", "src-2", "src-3"])

            let putIn = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(putIn["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4", "src-5"])
            #expect(defaults.stringArray(forKey: contextKey) == [context.id])

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-5"], mode: "exclude")
            listed = try parseJSON(try store.listNotebookSources(notebookID: goal.id))
            sources = try #require(listed["sources"] as? [[String: Any]])
            #expect(sources.compactMap { $0["in_chat"] as? Bool } == [true, true, true, true, false])
            notebooks = try #require(listed["context_notebooks"] as? [[String: Any]])
            #expect(notebooks.first?["in_chat"] as? Bool == true)
            #expect(notebooks.first?["in_chat_count"] as? Int == 2)

            let out = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "exclude"
            ))
            #expect(out["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3"])
            #expect(defaults.object(forKey: contextKey) == nil)
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: goal.id)) == ["src-5"],
                    "its sources' boxes are kept for when it comes back")

            // Put back in, it comes as it was left: src-5 still unticked.
            let back = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(back["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4"])
            #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: goal.id)) == ["src-5"])
            // Included again while it is in, every source of it is ticked, as its box does.
            let whole = try parseJSON(try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include"
            ))
            #expect(whole["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4", "src-5"])
            #expect(defaults.object(forKey: NotebookChatSelection.preferenceKey(notebookID: goal.id)) == nil)
            _ = try await store.setNotebookSourceSelection(
                notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "exclude"
            )

            let one = try parseJSON(try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-4"], mode: "include"))
            #expect(one["in_chat_source_ids"] as? [String] == ["src-1", "src-2", "src-3", "src-4"],
                    "ticking a source of a context notebook out of the chats puts it in with that source alone")
            #expect(defaults.stringArray(forKey: contextKey) == [context.id])

            let only = try parseJSON(try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "only"))
            #expect(only["in_chat_source_ids"] as? [String] == ["src-1"])
            #expect(defaults.object(forKey: contextKey) == nil, "only takes every context notebook it does not name out")

            do {
                _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], contextNotebookIDs: ["not-linked"], mode: "include")
                Issue.record("a notebook the Notebook does not link was put in")
            } catch let error as MCPError {
                #expect(error.localizedDescription.contains("not a context notebook"))
            }
        }
    }

    @Test("get_notebook_context reads a context notebook's sources and notes only once it is in the Notebook's chats, and says what it leaves out")
    func getNotebookContextFollowsContextNotebooks() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: goal)

        try await withNotebookSelectionDefaults { _ in
            let before = try await store.getNotebookContext(
                notebookID: goal.id, maxSourceChars: nil, includeEmergentState: true, includeSourceContent: true
            )
            #expect(before.contains("Text of src-3."))
            #expect(!before.contains("Text of src-4."))
            #expect(!before.contains("# Context notebook"))
            #expect(before.contains("1 context notebook out of its chats"))

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include")
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-2"], mode: "exclude")
            let after = try await store.getNotebookContext(
                notebookID: goal.id, maxSourceChars: nil, includeEmergentState: true, includeSourceContent: true
            )
            #expect(after.contains("Text of src-4.") && after.contains("Text of src-5."))
            #expect(after.contains("# Context notebook"))
            #expect(!after.contains("Text of src-2."), "an unticked source is left out")
            #expect(after.contains("1 source the learner unticked"))
            #expect(!after.contains("out of its chats"))
        }
    }

    @Test("update_notebook links a context notebook without putting it into the chats, and unlinking drops it alone from the row")
    func updateNotebookLinksWithoutPuttingIn() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let goal = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: goal, linked: false)
        let contextKey = NotebookChatContext.preferenceKey(notebookID: goal.id)

        try await withNotebookSelectionDefaults { defaults in
            _ = try await store.updateNotebook(
                notebookID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil,
                openEnded: nil, dailyTarget: nil, discover: nil, relatedNotebookIDs: [context.id]
            )
            let linked = try #require(try store.knowledgeStore().loadLearningGoal(goal.id))
            #expect(linked.relatedNotebookIDs == [context.id])
            #expect(defaults.object(forKey: contextKey) == nil)
            #expect(try store.notebookChatSourceIDs(goal: linked, store: store.knowledgeStore()) == ["src-1", "src-2", "src-3"])

            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include")
            #expect(defaults.stringArray(forKey: contextKey) == [context.id])

            // Another device linked and put in a notebook this Mac has not
            // heard of yet: a box write here keeps it.
            defaults.set([context.id, "elsewhere"].sorted(), forKey: contextKey)
            _ = try await store.setNotebookSourceSelection(notebookID: goal.id, sourceIDs: ["src-1"], mode: "exclude")
            #expect(defaults.stringArray(forKey: contextKey) == [context.id, "elsewhere"].sorted())

            _ = try await store.updateNotebook(
                notebookID: goal.id, title: nil, description: nil, topic: nil, endDateString: nil,
                openEnded: nil, dailyTarget: nil, discover: nil, relatedNotebookIDs: []
            )
            #expect(defaults.stringArray(forKey: contextKey) == ["elsewhere"], "unlinked here, it leaves the row, and nothing else does")
        }
    }

    @Test("merge_notebooks keeps the context notebooks the merged Notebook's chats read, for the survivor")
    func mergeNotebooksCarriesContextNotebooks() async throws {
        let (store, tmpPath) = try makeStore(syncGeneration: .one) // generation 1's hand-over of the preference rows; NotebookMergeSplitTests pin generation 2's
        defer { cleanup(tmpPath) }
        let survivor = try makeSelectionNotebook(store: store, tmpPath: tmpPath)
        let merged = try store.knowledgeStore().createCompanionGoal(
            title: "Merged",
            topic: "merged",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1"]
        )
        let context = try makeContextNotebook(store: store, tmpPath: tmpPath, for: merged)

        try await withNotebookSelectionDefaults { defaults in
            _ = try await store.setNotebookSourceSelection(notebookID: merged.id, sourceIDs: [], contextNotebookIDs: [context.id], mode: "include")
            _ = try store.mergeNotebooks(notebookIDs: [survivor.id, merged.id], title: nil, mergeNotes: true)

            #expect(try store.knowledgeStore().loadLearningGoal(survivor.id)?.relatedNotebookIDs == [context.id])
            #expect(defaults.stringArray(forKey: NotebookChatContext.preferenceKey(notebookID: survivor.id)) == [context.id])
            #expect(defaults.object(forKey: NotebookChatContext.preferenceKey(notebookID: merged.id)) == nil)
        }
    }

    @Test("get notebook context includes emergent state and source content")
    func getNotebookContextIncludesEmergentState() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "src-1", title: "Core paper", content: "Important mechanism.")

        let ks = try store.knowledgeStore()
        let goal = try ks.createCompanionGoal(
            title: "Mechanisms",
            topic: "mechanisms",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,  // a Notebook: open-ended since schema 120
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-1"]
        )
        let briefDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Requirements", isDirectory: true)
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        let briefURL = briefDirectory.appendingPathComponent("challenge description.pdf")
        let briefRequirement = "The final analysis must distinguish correlation from the rate-limiting mechanism."
        try makeTestPDF(
            at: briefURL,
            text: """
            Notebook challenge description. Use the supplied observations to compare the candidate mechanisms,
            document assumptions, test each explanation against held-out evidence, and report uncertainty clearly.
            \(briefRequirement) The submission should remain reproducible and concise for a technical reader.
            """
        )
        let briefValues = try briefURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let briefDate = briefValues.contentModificationDate ?? Date()
        let referencesDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Papers I care about", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
        let referenceURL = referencesDirectory.appendingPathComponent("supporting paper.pdf")
        let referenceEvidence = "The reference paper identifies a mechanistic bottleneck in the final reaction step."
        try makeTestPDF(at: referenceURL, text: referenceEvidence)
        let referenceValues = try referenceURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let referenceDate = referenceValues.contentModificationDate ?? Date()
        let dataDirectory = URL(fileURLWithPath: tmpPath)
            .appendingPathComponent("Projects/\(goal.id)/Screening run", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let dataURL = dataDirectory.appendingPathComponent("observations.tsv")
        let dataEvidence = "candidate_17\t0.942"
        try Data("candidate\tscore\n\(dataEvidence)\n".utf8).write(to: dataURL)
        let dataValues = try dataURL.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let dataDate = dataValues.contentModificationDate ?? Date()
        try ks.replaceNotebookFiles(
            notebookID: goal.id,
            with: [
                NotebookFileRecord(
                    id: "brief-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Requirements/challenge description.pdf",
                    name: "challenge description.pdf",
                    contentType: "com.adobe.pdf",
                    sizeBytes: Int64(briefValues.fileSize ?? 0),
                    modifiedAt: briefDate,
                    createdAt: briefValues.creationDate ?? briefDate
                ),
                NotebookFileRecord(
                    id: "reference-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Papers I care about/supporting paper.pdf",
                    name: "supporting paper.pdf",
                    contentType: "com.adobe.pdf",
                    sizeBytes: Int64(referenceValues.fileSize ?? 0),
                    modifiedAt: referenceDate,
                    createdAt: referenceValues.creationDate ?? referenceDate
                ),
                NotebookFileRecord(
                    id: "data-file",
                    notebookID: goal.id,
                    relativePath: "Projects/\(goal.id)/Screening run/observations.tsv",
                    name: "observations.tsv",
                    contentType: "public.tab-separated-values-text",
                    sizeBytes: Int64(dataValues.fileSize ?? 0),
                    modifiedAt: dataDate,
                    createdAt: dataValues.creationDate ?? dataDate
                ),
            ]
        )
        try ks.setLearningGoalNotes(goalID: goal.id, notes: "Synthesis so far.")
        _ = try store.createOpenQuestion(
            notebookID: goal.id,
            summary: "What is the rate-limiting step?",
            sourceID: "src-1",
            severity: nil,
            status: nil
        )
        let context = try await store.getNotebookContext(
            notebookID: goal.id,
            maxSourceChars: 4_000,
            includeEmergentState: true,
            includeSourceContent: true
        )
        #expect(context.contains("## Synthesis notes"))
        #expect(context.contains("Synthesis so far."))
        #expect(context.contains("## Open questions"))
        #expect(context.contains("What is the rate-limiting step?"))
        #expect(context.contains("## Source understanding"))
        #expect(context.contains("Core paper"))
        #expect(context.contains("Important mechanism."))
        // Sources are shown as links and the Notebook by its title, never an
        // id written beside a name (Prompts.hiddenIDs).
        #expect(context.contains("- source: [Core paper](foreverlm://source/src-1)"))
        #expect(context.contains("- [Core paper](foreverlm://source/src-1): "))
        #expect(context.contains("# Notebook 'Mechanisms'\n"))
        #expect(!context.contains("(id: \(goal.id)"))
        #expect(!context.contains("(src-1)"))
        #expect(context.contains("## Notebook files"))
        #expect(context.contains("### Requirements/challenge description.pdf"))
        #expect(context.contains("### Papers I care about/supporting paper.pdf"))
        #expect(context.contains("### Screening run/observations.tsv"))
        #expect(context.contains("challenge description.pdf"))
        let normalizedContext = context.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalizedContext.contains(briefRequirement))
        #expect(normalizedContext.contains(referenceEvidence))
        #expect(context.contains(dataEvidence))

        let stateOnly = try await store.getNotebookContext(
            notebookID: goal.id,
            maxSourceChars: nil,
            includeEmergentState: true,
            includeSourceContent: false
        )
        #expect(stateOnly.contains("Synthesis so far."))
        let normalizedStateOnly = stateOnly.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalizedStateOnly.contains(briefRequirement))
        #expect(normalizedStateOnly.contains(referenceEvidence))
        #expect(stateOnly.contains(dataEvidence))
        #expect(!stateOnly.contains("Important mechanism."))
    }

    @Test("schedule tool is exposed in MCP registry")
    func scheduleToolIsRegistered() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "get_schedule" })
    }

    @Test("schedule assignment tool is exposed in MCP registry")
    func scheduleAssignmentToolIsRegistered() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "assign_sources_to_day" })
    }

    @Test("schedule control tools are exposed in MCP registry")
    func scheduleControlToolsAreRegistered() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("unschedule_sources"))
        #expect(toolNames.contains("clear_schedule_day"))
        #expect(toolNames.contains("mark_schedule_day_done"))
        #expect(toolNames.contains("set_source_completion"))
        #expect(toolNames.contains("forget_source_activity"))
    }

    @Test("get_source_settings and set_source_settings are Settings › Sources")
    func sourceSettingsToolsDriveTheSourcesPane() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let defaults = UserDefaults.standard
        let hiddenKey = "studio.hiddenTabs"
        let knowledgeKey = StudioSidebarTab.knowledgeExclusionPreferenceKey
        let autoUnpinnedKey = StudioSidebarTab.autoUnpinnedIntegrationTabsPreferenceKey
        let keys = [hiddenKey, knowledgeKey, autoUnpinnedKey, "studio.tabOrder"]
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        // A library as Studio leaves a new one: the integration tabs off the
        // bar by Studio's own hand, everything in knowledge.
        defaults.set(["Meetings", "X"], forKey: hiddenKey)
        defaults.set(["Meetings", "X"], forKey: autoUnpinnedKey)

        func rows(_ json: String) throws -> [String: [String: Any]] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let families = try #require(object["families"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: families.map { ($0["family"] as! String, $0) })
        }

        // Read: one row per family, both switches as the pane shows them.
        let initial = try rows(try store.getSourceSettings())
        #expect(initial.count == StudioSidebarTab.allCases.count)
        #expect(initial["podcasts"]?["include_in_search_and_ai"] as? Bool == true)
        #expect(initial["podcasts"]?["pinned"] as? Bool == true)
        #expect(initial["meetings"]?["pinned"] as? Bool == false)
        #expect(initial["youtube"]?["label"] as? String == "YouTube")

        // Search & AI off for podcasts: the knowledge boundary every library
        // tool draws now excludes a podcast episode, and nothing else moved.
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(kstore, id: "ep-1", url: "https://pod.example/ep1", title: "Episode 1", sourceType: .podcast)
        try Self.seedReadySource(kstore, id: "web-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article)
        let excluded = try await store.setSourceSettings(family: "podcasts", includeInSearchAndAI: false, pinned: nil)
        let excludedJSON = try #require(try JSONSerialization.jsonObject(with: Data(excluded.utf8)) as? [String: Any])
        #expect(excludedJSON["updated"] as? Bool == true)
        #expect(excludedJSON["include_in_search_and_ai"] as? Bool == false)
        #expect(excludedJSON["pinned"] as? Bool == true)
        #expect(defaults.stringArray(forKey: knowledgeKey) == ["Podcasts"])
        let boundary = try kstore.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        #expect(boundary.contains("ep-1"))
        #expect(!boundary.contains("web-1"))
        #expect(defaults.stringArray(forKey: hiddenKey) == ["Meetings", "X"])

        // Back on, by the label the pane shows rather than the id.
        _ = try await store.setSourceSettings(family: "Podcasts", includeInSearchAndAI: true, pinned: nil)
        #expect(defaults.stringArray(forKey: knowledgeKey) == [])
        #expect(try kstore.knowledgeSearchExcludedSourceIDs(includeArchived: true).isEmpty)

        // Pin Meetings back: the tab leaves the hidden set, and Studio's record
        // that the unpin was its own is dropped, exactly as showTab does.
        _ = try await store.setSourceSettings(family: "meetings", includeInSearchAndAI: nil, pinned: true)
        #expect(defaults.stringArray(forKey: hiddenKey) == ["X"])
        #expect(defaults.stringArray(forKey: autoUnpinnedKey) == ["X"])

        // Unpin YouTube, by its pre-rename stored name.
        _ = try await store.setSourceSettings(family: "Videos", includeInSearchAndAI: nil, pinned: false)
        #expect(defaults.stringArray(forKey: hiddenKey) == ["X", "YouTube"])

        // A no-op write reports nothing changed and writes nothing.
        let same = try await store.setSourceSettings(family: "youtube", includeInSearchAndAI: nil, pinned: false)
        let sameJSON = try #require(try JSONSerialization.jsonObject(with: Data(same.utf8)) as? [String: Any])
        #expect(sameJSON["updated"] as? Bool == false)

        // The tab bar keeps at least one pinned family.
        defaults.set(StudioSidebarTab.allCases.filter { $0 != .papers }.map(\.rawValue), forKey: hiddenKey)
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "papers", includeInSearchAndAI: nil, pinned: false)
        }
        #expect(try rows(try store.getSourceSettings())["papers"]?["can_unpin"] as? Bool == false)

        // Unknown family, and a call that changes nothing, are refused.
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "slack", includeInSearchAndAI: false, pinned: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setSourceSettings(family: "papers", includeInSearchAndAI: nil, pinned: nil)
        }

        // Registered, and the schema's family enum is the reader's ids.
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        #expect(tools.contains { $0.name == "get_source_settings" })
        let setter = try #require(tools.first { $0.name == "set_source_settings" })
        let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
        let family = try #require(properties["family"] as? [String: Any])
        #expect(family["enum"] as? [String] == MCPDataStore.sourceFamilyIDs)
        #expect(MCPDataStore.sourceFamilyIDs == ["articles", "papers", "books", "meetings", "podcasts", "youtube", "x"])
    }

    @Test("The Zoom recordings only Zoom can convert are the Meetings tab's rows over MCP: listed with this Mac's folders, resolved only for a folder the scan itself listed")
    func unconvertedZoomRecordingsOverMCP() async throws {
        // The product owner (2026-09-20): a background pass opening a raw `.zoom` file
        // in Zoom put Zoom's unknown-source dialog on screen at every launch.
        // The list and the row's two buttons are the whole surface; nothing
        // opens Zoom but the learner's word, here or in the app.
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let tools = MCPToolRegistry(store: store).tools
        let list = try #require(tools.first { $0.name == "list_unconverted_zoom_recordings" })
        #expect((list.inputSchema["required"] as? [String])?.isEmpty == true)
        let resolve = try #require(tools.first { $0.name == "resolve_unconverted_zoom_recording" })
        #expect(resolve.inputSchema["required"] as? [String] == ["folder_path", "action"])
        let properties = try #require(resolve.inputSchema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["convert", "ignore", "unignore"])
        #expect(resolve.description.contains("Ask the learner before converting"))

        // The list answers this Mac's Zoom folders and never throws, whatever is in them.
        let listed = try #require(
            try JSONSerialization.jsonObject(with: Data(try await store.listUnconvertedZoomRecordings().utf8)) as? [String: Any]
        )
        let recordings = try #require(listed["recordings"] as? [[String: Any]])
        #expect(listed["count"] as? Int == recordings.count)
        #expect(listed["folders"] is [String])
        for row in recordings {
            #expect(row["folder_path"] is String && row["title"] is String && row["started_at"] is String)
            #expect(row["ignored"] is Bool)
        }

        // A folder the scan did not list is refused before anything is opened or written,
        // whatever the action; so is an action the row does not have.
        let unknown = "/nowhere/2026-01-01 00.00.00 Nobody"
        for action in ["convert", "ignore", "unignore", "delete"] {
            await #expect(throws: MCPError.self) {
                _ = try await store.resolveUnconvertedZoomRecording(folderPath: unknown, action: action)
            }
        }
    }

    /// Automatic audio over MCP — its only surface since 2026-09-22. The product owner (2026-09-20):
    /// "always generate audio for explainers" — the switch has to be readable
    /// and settable from an assistant like every other setting, and the
    /// explainers' switch is one of five, keyed by the automation kind. The
    /// voice is handed in rather than read from this Mac's Keychain, so the
    /// gate the pane applies — free always, paid behind consent — is pinned
    /// deterministically.
    @Test("get_automatic_audio_settings and set_automatic_audio_settings drive automatic audio")
    func automaticAudioSettingsToolsDriveTheTextToSpeechPane() async throws {
        // The paid voice is priced by OpenRouter's catalog, which unit tests
        // pin (`AudioPriceFixture`) rather than read.
        try await OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            let (store, tmpPath) = try makeStore()
            defer { cleanup(tmpPath) }
            let defaults = UserDefaults.standard
            var keys = SourceAudioAutomation.automatable.map(\.preferenceKey)
            keys += SourceAudioAutomation.automatableSourceTypes.compactMap {
                SourceAudioAutomation.constraintPreferenceKey(for: $0)
            }
            keys.append(SourceAudioAutomation.paidVoiceConsentPreferenceKey)
            let prior = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in prior {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
            for key in keys { defaults.removeObject(forKey: key) }

            let free = AutomaticAudioSelection(
                provider: .openRouter, model: "deepgram/flux-tts:free", voice: "aura", allowsPaidVoices: false
            )
            let paid = AutomaticAudioSelection(
                provider: .openRouter, model: "hexgrad/kokoro-82m", voice: "af_heart", allowsPaidVoices: false
            )
            func object(_ json: String) throws -> [String: Any] {
                try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            func rows(_ json: String) throws -> [String: [String: Any]] {
                let kinds = try #require(try object(json)["kinds"] as? [[String: Any]])
                return Dictionary(uniqueKeysWithValues: kinds.map { ($0["kind"] as! String, $0) })
            }

            // Read: one row per kind in the pane's order, the explainers' among
            // them, every switch off, and a free voice that may run.
            let initialJSON = try await store.getAutomaticAudioSettings(selection: free)
            let initial = try object(initialJSON)
            let kindOrder = try #require(initial["kinds"] as? [[String: Any]]).map { $0["kind"] as? String }
            #expect(kindOrder == ["article", "paper", "book", "course", "explainer"])
            let initialRows = try rows(initialJSON)
            #expect(initialRows["explainer"]?["enabled"] as? Bool == false)
            #expect(initialRows["explainer"]?["title"] as? String == "Explainers")
            #expect(initialRows["explainer"]?["filter"] as? String == "")
            #expect(initial["automation_available"] as? Bool == true)
            #expect(initial["allow_paid_voices"] as? Bool == false)
            #expect(initial["settings_pane"] == nil)
            #expect((initial["voice"] as? [String: Any])?["rate"] as? String == "free")

            // Explainers on, by the pane's plural: the explainers' key alone moves,
            // and generate_explainer's rule now says the audio starts unasked.
            let armed = try object(try await store.setAutomaticAudioSettings(
                kind: "explainers", enabled: true, filter: nil, allowPaidVoices: nil, selection: free
            ))
            #expect(armed["updated"] as? Bool == true)
            #expect(armed["changed"] as? [String] == ["enabled"])
            #expect((armed["kind"] as? [String: Any])?["enabled"] as? Bool == true)
            #expect(defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            #expect(!defaults.bool(forKey: SourceAudioAutomation.articlesPreferenceKey))
            #expect(MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
                kind: SourceAudioAutomation.explainerKind, selection: free
            ))
            #expect(!MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(kind: "article", selection: free))

            // A no-op write reports nothing changed; off by the switch title.
            let same = try object(try await store.setAutomaticAudioSettings(
                kind: "explainer", enabled: true, filter: nil, allowPaidVoices: nil, selection: free
            ))
            #expect(same["updated"] as? Bool == false)
            _ = try await store.setAutomaticAudioSettings(
                kind: "Explainers", enabled: false, filter: nil, allowPaidVoices: nil, selection: free
            )
            #expect(!defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))

            // A paid voice without consent cannot arm a switch — the pane's switch
            // is disabled in that state — and the reader says why.
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(
                    kind: "explainer", enabled: true, filter: nil, allowPaidVoices: nil, selection: paid
                )
            }
            #expect(!defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            let priced = try object(try await store.getAutomaticAudioSettings(selection: paid))
            #expect(priced["automation_available"] as? Bool == false)
            #expect((priced["unavailable_reason"] as? String)?.contains("Allow paid voices") == true)
            #expect((priced["voice"] as? [String: Any])?["requires_paid_consent"] as? Bool == true)
            #expect(priced["paid_consent_quote"] is [String: Any])

            // Consent granted in the same call arms the switch on the paid voice.
            let consented = try object(try await store.setAutomaticAudioSettings(
                kind: "explainer", enabled: true, filter: nil, allowPaidVoices: true, selection: paid
            ))
            #expect(consented["changed"] as? [String] == ["allow_paid_voices", "enabled"])
            #expect(defaults.bool(forKey: SourceAudioAutomation.paidVoiceConsentPreferenceKey))
            #expect(defaults.bool(forKey: SourceAudioAutomation.explainersPreferenceKey))
            #expect(consented["automation_available"] as? Bool == true)

            // An empty rule is a cleared rule and needs no model call.
            let cleared = try object(try await store.setAutomaticAudioSettings(
                kind: "paper", enabled: nil, filter: "   ", allowPaidVoices: nil, selection: free
            ))
            #expect(cleared["updated"] as? Bool == false)
            // The preview reads the test host's own library, so its count is
            // whatever that library holds; the rule it previews is the empty one.
            let clearedPreview = try #require(cleared["filter_preview"] as? [String: Any])
            #expect(clearedPreview["filter"] as? String == "")
            #expect((clearedPreview["matching_source_count"] as? Int ?? -1) >= 0)

            // Nothing to change, an unknown kind, and a switch without a kind are refused.
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: "paper", enabled: nil, filter: nil, allowPaidVoices: nil, selection: free)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: "podcast", enabled: true, filter: nil, allowPaidVoices: nil, selection: free)
            }
            await #expect(throws: MCPError.self) {
                _ = try await store.setAutomaticAudioSettings(kind: nil, enabled: true, filter: nil, allowPaidVoices: nil, selection: free)
            }

            // Registered, and the schema's kind enum is the reader's kinds.
            let tools = MCPToolRegistry(store: MCPDataStore()).tools
            #expect(tools.contains { $0.name == "get_automatic_audio_settings" })
            let setter = try #require(tools.first { $0.name == "set_automatic_audio_settings" })
            let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
            let kind = try #require(properties["kind"] as? [String: Any])
            #expect(kind["enum"] as? [String] == MCPDataStore.automaticAudioKinds)
            #expect(MCPDataStore.automaticAudioKinds == ["article", "paper", "book", "course", "explainer"])
        }
    }

    /// `generate_explainer` writes through the same pipeline the Mac's Explain
    /// button uses, with the writer handed in; the audio step is the switch's
    /// business and is pinned by `ArticleSpeechContentTests`
    /// (`explainerAudioStartsWithoutConfirmationOnlyBehindItsSwitch`), because
    /// starting it here would reach the speech queue.
    @Test("generate_explainer saves the script beside its source with the writer handed in")
    func generateExplainerWritesTheScriptWithAnInjectedWriter() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        try Self.seedReadySource(
            kstore, id: "mito-1", url: "https://example.org/mito", title: "Mitochondria explained", sourceType: .article,
            content: "The full text of the article, long enough for a writer to work with."
        )

        let written = try await store.generateExplainer(
            sourceID: "mito-1",
            lengthName: "brief",
            generateAudio: false,
            confirmCost: false,
            backend: CannedMCPExplainerBackend(
                draft: ExplainerDraft(title: "Why mitochondria matter", script: "They make the energy.\n\nAnd more.")
            )
        )
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        #expect(payload["status"] as? String == "written")
        #expect(payload["explains_source_id"] as? String == "mito-1")
        #expect(payload["length"] as? String == "brief")
        #expect(payload["replaced_existing"] as? Bool == false)
        #expect(payload["audio"] == nil)
        let explainerID = try #require(payload["explainer_source_id"] as? String)
        #expect(explainerID == GeneratedExplainer.sourceID(explaining: "mito-1"))
        let explainer = try #require(try kstore.loadSourceForSync(explainerID))
        #expect(explainer.title == "Explainer: Mitochondria explained")
        #expect(explainer.sourceType == .article)
        #expect(explainer.audioAutomationKind == SourceAudioAutomation.explainerKind)
    }

    /// Settings › AI Usage › Your own key over MCP. The reader is pinned against
    /// a test-only key so the developer's Keychain never decides the outcome,
    /// and every refused write is one that throws before `ManagedAI.setOwnKey`
    /// runs — a real write here would store a key in the iCloud Keychain.
    @Test("get_own_router_key and set_own_router_key are Settings › AI Usage › Your own key")
    func ownRouterKeyToolsDriveTheAIUsagePane() throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        func payload(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        // No key: only leftover balance can pay, and the reader still names
        // the router and where to get a key for it.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        let none = try payload(try store.getOwnRouterKey())
        #expect(none["configured"] as? Bool == false)
        #expect(none["router"] is NSNull)
        #expect((none["billed_to"] as? String)?.hasPrefix("leftover ForeverLM balance") == true)
        #expect((none["billed_to"] as? String)?.contains("the learner's own OpenRouter key") == true)
        let routers = try #require(none["routers"] as? [[String: Any]])
        #expect(routers.map { $0["id"] as? String } == ["openrouter"])
        #expect(routers.allSatisfy { ($0["keys_url"] as? String)?.hasPrefix("https://") == true })
        // OpenRouter also carries the text-to-speech voices and the speech-to-text
        // models, and the key pays for those; a plugin told "text models" would
        // quote the learner the wrong bill.
        let openRouterRow = try #require(routers.first { $0["id"] as? String == "openrouter" })
        #expect(openRouterRow["key_pays_for"] as? String == "text, voices, speech-to-text, images and video")
        #expect(openRouterRow["balance_still_pays_for"] == nil)

        // A stored key: the router, its label and the last four characters,
        // and never the key itself.
        let secret = "sk-or-v1-test-only-key-ABCD"
        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: secret))
        let storedJSON = try store.getOwnRouterKey()
        #expect(!storedJSON.contains(secret))
        let stored = try payload(storedJSON)
        #expect(stored["configured"] as? Bool == true)
        #expect(stored["router"] as? String == "openrouter")
        #expect(stored["router_label"] as? String == "OpenRouter")
        #expect(stored["key_suffix"] as? String == "ABCD")
        #expect(stored["key_pays_for"] as? String == "text, voices, speech-to-text, images and video")
        #expect(stored["balance_still_pays_for"] as? String == "nothing while the key is stored")

        // Refused before anything is written: an unknown router (Ramp Router
        // included, since its removal on 2026-09-23), key beside clear, a store
        // with no key, and a paste that is not a key.
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "anthropic", key: "sk-something-long", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "ramp", key: "sk-something-long", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "sk-something-long", clear: true) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "   ", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "short", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "has a space in it", clear: false) }
        #expect(throws: MCPError.self) { _ = try store.setOwnRouterKey(router: "openrouter", key: "non-ascii-ключ-1234", clear: false) }

        // Registered: the reader on the read-only list, the writer's router enum
        // the same ids the reader reports, and the desktop-only gateway list
        // carries both (`workers/shared/public-mcp-tools.ts`).
        let registry = MCPToolRegistry(store: MCPDataStore())
        #expect(registry.tools.contains { $0.name == "get_own_router_key" })
        let setter = try #require(registry.tools.first { $0.name == "set_own_router_key" })
        let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
        let router = try #require(properties["router"] as? [String: Any])
        #expect(router["enum"] as? [String] == ManagedAI.OwnKeyRouter.allCases.map(\.rawValue))
        #expect(setter.inputSchema["required"] as? [String] == ["router"])
    }

    @Test("save_animation keeps the files in the library like a site, files the record under Animations linked to its sources, writes a player page around a lone video, reads a local file, updates by id, and refuses a Site's id")
    func mcpSaveAnimation() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()
        let paperURL = "https://doi.org/10.1093/cvr/cvaf001"
        // Seeded as articles rather than papers: a ready paper needs the metadata
        // and content-cleanup attestations, which this test has no interest in.
        // The address is what the resolution being tested reads.
        try Self.seedReadySource(kstore, id: "src-empa-1", url: paperURL, title: "Empagliflozin improves cardiac energetics", sourceType: .article)
        try Self.seedReadySource(kstore, id: "src-other-1", url: "https://example.com/other", title: "Another paper", sourceType: .article)
        func files(_ id: String) async throws -> [SiteFile] {
            try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: id))
        }

        // A new animation: SVG that plays, about the paper named three ways —
        // by id, by its address, and by a token nothing answers to. No account
        // is needed; nothing is hosted.
        let html = """
        <!doctype html><html><head><title>EMPA and the TCA cycle</title></head>
        <body><h1>EMPA and the TCA cycle</h1><svg id="cycle"></svg><button id="play">Play</button>
        <p><a href="foreverlm://source/src-empa-1">Empagliflozin improves cardiac energetics</a></p>
        <script>document.getElementById("play").onclick = () => {};</script></body></html>
        """
        let saved = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "EMPA and the TCA cycle",
            description: "How empagliflozin shifts substrate use in the TCA cycle, with and without the drug.",
            html: html, files: nil,
            sources: ["src-empa-1", paperURL, "nope-xyz"],
            homeNotebookID: nil, notebookIDs: []
        ))
        #expect(saved["status"] as? String == "saved")
        #expect(saved["section"] as? String == "animations")
        let animationID = try #require(saved["animation_id"] as? String)
        #expect(saved["url"] as? String == "foreverlm-site://\(animationID)/")
        #expect(saved["player_page_written"] as? Bool == false)
        let sources = try #require(saved["sources"] as? [[String: Any]])
        #expect(sources.count == 1, "the id and the address name one source")
        #expect(sources.first?["id"] as? String == "src-empa-1")
        #expect(sources.first?["title"] as? String == "Empagliflozin improves cardiac energetics")
        #expect(saved["unresolved_sources"] as? [String] == ["nope-xyz"])
        #expect(saved["source_cards"] as? Int == 1, "the page's source link is drawn as the card")
        let doc = try #require(saved["doc"] as? [String: Any])
        #expect(doc["kind"] as? String == "animation")
        #expect(doc["section"] as? String == "animations")
        #expect(doc["source_ids"] as? [String] == ["src-empa-1"])
        #expect(doc["id"] as? String == animationID)
        let message = try #require(saved["message"] as? String)
        #expect(message.contains("under Animations"))
        #expect(message.contains("linked to 1 source: Empagliflozin improves cardiac energetics"))
        #expect(message.contains("No library source answers to nope-xyz"))
        #expect(try await files(animationID).map(\.path) == ["foreverlm/source-cards.js", "index.html"])

        // The library holds the record as an animation, and the text copy is
        // the description, the page's words and the source's name.
        let records = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        let record = try #require(records.first { $0.id == animationID })
        #expect(record.kind == .animation)
        #expect(record.section == .animations)
        #expect(record.sourceIDs == ["src-empa-1"])
        #expect(record.linkedKind == .foreverlmSite)
        let copy = try parseJSON(try await store.readArtifact(artifactID: animationID))
        let markdown = try #require(copy["markdown"] as? String)
        #expect(markdown.hasPrefix("How empagliflozin shifts substrate use"))
        #expect(markdown.contains("Play"))
        #expect(markdown.contains("About: Empagliflozin improves cardiac energetics"))

        // list_animations answers for the whole library and for one source.
        let all = try parseJSON(try await store.listAnimations(sourceID: nil))
        #expect(all["animation_count"] as? Int == 1)
        let byPaper = try parseJSON(try await store.listAnimations(sourceID: "foreverlm://source/src-empa-1"))
        #expect(byPaper["animation_count"] as? Int == 1)
        #expect(byPaper["source_title"] as? String == "Empagliflozin improves cardiac energetics")
        let entry = try #require((byPaper["animations"] as? [[String: Any]])?.first)
        #expect(entry["url"] as? String == "foreverlm-site://\(animationID)/")
        #expect((entry["summary"] as? String)?.hasPrefix("How empagliflozin") == true)
        let byOther = try parseJSON(try await store.listAnimations(sourceID: "src-other-1"))
        #expect(byOther["animation_count"] as? Int == 0)
        do {
            _ = try await store.listAnimations(sourceID: "nothing-here-at-all")
            Issue.record("an unknown source was accepted")
        } catch {
            #expect(error.localizedDescription.contains("No library source answers"))
        }

        // A new animation whose sources resolve to nothing is refused; one
        // about no source is saved and says so.
        do {
            _ = try await store.saveAnimation(
                animation: nil, title: "Nowhere", description: nil, html: "<h1>x</h1>", files: nil,
                sources: ["zzz-not-a-source"], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("unresolved sources were accepted on a new animation")
        } catch {
            #expect(error.localizedDescription.contains("No library source answers to zzz-not-a-source"))
        }

        // A lone video gets a player page, kept beside the video.
        let video = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "Electron flow", description: "Rendered with Manim.",
            html: nil, files: [["path": "flow.mp4", "content_base64": Data(repeating: 1, count: 64).base64EncodedString()]],
            sources: [], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(video["player_page_written"] as? Bool == true)
        #expect((video["message"] as? String)?.contains("about no library source") == true)
        let videoID = try #require(video["animation_id"] as? String)
        let videoFiles = try await files(videoID)
        #expect(videoFiles.map(\.path) == ["flow.mp4", "index.html"])
        let player = try #require(videoFiles.first { $0.path == "index.html" }.flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(player.contains("<source src=\"flow.mp4\" type=\"video/mp4\">"))
        #expect(player.contains("<h1>Electron flow</h1>"))

        // A file on this Mac is read from disk; one too big to sync with the
        // record is refused by name.
        let render = URL(fileURLWithPath: tmpPath).appendingPathComponent("tca-render.mp4")
        try Data(repeating: 2, count: 2_200_000).write(to: render)
        let local = try parseJSON(try await store.saveAnimation(
            animation: nil, title: "TCA render", description: nil, html: nil,
            files: [["local_path": render.path]],
            sources: ["src-empa-1"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(local["player_page_written"] as? Bool == true)
        let localID = try #require(local["animation_id"] as? String)
        #expect(try await files(localID).first { $0.path == "tca-render.mp4" }?.data.count == 2_200_000)
        let huge = URL(fileURLWithPath: tmpPath).appendingPathComponent("huge.mp4")
        try Data(count: LocalSite.maxBytes + 1).write(to: huge)
        do {
            _ = try await store.saveAnimation(
                animation: nil, title: "Too big", description: nil, html: nil, files: [["local_path": huge.path]],
                sources: [], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("an animation too big to sync was saved")
        } catch {
            #expect(error.localizedDescription.contains("syncs through iCloud"))
        }

        // An update names the animation by id and carries only the files that
        // change: the stored page is kept, the generated script remade, and the
        // sources stay as they were when none are passed.
        let updated = try parseJSON(try await store.saveAnimation(
            animation: animationID, title: nil, description: nil, html: nil,
            files: [["path": "styles.css", "content": "svg { width: 100%; }"]],
            sources: [], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(updated["status"] as? String == "updated")
        #expect(updated["kept_files"] as? [String] == ["index.html"])
        #expect((updated["doc"] as? [String: Any])?["source_ids"] as? [String] == ["src-empa-1"])
        #expect(try await files(animationID).map(\.path) == ["foreverlm/source-cards.js", "index.html", "styles.css"])

        // An update that names sources replaces them; the library address names it too.
        let regrounded = try parseJSON(try await store.saveAnimation(
            animation: "foreverlm-site://\(animationID)/", title: nil, description: nil, html: nil,
            files: [["path": "styles.css", "content": "svg { width: 90%; }"]],
            sources: ["src-other-1"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect((regrounded["doc"] as? [String: Any])?["source_ids"] as? [String] == ["src-other-1"])
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).first { $0.id == animationID }?.sourceIDs == ["src-other-1"])

        // A Site's id is refused by both the maker and the remover.
        let site = try parseJSON(try await store.saveSite(
            site: nil, title: "Atlas", html: "<h1>Atlas</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil,
            homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(site["site_id"] as? String)
        #expect((site["doc"] as? [String: Any])?["kind"] as? String == "foreverlm_site")
        #expect((site["doc"] as? [String: Any])?["section"] as? String == "sites")
        do {
            _ = try await store.saveAnimation(
                animation: siteID, title: nil, description: nil, html: "<h1>x</h1>", files: nil,
                sources: [], homeNotebookID: nil, notebookIDs: []
            )
            Issue.record("a Site was updated as an animation")
        } catch {
            #expect(error.localizedDescription.contains("is a Site, not an animation"))
        }
        do {
            _ = try await store.deleteAnimation(animation: siteID)
            Issue.record("a Site was deleted as an animation")
        } catch {
            #expect(error.localizedDescription.contains("is a Site, not an animation"))
        }

        // delete_animation removes the entry with its files.
        let deleted = try parseJSON(try await store.deleteAnimation(animation: animationID))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["animation_id"] as? String == animationID)
        let remaining = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        #expect(!remaining.contains { $0.id == animationID })
        #expect(try await store.notebookFileStorage.localSiteFiles(artifactID: animationID) == nil, "the files go with the entry")
        #expect(remaining.filter(\.isAnimation).count == 2, "the video and the render stay")
        #expect(remaining.contains { $0.linkedKind == .foreverlmSite && !$0.isAnimation }, "the Site stays")

        // The registry, and the study chat's surface.
        #expect(Set(MCPToolRegistry.shared.tools.map(\.name)).isSuperset(of: ["save_animation", "list_animations", "delete_animation"]))
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["save_animation", "list_animations", "delete_animation"]))
    }

    // MARK: - Spaces of pages and a page's versions (docs/docs-design.md, "The Space", "Version history")

    /// The space rows bound to a throwaway defaults suite for this task
    /// (`PageSpaceRows.overrideDefaults`), never the standard defaults the
    /// Dev build and parallel suites share.
    private func withPageSpaceDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "MCPDataStoreTests.pageSpaces.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
            try await body(defaults)
        }
    }

    private func createdDocID(_ store: MCPDataStore, title: String, markdown: String) async throws -> String {
        let created = try parseJSON(try await store.createArtifact(
            title: title, homeNotebookID: nil, notebookIDs: [], markdown: markdown
        ))
        return try #require((created["doc"] as? [String: Any])?["id"] as? String)
    }

    /// A team's page, in a team this account owns and may write.
    private func createdTeamPage(_ store: MCPDataStore, markdown: String) async throws -> ArtifactMarkdownSnapshot {
        let now = Date()
        try store.knowledgeStore().saveTeam(TeamRecord(
            id: "team-pages", name: "Pages team", role: .owner, permission: .readWrite,
            zoneScope: .privateScope, zoneName: TeamRecord.zoneName(forTeamID: "team-pages"), zoneOwnerRecordName: nil,
            shareRecordName: nil, shareURL: nil, createdAt: now, joinedAt: now, updatedAt: now
        ))
        return try await store.notebookFileStorage.createArtifact(
            title: "The team's page", homeNotebookID: nil, linkedNotebookIDs: [], markdown: markdown, teamID: "team-pages"
        )
    }

    @Test("update_space makes, fills, moves, renames and deletes a space; list_spaces and list_docs read it")
    func mcpPageSpaces() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let aging = try await createdDocID(store, title: "Aging clocks", markdown: "# Aging clocks")
        let bio = try await createdDocID(store, title: "Bioelectric fields", markdown: "# Bioelectric fields")
        let trashed = try await createdDocID(store, title: "Old draft", markdown: "# Old draft")

        try await withPageSpaceDefaults { defaults in
            let created = try parseJSON(try await store.updatePageSpace(
                action: "create", spaceID: nil, name: "  🔬 Research \n project ", docIDs: [bio, bio, trashed]
            ))
            let space = try #require(created["space"] as? [String: Any])
            let id = try #require(space["id"] as? String)
            #expect(id.hasPrefix(PageSpaces.idPrefix))
            #expect(space["name"] as? String == "🔬 Research project")
            #expect(created["moved_doc_ids"] as? [String] == [bio, trashed], "each Doc once")
            #expect(defaults.string(forKey: PageSpaces.nameKey(spaceID: id)) == "🔬 Research project")
            #expect(defaults.string(forKey: PageSpaces.membershipKey(pageID: bio)) == id)

            // A page in the Trash stays in its space but is not listed there.
            _ = try await store.updateArtifact(artifactID: trashed, title: nil, homeNotebookID: nil, notebookIDs: nil, isArchived: true)
            let moved = try parseJSON(try await store.updatePageSpace(
                action: "move_docs", spaceID: id, name: nil, docIDs: [aging]
            ))
            let movedRow = try #require(moved["space"] as? [String: Any])
            let movedDocs = try #require(movedRow["docs"] as? [[String: Any]])
            #expect(movedDocs.map { $0["id"] as? String } == [aging, bio], "by title, the Trash left out")
            #expect(movedDocs.first?["kind"] as? String == "markdown")
            #expect(movedRow["doc_count"] as? Int == 2)

            // list_docs names each Doc's space.
            let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
            let docs = try #require(listing["docs"] as? [[String: Any]])
            #expect(docs.first { $0["id"] as? String == aging }?["space_id"] as? String == id)
            #expect(docs.first { $0["id"] as? String == aging }?["space_name"] as? String == "🔬 Research project")

            // A page is in one space at a time: moving it to a second takes it out of the first.
            let second = try parseJSON(try await store.updatePageSpace(
                action: "create", spaceID: nil, name: "Reading group", docIDs: [aging]
            ))
            let secondID = try #require((second["space"] as? [String: Any])?["id"] as? String)
            #expect(defaults.string(forKey: PageSpaces.membershipKey(pageID: aging)) == secondID)

            _ = try await store.updatePageSpace(action: "rename", spaceID: id, name: "Labs", docIDs: nil)
            let listed = try parseJSON(try await store.listPageSpaces())
            let rows = try #require(listed["spaces"] as? [[String: Any]])
            #expect(rows.map { $0["name"] as? String } == ["Labs", "Reading group"], "by name")
            #expect((rows.first?["docs"] as? [[String: Any]])?.map { $0["id"] as? String } == [bio])

            let removed = try parseJSON(try await store.updatePageSpace(
                action: "remove_docs", spaceID: nil, name: nil, docIDs: [aging]
            ))
            #expect(removed["removed_doc_ids"] as? [String] == [aging])
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: aging)) == nil)

            let deleted = try parseJSON(try await store.updatePageSpace(
                action: "delete", spaceID: id, name: nil, docIDs: nil
            ))
            #expect(deleted["deleted"] as? Bool == true)
            #expect(defaults.object(forKey: PageSpaces.nameKey(spaceID: id)) == nil)
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: bio)) == nil)
            #expect(defaults.object(forKey: PageSpaces.membershipKey(pageID: trashed)) == nil)
            let after = try parseJSON(try await store.listPageSpaces())
            #expect((after["spaces"] as? [[String: Any]])?.map { $0["id"] as? String } == [secondID])
            let remaining = try await store.notebookFileStorage.loadArtifacts(notebookID: nil).map(\.id)
            #expect(Set(remaining).isSuperset(of: [aging, bio, trashed]), "the pages stay")
            let relisted = try parseJSON(try await store.listArtifacts(notebookID: nil))
            #expect((relisted["docs"] as? [[String: Any]])?.first { $0["id"] as? String == bio }?["space_id"] is NSNull)
        }
    }

    @Test("update_space refuses an unknown action, a blank name, a missing space, an unknown Doc and a team's page, writing nothing")
    func mcpPageSpaceRefusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let page = try await createdDocID(store, title: "Mine", markdown: "# Mine")
        let team = try await createdTeamPage(store, markdown: "# Team")

        try await withPageSpaceDefaults { _ in
            func refused(_ action: String, _ spaceID: String?, _ name: String?, _ docIDs: [String]?, _ phrase: String) async {
                do {
                    _ = try await store.updatePageSpace(action: action, spaceID: spaceID, name: name, docIDs: docIDs)
                    Issue.record("\(action) was accepted")
                } catch let error as MCPError {
                    #expect(error.localizedDescription.contains(phrase), "\(error.localizedDescription)")
                } catch {
                    Issue.record("unexpected \(error)")
                }
            }
            await refused("archive", nil, "X", nil, "action must be")
            await refused("create", nil, "  ", [page], "name is required")
            await refused("create", nil, "Research", ["not-a-doc"], "Doc not found")
            await refused("create", nil, "Research", [page, team.artifact.id], "team's record")
            await refused("rename", "psp-missing", "X", nil, "Space not found")
            await refused("delete", nil, nil, nil, "space_id is required")
            #expect(PageSpaceRows.read() == PageSpaces(), "a refusal writes nothing")

            let created = try parseJSON(try await store.updatePageSpace(action: "create", spaceID: nil, name: "Research", docIDs: nil))
            let id = try #require((created["space"] as? [String: Any])?["id"] as? String)
            await refused("move_docs", id, nil, [], "doc_ids is required")
            await refused("remove_docs", nil, nil, nil, "doc_ids is required")
            #expect(PageSpaceRows.read().pageIDs([page, team.artifact.id], in: id).isEmpty)

            // Every Setting has an MCP route; a space's rows have theirs here, never set_app_setting.
            #expect(Set(MCPToolRegistry().tools.map(\.name)).isSuperset(of: ["list_spaces", "update_space"]))
            let settings = await MainActor.run { MCPDataStore.appSettingsCatalog().map { ($0.id, $0.preferenceKeys) } }
            for (id, keys) in settings {
                #expect(!keys.contains {
                    $0.hasPrefix(PageSpaces.namePreferenceKeyPrefix) || $0.hasPrefix(PageSpaces.membershipPreferenceKeyPrefix)
                }, "set_app_setting's \(id) writes a space's row")
            }
        }
    }

    @Test("list_doc_versions lists this Mac's versions newest first and reads one; restore_doc_version restores and keeps the body it replaced")
    func mcpDocVersions() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let docID = try await createdDocID(store, title: "Landscape", markdown: "# Landscape\n\nOne.")
        let empty = try parseJSON(try await store.listDocVersions(artifactID: docID))
        #expect(empty["version_count"] as? Int == 0)
        #expect(empty["can_restore"] as? Bool == true)

        // Two assistant writes: each keeps the body it replaced.
        let revision1 = try #require(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String)
        let written = try parseJSON(try await store.writeArtifact(
            artifactID: docID, markdown: "# Landscape\n\nTwo.", expectedRevision: revision1
        ))
        let revision2 = try #require(written["revision"] as? String)
        _ = try await store.writeArtifact(artifactID: docID, markdown: "# Landscape\n\nThree.", expectedRevision: revision2)

        let listed = try parseJSON(try await store.listDocVersions(artifactID: docID))
        #expect(listed["version_count"] as? Int == 2)
        let versions = try #require(listed["versions"] as? [[String: Any]])
        #expect(versions.map { $0["reason"] as? String } == ["assistant_edit", "assistant_edit"])
        #expect(versions.first?["summary"] as? String == "Before an AI edit")
        #expect(versions.first?["bytes"] as? Int == "# Landscape\n\nTwo.".utf8.count)
        let current = try #require(listed["current"] as? [String: Any])
        #expect(current["characters"] as? Int == "# Landscape\n\nThree.".count)
        let oldestID = try #require(versions.last?["version_id"] as? String)

        // One version's text, whole and by range.
        let read = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: oldestID))
        #expect((read["version"] as? [String: Any])?["markdown"] as? String == "# Landscape\n\nOne.")
        let ranged = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: oldestID, start: 13, length: 4))
        #expect((ranged["version"] as? [String: Any])?["markdown"] as? String == "One.")
        #expect((ranged["version"] as? [String: Any])?["is_complete"] as? Bool == false)

        // A stale revision and an unknown version are refused, and nothing changes.
        await #expect(throws: MCPError.self) {
            _ = try await store.restoreDocVersion(artifactID: docID, versionID: oldestID, expectedRevision: revision1)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.restoreDocVersion(artifactID: docID, versionID: "1-learnerEdit.md")
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nThree.")

        // The restore writes the version and keeps "Three." as a restore version, which undoes it.
        let restored = try parseJSON(try await store.restoreDocVersion(
            artifactID: docID, versionID: oldestID, expectedRevision: current["revision"] as? String
        ))
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nOne.")
        #expect(restored["revision"] as? String == (try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String))
        let keptID = try #require(restored["replaced_body_version_id"] as? String)
        let afterRestore = try parseJSON(try await store.listDocVersions(artifactID: docID, versionID: keptID))
        #expect(afterRestore["version_count"] as? Int == 3)
        #expect((afterRestore["version"] as? [String: Any])?["reason"] as? String == "restore")
        #expect((afterRestore["version"] as? [String: Any])?["markdown"] as? String == "# Landscape\n\nThree.")
        _ = try await store.restoreDocVersion(artifactID: docID, versionID: keptID)
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String == "# Landscape\n\nThree.")
    }

    @Test("restore_doc_version refuses a team's page and a linked page, as the app's Version History does")
    func mcpDocVersionRefusals() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        // A team's page: its versions are listed, never restored here.
        let team = try await createdTeamPage(store, markdown: "# Team\n\nOne.")
        _ = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: team.artifact.id, markdown: "# Team\n\nTwo.", expectedRevision: team.revision, versionReason: .assistantEdit
        )
        let listed = try parseJSON(try await store.listDocVersions(artifactID: team.artifact.id))
        #expect(listed["version_count"] as? Int == 1)
        #expect(listed["can_restore"] as? Bool == false)
        let versionID = try #require((listed["versions"] as? [[String: Any]])?.first?["version_id"] as? String)
        do {
            _ = try await store.restoreDocVersion(artifactID: team.artifact.id, versionID: versionID)
            Issue.record("a team's page was restored")
        } catch {
            #expect(error.localizedDescription.contains("team's page"), "\(error.localizedDescription)")
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: team.artifact.id))["markdown"] as? String == "# Team\n\nTwo.")

        // A linked page has no body of ForeverLM's own to restore.
        let linked = try parseJSON(try await store.linkPageArtifact(
            urlString: "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d",
            title: "Atlas", text: "# Atlas", homeNotebookID: nil, notebookIDs: []
        ))
        let linkedID = try #require((linked["doc"] as? [String: Any])?["id"] as? String)
        #expect(try parseJSON(try await store.listDocVersions(artifactID: linkedID))["can_restore"] as? Bool == false)
        do {
            _ = try await store.restoreDocVersion(artifactID: linkedID, versionID: versionID)
            Issue.record("a linked page was restored")
        } catch {
            #expect(error.localizedDescription.contains("read-only copy"), "\(error.localizedDescription)")
        }
        #expect(Set(MCPToolRegistry().tools.map(\.name)).isSuperset(of: ["list_doc_versions", "restore_doc_version"]))
    }

}

@Suite("MCP Protocol")
struct MCPProtocolTests {
    private func request(
        method: String,
        headers: [String: String] = [:],
        params: [String: Any] = [:],
        id: Any? = 1
    ) throws -> HTTPRequest {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let id {
            body["id"] = id
        }

        return HTTPRequest(
            method: "POST",
            path: "/mcp",
            queryString: "",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func jsonBody(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test("initialized notification returns accepted empty response")
    func initializedNotificationReturnsAcceptedEmptyResponse() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "notifications/initialized", id: nil),
            access: .internalFullAccess
        )

        #expect(response.status == 202)
        #expect(response.body.isEmpty)
        #expect(response.headers["Content-Type"] == nil)
    }

    @Test("Expired MCP sessions tell clients to initialize again")
    func expiredSessionReturnsNotFound() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/list",
                headers: ["mcp-session-id": "expired-after-app-relaunch"],
                id: 1
            ),
            access: .internalFullAccess
        )
        let json = try jsonBody(response)
        let error = try #require(json["error"] as? [String: Any])

        #expect(response.status == 404)
        #expect(error["code"] as? Int == -32600)
        #expect((error["message"] as? String)?.contains("initialize") == true)
    }

    @Test("Missing MCP session IDs remain bad requests")
    func missingSessionReturnsBadRequest() async throws {
        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "tools/list", id: 1),
            access: .internalFullAccess
        )

        #expect(response.status == 400)
    }

    @Test("resource list handlers advertise empty resources")
    func resourceListHandlersAdvertiseEmptyResources() async throws {
        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: .internalFullAccess
        )
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let resources = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "resources/list", headers: headers, id: 2),
            access: .internalFullAccess
        )
        let resourcesJSON = try jsonBody(resources)
        let resourcesResult = try #require(resourcesJSON["result"] as? [String: Any])
        let resourceItems = try #require(resourcesResult["resources"] as? [Any])
        #expect(resourceItems.isEmpty)

        let templates = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "resources/templates/list", headers: headers, id: 3),
            access: .internalFullAccess
        )
        let templatesJSON = try jsonBody(templates)
        let templatesResult = try #require(templatesJSON["result"] as? [String: Any])
        let templateItems = try #require(templatesResult["resourceTemplates"] as? [Any])
        #expect(templateItems.isEmpty)
    }

    @Test("MCP status tool call returns active status")
    func mcpStatusToolCallReturnsActiveStatus() async throws {
        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: .internalFullAccess
        )
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let response = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "get_mcp_status",
                    "arguments": [:] as [String: Any],
                ],
                id: 2
            ),
            access: .internalFullAccess
        )
        let json = try jsonBody(response)
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(payload["status"] as? String == "active")
        #expect(payload["server"] as? String == "ForeverLM MCP")
    }

    @Test("Ingest-scoped requests see and reach only the ingest surface")
    func ingestScopedRequestsAreFiltered() async throws {
        let ingest = MCPAccessContext(clientID: "dyn_conn", scope: .ingest, connectorLabel: "Feed Bot")

        let initialize = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "initialize", id: 1),
            access: ingest
        )
        let initJSON = try jsonBody(initialize)
        let initResult = try #require(initJSON["result"] as? [String: Any])
        let instructions = try #require(initResult["instructions"] as? String)
        #expect(instructions.contains("ingest-only"))

        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let headers = ["mcp-session-id": sessionID]

        let list = await MCPProtocolHandler.shared.handleRequest(
            try request(method: "tools/list", headers: headers, id: 2),
            access: ingest
        )
        let listJSON = try jsonBody(list)
        let listResult = try #require(listJSON["result"] as? [String: Any])
        let toolDicts = try #require(listResult["tools"] as? [[String: Any]])
        let names = Set(toolDicts.compactMap { $0["name"] as? String })
        #expect(names == MCPToolRegistry.ingestAllowedTools)

        let refusal = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "list_sources",
                    "arguments": [:] as [String: Any],
                ],
                id: 3
            ),
            access: ingest
        )
        let refusalJSON = try jsonBody(refusal)
        let error = try #require(refusalJSON["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32001)
        #expect((error["message"] as? String)?.contains("mcp:ingest") == true)

        // A legacy alias cannot slip past the gate either.
        let aliasRefusal = await MCPProtocolHandler.shared.handleRequest(
            try request(
                method: "tools/call",
                headers: headers,
                params: [
                    "name": "start_review_session",
                    "arguments": [:] as [String: Any],
                ],
                id: 4
            ),
            access: ingest
        )
        let aliasJSON = try jsonBody(aliasRefusal)
        #expect(aliasJSON["error"] != nil)
    }
}

// HTTPResponse.json takes Any; a scalar top level must serialize instead of
// producing an empty body (JSONSerialization would otherwise throw an ObjC
// exception that `try?` cannot catch).
@Suite("MCP HTTP JSON Responses")
struct MCPHTTPResponseJSONTests {
    @Test("dictionary payloads serialize to a JSON body")
    func dictionaryPayloadSerializes() throws {
        let response = HTTPResponse.json(["ok": true])
        let text = try #require(String(data: response.body, encoding: .utf8))
        #expect(text == #"{"ok":true}"#)
        #expect(response.status == 200)
    }

    @Test("scalar top-level values serialize instead of returning an empty body")
    func scalarPayloadSerializes() throws {
        let stringResponse = HTTPResponse.json("ok")
        #expect(String(data: stringResponse.body, encoding: .utf8) == #""ok""#)

        let numberResponse = HTTPResponse.json(42)
        #expect(String(data: numberResponse.body, encoding: .utf8) == "42")
    }
}

@Suite("MCP relay recovery")
struct MCPRelayRecoveryTests {
    @Test("only unanimous explicit auth rejection invalidates credentials")
    func explicitAuthenticationRejection() {
        #expect(
            MCPRelayClient.failureKind(forHTTPStatusCodes: [401, 403])
                == .authenticationRejected
        )
    }

    @Test("network and ambiguous failures preserve credentials")
    func transientFailuresPreserveCredentials() {
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: []) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [nil, nil]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [500, 503]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [401, nil]) == .transient)
        #expect(MCPRelayClient.failureKind(forHTTPStatusCodes: [401, 500]) == .transient)
    }
}

@Suite("MCP tool argument normalization")
struct MCPToolArgumentNormalizationTests {
    /// The bug this guards against: a model that fills every slot sends
    /// `added_from ""`, and the date parser refused it as "not a date" — twice
    /// in one turn on 2026-09-02 — when the caller plainly meant no filter.
    @Test("blank optional filters on a read-only tool are dropped")
    func blankFiltersOnReadOnlyToolAreDropped() {
        let normalized = MCPToolRegistry.normalizedArguments(
            toolName: "search_sources_semantic",
            arguments: [
                "query": "aging atlas",
                "added_from": "",
                "added_to": "  \n",
                "source_type": "",
                "limit": 8,
            ]
        )
        #expect(normalized["query"] as? String == "aging atlas")
        #expect(normalized["limit"] as? Int == 8)
        #expect(normalized["added_from"] == nil)
        #expect(normalized["added_to"] == nil)
        #expect(normalized["source_type"] == nil)
    }

    /// Mutating tools document `""` as a deliberate value ("pass instructions
    /// \"\" to clear"), so nothing may be dropped from them.
    @Test("mutating tools keep an empty string as sent")
    func mutatingToolsKeepEmptyStrings() {
        let arguments: [String: Any] = ["notebook_id": "p1", "instructions": ""]
        let normalized = MCPToolRegistry.normalizedArguments(
            toolName: "update_notebook",
            arguments: arguments
        )
        #expect(normalized["instructions"] as? String == "")
        #expect(normalized.count == 2)
    }


}


/// The Cloudflare gateway used to carry a second, hand-written copy of this
/// contract, and it had silently fallen 98 tools behind the app. The registry is
/// now the only source of truth: this suite writes it out for the Worker to
/// compile, and fails the moment the two disagree.
@Suite("MCP tool contract")
struct MCPToolContractTests {

    /// `workers/shared/mcp-tools.generated.json`, resolved from this file so the
    /// test does not depend on the working directory a runner happens to use.
    static var catalogueURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("workers/shared/mcp-tools.generated.json")
    }

    /// Sorted by name with sorted keys throughout, so the committed file changes
    /// only when a tool's contract changes — never because a dictionary iterated
    /// in a different order. `readOnlyHint` is the gateway's only read-only list:
    /// it publishes it and lets only those calls fall back to the hosted mirror
    /// after the relay may have handed them to the Mac.
    static func canonicalJSON(for tools: [MCPToolDef]) throws -> String {
        let entries: [[String: Any]] = tools
            .sorted { $0.name < $1.name }
            .map {
                [
                    "name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema,
                    "readOnlyHint": MCPToolRegistry.isReadOnlyTool($0.name),
                ]
            }
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidInput("tool catalogue is not UTF-8")
        }
        return text + "\n"
    }

    @Test("every registry tool is in the catalogue the gateway publishes")
    func catalogueMatchesRegistry() throws {
        let generated = try Self.canonicalJSON(for: MCPToolRegistry().tools)

        // Regenerating is `rm workers/shared/mcp-tools.generated.json` and running
        // this suite again: a missing catalogue is written rather than reported,
        // because xcodebuild does not reliably forward an environment variable to
        // the test host. A catalogue that exists and disagrees is still a failure.
        let missing = !FileManager.default.fileExists(atPath: Self.catalogueURL.path)
        if missing || ProcessInfo.processInfo.environment["FOREVERLM_WRITE_TOOL_CONTRACT"] == "1" {
            try generated.write(to: Self.catalogueURL, atomically: true, encoding: .utf8)
            return
        }

        let committed = try String(contentsOf: Self.catalogueURL, encoding: .utf8)
        #expect(
            committed == generated,
            """
            workers/shared/mcp-tools.generated.json is out of date with MCPToolRegistry.
            Regenerate it:
              rm workers/shared/mcp-tools.generated.json
              xcodebuild test -scheme 'ForeverLM (macOS)' \
                -only-testing:ForeverLMMacUnitTests/MCPToolContractTests
            """
        )
    }

    /// The gateway sends a read to the hosted mirror after the Mac may have run
    /// it, and never a write (design review 2026-10-09, fix-first 2), so a tool on
    /// the read-only list must change nothing. These five were on the wrong side.
    @Test("report_connector_status is a write; the reading view, animations, canvas versions and share requests are reads")
    func readOnlyClassification() {
        for name in ["get_article_reading_view", "list_animations", "list_canvas_versions", "list_share_requests"] {
            #expect(MCPToolRegistry.isReadOnlyTool(name), "\(name)")
            #expect(MCPToolRegistry.annotations(for: name)["readOnlyHint"] as? Bool == true, "\(name)")
            #expect(MCPToolRegistry.storeGateMode(for: name) == .shared, "\(name)")
        }
        // It records the plugin's health on this Mac's Device record and in the
        // connector's preferences.
        #expect(!MCPToolRegistry.isReadOnlyTool("report_connector_status"))
        #expect(MCPToolRegistry.annotations(for: "report_connector_status")["readOnlyHint"] as? Bool == false)
        #expect(MCPToolRegistry.storeGateMode(for: "report_connector_status") == .exclusive)
    }

    @Test("no tool is advertised without a description or an object schema")
    func everyToolCarriesAContract() throws {
        for tool in MCPToolRegistry().tools {
            #expect(!tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(tool.name) has no description")
            #expect(tool.inputSchema["type"] as? String == "object", "\(tool.name) has no object input schema")
        }
    }

    /// Schema v2 §3.5.3 (WP12b): under generation 2 every synced key that stays a Setting is settable over
    /// MCP, a Notebook Collection's name only through `update_notebook_collection` and never through
    /// `set_app_setting`. The catalog's `records` hold keys that generation 2 moves into records, except
    /// `studio.courseOrder` and `meetingFolder.image.*`, which stay Settings for now (WP9's correction, and
    /// the icon satellite still to come); they keep their generation-1 routes.
    @Test("every Setting under generation 2 is settable over MCP, a collection's name only through update_notebook_collection")
    @MainActor
    func everyGenerationTwoSettingIsSettableOverMCP() throws {
        let catalog = try SettingsCatalogTests.loadCatalog()
        let records = Set(catalog.records.keys)
        // A retired key is never written (the generator refuses a route on one), so there is
        // nothing to set: only the live keys and patterns need a route.
        for key in SyncedPreferenceKeys.synced where SyncedPreferenceKeys.isSetting(key) && !records.contains(key) {
            let row = catalog.keys[key]
            #expect(row != nil && (row?["retired"] as? Bool == true || SettingsCatalogTests.mcp(row ?? [:]) != nil),
                    "\(key) is a Setting with no MCP route in the catalog")
        }
        for prefix in SyncedPreferenceKeys.syncedPrefixes(for: .two) where !records.contains(prefix) {
            let routed = (catalog.families[prefix] ?? []).allSatisfy { $0["retired"] as? Bool == true || SettingsCatalogTests.mcp($0) != nil }
                && catalog.families[prefix] != nil
            #expect(routed || catalog.leftOut[prefix] != nil, "\(prefix) is a Setting family with no MCP route and not left out to its own writer")
        }
        let collectionName = NotebookCollections.namePreferenceKeyPrefix + "nbc-1"
        #expect(SyncedPreferenceKeys.isSetting(collectionName) && catalog.leftOut[NotebookCollections.namePreferenceKeyPrefix] != nil)
        let tools = Set(MCPToolRegistry().tools.map(\.name))
        #expect(tools.contains("update_notebook_collection"))
        for entry in MCPDataStore.appSettingsCatalog() {
            #expect(!entry.preferenceKeys.contains { $0.hasPrefix(NotebookCollections.namePreferenceKeyPrefix) },
                    "set_app_setting's \(entry.id) writes a Notebook Collection's name")
        }
    }
}

@Suite("import_local_file routes")
struct MCPLocalFileImportRouteTests {
    private func kind(_ ext: String, pages: Int? = nil, _ requested: String? = nil) throws -> MCPDataStore.LocalFileImportKind {
        try MCPDataStore.localFileImportKind(fileExtension: ext, pdfPageCount: pages, requested: requested)
    }

    @Test("Left to the tool, a long PDF is a book and a short one a paper")
    func pdfByPageCount() throws {
        #expect(try kind("pdf", pages: 12) == .paper)
        #expect(try kind("pdf", pages: 99, "auto") == .paper)
        #expect(try kind("PDF", pages: 100) == .book)
        #expect(try kind("pdf", pages: 400, " Auto ") == .book)
    }

    @Test("An asked-for kind wins for a PDF, but a PDF is never text")
    func pdfAsAsked() throws {
        #expect(try kind("pdf", pages: 400, "paper") == .paper)
        #expect(try kind("pdf", pages: 8, "book") == .book)
        #expect(throws: MCPError.self) { try kind("pdf", pages: 8, "text") }
    }

    @Test("EPUB and Kindle files are books, text and Markdown files text")
    func otherFormats() throws {
        for ext in ["epub", "azw", "azw3", "mobi", "prc"] {
            #expect(try kind(ext) == .book, "\(ext)")
            #expect(throws: MCPError.self) { try kind(ext, "paper") }
        }
        for ext in ["txt", "md", "markdown"] {
            #expect(try kind(ext) == .text, "\(ext)")
            #expect(throws: MCPError.self) { try kind(ext, "book") }
        }
    }

    @Test("An unknown format or kind is refused")
    func refusals() {
        #expect(throws: MCPError.self) { try kind("mp4") }
        #expect(throws: MCPError.self) { try kind("") }
        #expect(throws: MCPError.self) { try kind("pdf", pages: 3, "novel") }
    }

    @Test("import_local_file is registered as paid, open-world work no ingest plugin may call")
    func registration() {
        #expect(MCPToolRegistry.shared.tools.contains { $0.name == "import_local_file" })
        #expect(MCPToolRegistry.paidWorkToolNames.contains("import_local_file"))
        #expect(!MCPToolRegistry.isToolAllowed("import_local_file", scope: .ingest))
    }
}

/// On 2026-10-12 seven `import_local_pdf_as_paper` calls sent together held
/// the store alone one after another, a minute or more each; three clients
/// timed out, a `filter_sources` waited behind them, and a call cancelled
/// during Source Content Cleanup deleted the PDF of the paper it had just
/// saved, which then read "PDF needed" with no content.
@Suite("A local PDF imported as a paper")
struct MCPLocalPaperImportTests {
    private static let paperText = "Phase separated droplets concentrate enzymes with their substrates, and the cell tunes them by temperature and salt."

    private func makeStore() throws -> (MCPDataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_local_paper_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: dir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, dir)
    }

    /// One US-letter page per string, drawn with CoreText so PDFKit reads the
    /// words back; an empty string is a blank page.
    private func writePDF(_ pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 10, nil)]
                ))
                context.textPosition = CGPoint(x: 36, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func stage(_ store: MCPDataStore, pages: [String], in dir: URL) async throws -> MCPDataStore.StagedLocalPaper {
        let pdf = dir.appendingPathComponent("Droplets.pdf")
        try writePDF(pages, to: pdf)
        guard case .staged(let staged) = try await store.stageLocalPDFAsPaper(filePath: pdf.path, title: "Droplets in the cell") else {
            throw MCPError.invalidInput("the PDF was taken for a paper the library already held")
        }
        return staged
    }

    private func pdfIsOnDisk(_ article: StudioArticle, in dir: URL) -> Bool {
        guard let relative = article.localFilePath else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    @Test("The paper is saved with its PDF and its text before any model reads it")
    func stagedPaperIsSavedWithItsPDF() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.sourceType == .paper)
        #expect(saved.title == "Droplets in the cell")
        #expect(saved.state == .queued)
        #expect(saved.requiresPaperMetadataAI, "the Paper Metadata model has not read it yet")
        #expect(saved.localFilePath == "Papers/Droplets.pdf")
        #expect(pdfIsOnDisk(saved, in: dir))
        let raw = try store.knowledgeStore().loadPaperContentPreparation(saved.id)?.raw
        #expect(raw?.contains("Phase separated droplets") == true)
        #expect(staged.firstPageText.contains("Phase separated droplets"))

        // Staging held the store only around its own match and save.
        await store.acquireToolOperation(.exclusive)
        await store.releaseToolOperation()
    }

    @Test("A read that fails is saved on the paper, which keeps its PDF")
    func failedReadKeepsThePDF() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A blank first page fails the metadata step before any model call.
        let staged = try await stage(store, pages: ["", Self.paperText], in: dir)
        #expect(staged.firstPageText.isEmpty)

        do {
            _ = try await store.finishStagedLocalPaper(staged)
            Issue.record("a paper with no first-page text was read")
        } catch {
            #expect(error.localizedDescription.contains("no readable paper text"))
            #expect(error.localizedDescription.contains("stays in the library with its PDF (id: \(staged.article.id))"))
        }
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.state == .error)
        #expect(saved.errorMessage?.contains("no readable paper text") == true)
        #expect(pdfIsOnDisk(saved, in: dir), "the failure took the PDF away from the paper")
    }

    @Test("A stopped read leaves the paper pending with its PDF, not failed")
    func stoppedReadLeavesThePaperPending() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        await #expect(throws: CancellationError.self) {
            _ = try await store.finishStagedLocalPaper(staged) { _, _ in throw CancellationError() }
        }
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.state == .queued)
        #expect(saved.errorMessage == nil)
        #expect(saved.requiresPaperMetadataAI, "the app's own metadata pass finishes it")
        #expect(pdfIsOnDisk(saved, in: dir), "a stopped import took the PDF away from the paper it saved")
    }

    @Test("Another call takes the store, even alone, while a paper's models read it")
    func readingHoldsNoGate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let entered = MCPTestSignal()
        let release = MCPTestSignal()
        let finishing = Task {
            try await store.finishStagedLocalPaper(staged) { article, firstPage in
                await entered.signal()
                await release.wait()
                #expect(firstPage.contains("Phase separated droplets"))
                article.title = "Droplets, read"
                article.author = "Zara Holt"
                _ = article.attestPaperMetadataExtractionAfterLLM()
                return "read by the test"
            }
        }
        await entered.wait()

        // A writer waits for every holder of the gate, so being let in while
        // the models read shows the read holds nothing.
        let admitted = MCPTestSignal()
        let writer = Task {
            await store.acquireToolOperation(.exclusive)
            await admitted.signal()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await admitted.hasSignaled, "a call waited behind a paper's models")
        await release.signal()
        await writer.value
        await store.releaseToolOperation()

        let outcome = try await finishing.value
        #expect(outcome.sourceID == staged.article.id)
        #expect(outcome.message.contains("read by the test"))
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.title == "Droplets, read")
        #expect(saved.hasPaperIngestionAttestation)
        #expect(pdfIsOnDisk(saved, in: dir))
    }

    @Test("Read in the background, a paper answers with a work_id listed until it is saved")
    func backgroundReadingIsListedRunningWork() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try await stage(store, pages: [Self.paperText], in: dir)

        let release = MCPTestSignal()
        let workID = store.startStagedLocalPaperReading(
            staged,
            tool: "import_local_pdf_as_paper",
            spendLimitUSD: nil
        ) { article, _ in
            await release.wait()
            article.author = "Zara Holt"
            _ = article.attestPaperMetadataExtractionAfterLLM()
            return "read in the background"
        }
        #expect(workID.hasPrefix("task-"))
        let entry = try #require(MCPRunningWork.shared.snapshot.first { $0.id == workID })
        #expect(entry.tool == "import_local_pdf_as_paper")
        #expect(entry.kind == .background)
        #expect(entry.spendLimitUSD == MCPRunningWork.defaultSpendLimitUSD)

        await release.signal()
        for _ in 0..<100 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == workID })
        let saved = try #require(try store.knowledgeStore().loadSourceForSync(staged.article.id))
        #expect(saved.hasPaperIngestionAttestation)
    }

    @Test("The waiting line lets its width through and hands each place on in turn")
    func waitingLineHandsPlacesOn() async throws {
        let line = MCPWaitingLine(width: 2)
        await line.enter()
        await line.enter()
        let third = MCPTestSignal()
        let waiter = Task {
            await line.enter()
            await third.signal()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await third.hasSignaled))
        #expect(await line.waitingCount == 1)
        await line.leave()
        await waiter.value
        #expect(await third.hasSignaled)
        #expect(await line.waitingCount == 0)
    }

    @Test("The paper imports gate only their own store stretches")
    func paperImportsAreSelfGated() {
        for name in ["import_local_pdf_as_paper", "import_local_file"] {
            #expect(MCPToolRegistry.selfGatedToolNames.contains(name), "\(name)")
            #expect(MCPToolRegistry.paidWorkToolNames.contains(name), "\(name)")
        }
    }
}

#endif

@Suite("create_notebook without a title")
struct MCPCreateNotebookNamingTests {
    @Test("No title makes an unnamed notebook ForeverLM names; a title or summary given is the learner's")
    func createsUnnamed() async throws {
        let tmpPath = NSTemporaryDirectory() + "MCPCreateNotebookNamingTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let suiteName = "MCPCreateNotebookNamingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = activeNotebookID }
        let store = MCPDataStore(dbPath: tmpPath + "/knowledge.db")

        try await NotebookNamingRows.$overrideDefaults.withValue(NotebookNamingRows.DefaultsOverride(defaults: defaults)) {
            func create(title: String?, summary: String? = nil) async throws -> LearningGoalRecord {
                let text = try await store.createNotebook(
                    title: title, description: nil, summary: summary, topic: nil, endDateString: "",
                    sourceIDs: [], dailyTarget: nil, discover: false
                )
                let id = try #require(createdNotebookID(in: text))
                return try #require(try store.knowledgeStore().loadLearningGoal(id))
            }
            let unnamed = try await create(title: nil)
            #expect(unnamed.isNotebook)
            #expect(unnamed.title == "New notebook")
            #expect(NotebookNamingRows.mark(notebookID: unnamed.id) == .unnamed(title: "New notebook"))
            // Two unnamed notebooks are no duplicate: the second is numbered.
            let second = try await create(title: "  ")
            #expect(second.title == "New notebook 2")

            let named = try await create(title: "Complex I assembly")
            #expect(NotebookNamingRows.mark(notebookID: named.id) == nil)
            let described = try await create(title: nil, summary: "My own line")
            #expect(NotebookNamingRows.mark(notebookID: described.id) == nil)

            // A name given later is the learner's: ForeverLM never renames it.
            _ = try await store.updateNotebook(
                notebookID: unnamed.id, title: "Leigh syndrome", description: nil, topic: nil,
                endDateString: nil, openEnded: nil, dailyTarget: nil, discover: nil
            )
            #expect(NotebookNamingRows.mark(notebookID: unnamed.id) == nil)

            await #expect(throws: MCPError.self) {
                _ = try await store.createNotebook(
                    title: nil, description: nil, topic: nil, endDateString: "",
                    sourceIDs: [], dailyTarget: nil, discover: true
                )
            }
        }

        let createTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_notebook" })
        #expect((createTool.inputSchema["required"] as? [String]) == [])
    }
}

/// The Canvas's Heptabase parity build over MCP (docs/knowledge-map-design.md,
/// "Over MCP"): the four new tools and the fields the existing ones gained, as
/// a connector sees them in the registry. What each does to a canvas is in
/// `KnowledgeMapMCPParityTests`.
@Suite("MCP Canvas parity tools")
struct MCPCanvasParityContractTests {
    private func tool(_ name: String) throws -> MCPToolDef {
        try #require(MCPToolRegistry.shared.tools.first { $0.name == name }, "\(name) is not registered")
    }

    private func properties(_ name: String) throws -> [String: Any] {
        try #require(try tool(name).inputSchema["properties"] as? [String: Any])
    }

    private func property(_ tool: String, _ field: String) throws -> [String: Any] {
        try #require(try properties(tool)[field] as? [String: Any], "\(tool) has no \(field)")
    }

    @Test("update_canvas_card and arrange_on_canvas edit the Canvas on the learner's word, off the store gate, and take what the contract names")
    func editTools() throws {
        for name in ["update_canvas_card", "arrange_on_canvas"] {
            #expect(MCPToolRegistry.canvasEditToolNames.contains(name))
            #expect(!MCPToolRegistry.knowledgeMapToolNames.subtracting(MCPToolRegistry.canvasEditToolNames).contains(name))
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full) && !MCPToolRegistry.isToolAllowed(name, scope: .ingest))
            #expect(try tool(name).description.contains("Undo"), "\(name) says its edit is one Undo step")
            #expect(try tool(name).description.contains("on the learner's word"))
            // A mutating tool keeps its blank arguments as sent.
            #expect(MCPToolRegistry.normalizedArguments(toolName: name, arguments: ["color": ""])["color"] as? String == "")
            #expect(try tool(name).inputSchema["required"] as? [String] == ["item_ids"])
        }
        let card = try properties("update_canvas_card")
        #expect(Set(card.keys) == ["item_ids", "color", "folded", "w", "h", "fit_to_content", "page", "annotation", "plain", "answered"])
        #expect((card["item_ids"] as? [String: Any])?["maxItems"] as? Int == 200)
        #expect(try property("update_canvas_card", "w")["type"] as? String == "number")
        #expect(try property("update_canvas_card", "folded")["type"] as? String == "boolean")
        let arrange = try properties("arrange_on_canvas")
        #expect(Set(arrange.keys) == ["item_ids", "arrangement", "align"])
        #expect((arrange["arrangement"] as? [String: Any])?["enum"] as? [String] == ["row", "column", "grid"])
        #expect((arrange["align"] as? [String: Any])?["enum"] as? [String] == ["left", "center", "right", "top", "middle", "bottom"])
        #expect((arrange["item_ids"] as? [String: Any])?["minItems"] as? Int == 2)
    }

    @Test("lint_canvas and screenshot_canvas only look: read-only, off the gate, in the Canvas's reads and not its edits")
    func lookingTools() throws {
        for name in ["lint_canvas", "screenshot_canvas"] {
            #expect(MCPToolRegistry.knowledgeMapToolNames.contains(name))
            #expect(!MCPToolRegistry.canvasEditToolNames.contains(name))
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(try tool(name).inputSchema["required"] as? [String] == [])
            // A read-only tool drops a blank argument a model filled in.
            #expect(MCPToolRegistry.normalizedArguments(toolName: name, arguments: ["limit": "", "scale": " "]).isEmpty)
        }
        #expect(Set(try properties("lint_canvas").keys) == ["limit"])
        let lint = try tool("lint_canvas").description
        for kind in ["overlap", "card_outside_region", "arrow_over_card", "empty_region"] { #expect(lint.contains(kind)) }
        #expect(Set(try properties("screenshot_canvas").keys) == ["scale", "item_ids"])
        let shot = try tool("screenshot_canvas").description
        #expect(shot.contains("Exports/") && shot.contains("file_path") && shot.contains("width") && shot.contains("4 MB"))
        #expect(shot.contains("showing on the Mac"), "it says it needs the Canvas on screen")
    }

    @Test("place_on_canvas takes a look for the cards it sets down, and create_canvas_region a lock")
    func placeAndCreate() throws {
        let place = try properties("place_on_canvas")
        for field in ["color", "folded", "w", "h"] { #expect(place[field] != nil, "place_on_canvas lacks \(field)") }
        #expect(try property("create_canvas_region", "locked")["type"] as? String == "boolean")
        #expect(try tool("place_on_canvas").inputSchema["required"] as? [String] == ["item_ids"])
        // The new kinds are named where cards are.
        for name in ["place_on_canvas", "take_off_canvas", "create_canvas_region", "focus_map", "apply_map_lens"] {
            let text = String(describing: try tool(name).inputSchema)
            #expect(text.contains("canvas:<canvas_id>") && text.contains("chat:<session_id>") && text.contains("picture:<image_id>"), "\(name)")
        }
    }

    @Test("update_canvas_region takes a lock, a layout, a fit and a grow")
    func regionFields() throws {
        let region = try properties("update_canvas_region")
        #expect(region["locked"] != nil && region["fit_to_content"] != nil)
        #expect((region["layout"] as? [String: Any])?["enum"] as? [String] == ["free", "tree"])
        #expect((region["grow_to_hold"] as? [String: Any])?["type"] as? String == "array")
        #expect(try tool("update_canvas_region").inputSchema["required"] as? [String] == ["region"])
        let description = try tool("update_canvas_region").description
        #expect(description.contains("locked") && description.contains("mind map") && description.contains("200 by 120"))
    }

    @Test("Arrows take a route, dashes, heads, a colour and a branch, and end at regions; update_canvas_arrow no longer needs a label")
    func arrowFields() throws {
        for name in ["draw_canvas_arrow", "update_canvas_arrow"] {
            let arrow = try properties(name)
            #expect((arrow["route"] as? [String: Any])?["enum"] as? [String] == ["curve", "straight", "elbow"], "\(name)")
            #expect((arrow["heads"] as? [String: Any])?["enum"] as? [String] == ["end", "both", "none"], "\(name)")
            for field in ["dashed", "color", "tree", "label"] { #expect(arrow[field] != nil, "\(name) lacks \(field)") }
        }
        #expect(try tool("draw_canvas_arrow").inputSchema["required"] as? [String] == ["from", "to"])
        #expect(try tool("update_canvas_arrow").inputSchema["required"] as? [String] == [], "a style change needs no label")
        for name in ["draw_canvas_arrow", "update_canvas_arrow", "delete_canvas_arrow"] {
            #expect(String(describing: try tool(name).inputSchema).contains("region:<region_id>"), "\(name) names region ends")
        }
        #expect(try tool("draw_canvas_arrow").description.contains("survives its cards leaving"))
    }

    @Test("build_canvas takes mind maps as trees, arrows with a look, and the new kinds by item_id")
    func buildCanvasFields() throws {
        let trees = try property("build_canvas", "trees")
        #expect(trees["type"] as? String == "array")
        let item = try #require(trees["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["name", "root"])
        let root = try #require((item["properties"] as? [String: Any])?["root"] as? [String: Any])
        #expect(root["required"] as? [String] == ["title"])
        let rootFields = try #require(root["properties"] as? [String: Any])
        #expect(Set(rootFields.keys) == ["key", "title", "text", "children"])
        let arrows = try #require(try property("build_canvas", "arrows")["items"] as? [String: Any])
        let arrowFields = try #require(arrows["properties"] as? [String: Any])
        for field in ["route", "dashed", "heads", "color"] { #expect(arrowFields[field] != nil) }
        let description = try tool("build_canvas").description
        #expect(description.contains("mind map") && description.contains("canvas:<id>") && description.contains("picture:<image_id>"))
        #expect(try tool("build_canvas").inputSchema["required"] as? [String] == [])
    }

    @Test("get_knowledge_map says what it now reports")
    func readsMore() throws {
        let description = try tool("get_knowledge_map").description
        for word in ["rect", "folded", "locked", "tree", "route", "heads", "region:<region_id>", "canvas:<canvas_id>", "chat:<session_id>", "picture:<image_id>"] {
            #expect(description.contains(word), "get_knowledge_map does not mention \(word)")
        }
    }

    @Test("No Canvas tool publishes a schema the Claude API refuses: no top-level anyOf, oneOf or allOf")
    func noTopLevelAlternatives() throws {
        let canvasTools = MCPToolRegistry.knowledgeMapToolNames
        #expect(canvasTools.count >= 18)
        for name in canvasTools {
            let schema = try tool(name).inputSchema
            #expect(schema["type"] as? String == "object", "\(name)")
            for forbidden in ["anyOf", "oneOf", "allOf", "not", "enum"] { #expect(schema[forbidden] == nil, "\(name) has a top-level \(forbidden)") }
        }
    }

    @Test("The published catalogue carries the four new tools and the fields the old ones gained")
    func catalogue() throws {
        let data = try Data(contentsOf: MCPToolContractTests.catalogueURL)
        let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let names = Set(entries.compactMap { $0["name"] as? String })
        for name in ["update_canvas_card", "arrange_on_canvas", "lint_canvas", "screenshot_canvas"] { #expect(names.contains(name), "\(name)") }
    }
}
