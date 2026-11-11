// The MCP auth scope tests: which scopes each tool and client kind needs.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

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
        // Tool aliases resolve before the check, so an old name can't slip past.
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
            "list_running_ai_work", "cancel_ai_work", "resume_ai_work", "cancel_source_audio_generation",
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
            "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video",
            "find_podcast_on_youtube", "import_podcast_youtube_transcript",
            "get_linked_references", "get_block", "get_daily_note", "append_to_daily_note", "get_plan",
            "practice_cards",
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
        // Every read can address one connected workspace or, omitted, all of them.
        for name in linear {
            let properties = byName[name]?.inputSchema["properties"] as? [String: Any]
            #expect((properties?["workspace"] as? [String: Any])?["type"] as? String == "string", "\(name) lacks workspace")
            #expect((byName[name]?.inputSchema["required"] as? [String])?.contains("workspace") != true)
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
        #expect(MCPDataStore.linearConnection(in: ["connected": true]) == .connected(workspaces: []))
        #expect(MCPDataStore.linearConnection(in: ["connected": false, "configured": true]) == .notConnected)
        #expect(MCPDataStore.linearConnection(in: ["error": "x"]) == nil)
        // The workspace and user the gateway reports travel with the state, so
        // the plugins list can say which workspace is read and as whom. A
        // workspace without a name falls back to its URL key.
        #expect(MCPDataStore.linearConnection(in: [
            "connected": true,
            "workspaces": [["id": "org_1", "name": "Bench Lab", "url_key": "benchlab", "user": ["name": "Robin Vale"]]],
        ]) == .connected(workspaces: [.init(id: "org_1", name: "Bench Lab", urlKey: "benchlab", user: "Robin Vale")]))
        #expect(MCPDataStore.linearConnection(in: [
            "connected": true,
            "workspaces": [["id": "org_1", "name": NSNull(), "url_key": "benchlab", "user": ["name": " "]]],
        ]) == .connected(workspaces: [.init(id: "org_1", name: nil, urlKey: "benchlab", user: nil)]))
        // Several workspaces arrive as a list, each its own grant, in order.
        let twoLinear = MCPDataStore.linearConnection(in: [
            "connected": true,
            "workspaces": [
                ["id": "org_1", "name": "Bench Lab", "url_key": "benchlab", "user": ["name": "Robin Vale"]],
                ["id": "org_2", "name": "Acme Lab", "url_key": "acmelab", "user": ["name": "Zara Holt"]],
                ["name": "No id"],
            ],
        ])
        #expect(twoLinear?.workspaces.map(\.id) == ["org_1", "org_2"])
        #expect(twoLinear?.workspaces.map(\.label) == ["Bench Lab", "Acme Lab"])
        #expect(twoLinear?.workspaces.last?.user == "Zara Holt")
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
        for name in ["search_notion", "get_notion_page", "list_notion_databases", "get_notion_database", "query_notion_database"] {
            let properties = byName[name]?.inputSchema["properties"] as? [String: Any]
            #expect((properties?["workspace"] as? [String: Any])?["type"] as? String == "string", "\(name) lacks workspace")
        }
        #expect((queryProperties?["filter"] as? [String: Any])?["type"] as? String == "object")
        #expect((queryProperties?["sorts"] as? [String: Any])?["type"] as? String == "array")
        #expect(byName["search_notion"]?.description.contains("only way into Notion") == true)

        // The connection state is read off the gateway's status payload, and a
        // payload without the field is unknown rather than a guess.
        #expect(MCPDataStore.notionConnection(in: ["connected": true]) == .connected(workspaces: []))
        #expect(MCPDataStore.notionConnection(in: ["connected": false, "configured": true]) == .notConnected)
        #expect(MCPDataStore.notionConnection(in: ["error": "x"]) == nil)
        #expect(MCPDataStore.notionConnection(in: [
            "connected": true,
            "workspaces": [["id": "ws", "name": "Bench Lab", "icon": NSNull(), "user": ["id": "u", "name": "Robin Vale"]]],
        ]) == .connected(workspaces: [.init(id: "ws", name: "Bench Lab", user: "Robin Vale")]))
        #expect(MCPDataStore.notionConnection(in: ["connected": true, "workspaces": [["id": "ws", "name": ""]]])
            == .connected(workspaces: [.init(id: "ws", name: nil, user: nil)]))
        // Several workspaces arrive as a list, each its own grant, in order.
        let twoNotion = MCPDataStore.notionConnection(in: [
            "connected": true,
            "workspaces": [
                ["id": "ws_1", "name": "Bench Lab", "user": ["name": "Robin Vale"]],
                ["id": "ws_2", "name": "Acme Lab"],
            ],
        ])
        #expect(twoNotion?.workspaces.map(\.id) == ["ws_1", "ws_2"])
        #expect(twoNotion?.workspaces.last?.user == nil)
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
        #expect(PluginScopeCopy.x(accounts: []) == nil)
        #expect(PluginScopeCopy.x(accounts: [XAccount(id: "1", username: nil)]) == nil)
        #expect(PluginScopeCopy.x(accounts: [XAccount(id: "1", username: " ")]) == nil)
        #expect(PluginScopeCopy.x(accounts: [XAccount(id: "1", username: "robin")]) == "Imports bookmarks and saved posts from @robin.")
        #expect(PluginScopeCopy.x(accounts: [XAccount(id: "1", username: "robin"), XAccount(id: "2", username: nil)])
            == "Imports bookmarks and saved posts from 2 accounts.")

        #expect(PluginScopeCopy.youtube(sources: [], followedChannels: 0) == nil)
        #expect(PluginScopeCopy.youtube(sources: ["Liked videos"], followedChannels: 0) == "Imports your Liked videos.")
        #expect(PluginScopeCopy.youtube(sources: [], followedChannels: 1) == "Follows 1 channel.")
        #expect(PluginScopeCopy.youtube(sources: ["ForeverLM playlist"], followedChannels: 3)
            == "Imports your ForeverLM playlist and follows 3 channels.")
        // Two accounts reading the same source name it once.
        #expect(PluginScopeCopy.youtube(sources: ["Liked videos", "Liked videos"], followedChannels: 0)
            == "Imports your Liked videos.")

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

        #expect(PluginScopeCopy.linear([]) == nil)
        #expect(PluginScopeCopy.linear([.init(id: "1", name: "Bench Lab", urlKey: nil, user: "Robin Vale")]) == "Reads the Bench Lab workspace as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.linear([.init(id: "1", name: "Bench Lab", urlKey: nil, user: nil)]) == "Reads the Bench Lab workspace. Read-only.")
        #expect(PluginScopeCopy.linear([.init(id: "1", name: nil, urlKey: nil, user: "Robin Vale")]) == "Reads Linear as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.linear([
            .init(id: "1", name: "Bench Lab", urlKey: nil, user: "Robin Vale"),
            .init(id: "2", name: nil, urlKey: "acmelab", user: nil),
        ]) == "Reads the Bench Lab and acmelab workspaces. Read-only.")

        #expect(PluginScopeCopy.github(login: nil, installations: []) == nil)
        #expect(PluginScopeCopy.github(login: "robinvale", installations: ["ForeverLM-HQ", "robinvale"])
            == "Reads ForeverLM-HQ and robinvale as @robinvale. Read-only.")
        #expect(PluginScopeCopy.github(login: "robinvale", installations: []) == "Reads GitHub as @robinvale. Read-only.")
        #expect(PluginScopeCopy.github(login: nil, installations: ["ForeverLM-HQ"]) == "Reads ForeverLM-HQ. Read-only.")

        #expect(PluginScopeCopy.notion([]) == nil)
        #expect(PluginScopeCopy.notion([.init(id: "1", name: "Bench Lab", user: "Robin Vale")]) == "Reads the Bench Lab workspace as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.notion([.init(id: "1", name: "Bench Lab", user: nil)]) == "Reads the Bench Lab workspace. Read-only.")
        #expect(PluginScopeCopy.notion([.init(id: "1", name: nil, user: "Robin Vale")]) == "Reads Notion as Robin Vale. Read-only.")
        #expect(PluginScopeCopy.notion([
            .init(id: "1", name: "Bench Lab", user: nil),
            .init(id: "2", name: "Acme Lab", user: nil),
        ]) == "Reads the Bench Lab and Acme Lab workspaces. Read-only.")
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

#endif
