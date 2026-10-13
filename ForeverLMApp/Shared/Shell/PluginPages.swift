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
    /// plugin page lists the MCP servers and skills a plugin includes). Empty
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
                "set_youtube_channel_hidden", "set_connector_auto_import",
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

// MARK: - Where the place is

/// The Plugins place's two lists and the pages under them, as Codex's
/// Plugins | Skills tabs (`skills.appsPage.browseTabs`): the plugins'
/// directory and each plugin's page; the learner's skills, one skill's page,
/// and a new skill being written. A window's own, like the course it shows.
enum PluginsPlaceLocation: Hashable, Sendable {
    case directory
    case plugin(PluginPage)
    case skills
    /// A skill's page, by its id (`SkillRecord.id`).
    case skill(String)
    case newSkill

    /// Which of the two lists this is, or is under.
    var tab: PluginsPlaceTab {
        switch self {
        case .directory, .plugin: return .plugins
        case .skills, .skill, .newSkill: return .skills
        }
    }

    /// The plugin whose page this is, or nil.
    var pluginPage: PluginPage? {
        if case .plugin(let page) = self { return page }
        return nil
    }

    /// The list itself rather than a page under it.
    var isList: Bool { self == .directory || self == .skills }

    /// The list a page goes back to.
    var list: PluginsPlaceLocation { tab.location }
}

/// The place's two tabs.
enum PluginsPlaceTab: String, CaseIterable, Sendable {
    case plugins
    case skills

    var title: String {
        switch self {
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        }
    }

    /// Codex's line under the title (`skills.appsPage.browseIntro`), with
    /// ForeverLM's name in it.
    var subtitle: String {
        switch self {
        case .plugins: return "Connect plugins to let ForeverLM work across your tools."
        case .skills: return "Extend ForeverLM with task-specific skills."
        }
    }

    var location: PluginsPlaceLocation { self == .plugins ? .directory : .skills }
}

// MARK: - Links

/// A `foreverlm://` address for a place in the Plugins place, which a plugin's
/// or a skill's Copy Link puts on the pasteboard and the app opens again:
/// `foreverlm://plugins`, `foreverlm://plugins/slack`, `foreverlm://skills`,
/// `foreverlm://skills/paper-walkthrough`. A skill is addressed by its name,
/// the handle the learner knows it by, and opens the newest skill of that
/// name (`[SkillRecord].skill(named:)`).
enum PluginsPlaceLink: Equatable, Sendable {
    case plugins(PluginPage?)
    case skills(name: String?)

    static let scheme = "foreverlm"

    var url: URL {
        switch self {
        case .plugins(let page):
            return URL(string: "\(Self.scheme)://plugins" + (page.map { "/\($0.rawValue)" } ?? ""))!
        case .skills(let name):
            let normalized = name.map(SkillRecord.normalizedName) ?? ""
            return URL(string: "\(Self.scheme)://skills" + (normalized.isEmpty ? "" : "/\(normalized)"))!
        }
    }

    /// The place `url` addresses, or nil for any other address. An unknown
    /// plugin id is nil rather than the list, so a mistyped link says so.
    /// The product scheme is the written form; the running build's own
    /// (`foreverlm-dev`) reads too, as `StudioEntityLink` reads both.
    static func parse(_ url: URL) -> PluginsPlaceLink? {
        guard let urlScheme = url.scheme?.lowercased(),
              urlScheme == scheme || urlScheme == ForeverLMRuntimeIdentity.urlScheme.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        let rest = url.pathComponents.filter { $0 != "/" }
        guard rest.count <= 1 else { return nil }
        switch host {
        case "plugins":
            guard let id = rest.first else { return .plugins(nil) }
            return PluginPage(rawValue: id.lowercased()).map { .plugins($0) }
        case "skills":
            guard let raw = rest.first else { return .skills(name: nil) }
            let name = SkillRecord.normalizedName(raw)
            return name.isEmpty ? nil : .skills(name: name)
        default:
            return nil
        }
    }
}

// MARK: - The skills list

/// What the Skills list shows: the learner's skills by name, those whose
/// name or description holds every word of the search (a leading / or $ on
/// a word is how the chat types a skill, so it is read past).
enum SkillsDirectory {
    static func rows(_ skills: [SkillRecord], query: String) -> [SkillRecord] {
        let words = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/$")) }
            .filter { !$0.isEmpty }
        let sorted = skills.sorted {
            $0.name == $1.name ? $0.updatedAt > $1.updatedAt : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard !words.isEmpty else { return sorted }
        return sorted.filter { skill in
            let haystack = "\(skill.name) \(skill.description)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// A skill being written on its page: the three fields as typed, and what
/// would stop it saving.
struct SkillDraft: Equatable, Sendable {
    var name: String
    var description: String
    var instructions: String

    init(name: String = "", description: String = "", instructions: String = "") {
        self.name = name
        self.description = description
        self.instructions = instructions
    }

    init(_ skill: SkillRecord) {
        self.init(name: skill.name, description: skill.description, instructions: skill.instructions)
    }

    /// A `SKILL.md` read into the fields: its name, description and
    /// instructions, each kept as typed where the file has none. nil when the
    /// text has no frontmatter.
    func filled(fromSkillMarkdown text: String) -> SkillDraft? {
        guard let parsed = SkillRecord.parseSkillMarkdown(text) else { return nil }
        return SkillDraft(
            name: parsed.name ?? name,
            description: parsed.description ?? description,
            instructions: parsed.instructions.isEmpty ? instructions : parsed.instructions
        )
    }

    /// The command the name becomes, as the chat will take it.
    var command: String { SkillRecord.normalizedName(name) }

    /// Why it cannot be saved, or nil: the record's own rules, then a name
    /// another skill holds (the store refuses that too; saying it here says
    /// it before Save).
    func problem(among skills: [SkillRecord], editing skillID: String?) -> String? {
        if let problem = SkillRecord.validationProblem(name: name, description: description, instructions: instructions) {
            return problem
        }
        if skills.contains(where: { $0.name == command && $0.id != skillID }) {
            return "Another skill is already called /\(command). Pick another name."
        }
        return nil
    }

    /// Whether it differs from what `skill` holds (or holds anything, for a
    /// new one): leaving it asks before throwing it away only then.
    func hasChanges(from skill: SkillRecord?) -> Bool {
        guard let skill else {
            return ![name, description, instructions].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return self != SkillDraft(skill)
    }
}
