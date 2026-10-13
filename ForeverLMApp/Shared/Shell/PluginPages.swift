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
}
