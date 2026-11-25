import Foundation

// MARK: - The Plugins place's pages

/// One page in the Plugins place: a built-in plugin's own page, or Your
/// Plugins', where the learner's own ingest plugins are set up. The Plugins
/// place is Codex's (product owner, 2026-10-13: "so you can take plugins out of
/// settings actually and put it similarly to codex"): a directory of every
/// plugin with its state, and each plugin's page inside it.
///
/// The raw values are the ids `open_settings` has always taken for these
/// pages, and the web's Plugins place names its rows by the same ids, so
/// they never change.
enum PluginPage: String, CaseIterable, Sendable {
    case x
    case youtube
    case googleDrive = "google_drive"
    case appleCalendar = "apple_calendar"
    case slack
    case linear
    case github
    case notion
    /// Your Plugins: the learner's own ingest plugins and how to build one.
    case yourPlugins = "build_your_own_plugin"

    /// The built-in plugins, in the directory's order.
    static let builtIn: [PluginPage] = [.x, .youtube, .googleDrive, .appleCalendar, .slack, .linear, .github, .notion]

    /// The name the directory and the page give it.
    var title: String {
        switch self {
        case .x: return "X"
        case .youtube: return "YouTube"
        case .googleDrive: return "Google Drive"
        case .appleCalendar: return "Calendar"
        case .slack: return "Slack"
        case .linear: return "Linear"
        case .github: return "GitHub"
        case .notion: return "Notion"
        case .yourPlugins: return "Build Your Own"
        }
    }

    /// What it reads, in one line: the page's description under its name.
    var about: String {
        switch self {
        case .x: return "Sync bookmarks into Studio."
        case .youtube: return "Import Liked videos or a playlist named ForeverLM."
        case .googleDrive: return "Import meeting recordings and transcripts from a folder you choose."
        case .appleCalendar: return "Your Mac's calendars, for the Now chip and planning in a chat."
        case .slack: return "Read preparation material from channels you choose."
        case .linear: return "Read issues, teams and projects as you. Read-only."
        case .github: return "Read repositories, issues and pull requests as you. Read-only."
        case .notion: return "Read the pages and databases you share as you. Read-only."
        case .yourPlugins: return "Add sources from any service your own plugin can reach."
        }
    }

    /// The ForeverLM tools this plugin brings to a chat and to an assistant
    /// over MCP, in the order its page lists them under Includes (Codex's
    /// plugin page lists the MCP servers a plugin includes). Empty
    /// for a plugin that brings none of its own: Google Drive's recordings
    /// arrive as sources, and every plugin's connect state is
    /// `get_plugin_connections` and `disconnect_plugin`.
    var includedTools: [String] {
        switch self {
        case .x:
            return ["create_x_post"]
        case .youtube:
            return [
                "follow_youtube_liked_videos", "follow_youtube_foreverlm_playlist", "follow_youtube_channel",
                "unfollow_youtube_channel", "import_youtube_playlist", "refresh_youtube_sources",
                "set_visibility", "set_connector_auto_import",
            ]
        case .googleDrive:
            return []
        case .appleCalendar:
            return [
                "get_calendar_events", "create_calendar_event", "update_calendar_event", "delete_calendar_event",
                "get_calendar_settings", "set_calendar_settings",
            ]
        case .slack:
            return ["list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages", "set_slack_channel_enabled"]
        case .linear:
            return ["list_linear_teams", "list_linear_projects", "list_linear_issues", "search_linear_issues", "get_linear_issue", "get_linear_project"]
        case .github:
            return [
                "list_github_repositories", "get_github_repository", "list_github_files", "read_github_file",
                "search_github_code", "list_github_issues", "get_github_issue", "list_github_pull_requests",
                "get_github_pull_request", "list_github_commits",
            ]
        case .notion:
            return ["search_notion", "get_notion_page", "list_notion_databases", "get_notion_database", "query_notion_database"]
        case .yourPlugins:
            return ["report_connector_status", "get_connector_inbox", "import_connector_paper", "remove_connector_sources"]
        }
    }
}

/// One connection a directory row's Disconnect can end: a plugin, and the
/// account or workspace of it when it holds several. It is the argument pair
/// `disconnect_plugin` takes, so the row does exactly what the page's own
/// Disconnect does.
struct PluginDisconnectTarget: Identifiable, Equatable, Sendable {
    /// `disconnect_plugin`'s `plugin`.
    let plugin: String
    /// Its `account_id`; nil for a plugin with one connection and nothing to
    /// tell apart (GitHub, Calendar, an older Google Drive sign-in).
    let accountID: String?
    /// The account or workspace's name, for the confirmation and for the menu
    /// when a plugin holds more than one.
    let label: String?

    var id: String { "\(plugin).\(accountID ?? "")" }

    /// Calendar is the Mac's own, so ForeverLM turns it off rather than
    /// disconnecting from a service.
    var isTurnOff: Bool { plugin == "apple_calendar" }
    var verb: String { isTurnOff ? "Turn Off" : "Disconnect" }
}

// MARK: - Where the place is

/// Where a window is in the Plugins place: the plugins' directory or one
/// plugin's page. A window's own, like the course it shows.
enum PluginsPlaceLocation: Hashable, Sendable {
    case directory
    case plugin(PluginPage)

    /// The plugin whose page this is, or nil.
    var pluginPage: PluginPage? {
        if case .plugin(let page) = self { return page }
        return nil
    }
}

// MARK: - Links

/// A `foreverlm://` address for a place in the Plugins place, which a
/// plugin's Copy Link puts on the pasteboard and the app opens again:
/// `foreverlm://plugins`, `foreverlm://plugins/slack`.
enum PluginsPlaceLink: Equatable, Sendable {
    case plugins(PluginPage?)

    static let scheme = "foreverlm"

    var url: URL {
        switch self {
        case .plugins(let page):
            return URL(string: "\(Self.scheme)://plugins" + (page.map { "/\($0.rawValue)" } ?? ""))!
        }
    }

    /// The place `url` addresses, or nil for any other address. An unknown
    /// plugin id is nil rather than the list, so a mistyped link says so.
    /// The product scheme is the written form; the running build's own
    /// (`foreverlm-dev`) reads too, as `StudioEntityLink` reads both.
    static func parse(_ url: URL) -> PluginsPlaceLink? {
        guard let urlScheme = url.scheme?.lowercased(),
              urlScheme == scheme || urlScheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              url.host?.lowercased() == "plugins" else { return nil }
        let rest = url.pathComponents.filter { $0 != "/" }
        guard rest.count <= 1 else { return nil }
        guard let id = rest.first else { return .plugins(nil) }
        return PluginPage(rawValue: id.lowercased()).map { .plugins($0) }
    }
}
