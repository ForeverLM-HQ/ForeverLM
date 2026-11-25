import AppKit
import SwiftUI

// MARK: - Plugins in the chat composer

/// A workspace plugin the chat can read live — Slack, Linear, GitHub,
/// Notion — as the composer sees it: an `@` mention while it is connected,
/// offered by the popup the moment an `@` starts a word, the way Claude's
/// composer takes an `@` for a plugin. No brand mark sits in the composer's chrome; the mark
/// is drawn on the popup row and on the mention itself. Connection lives on
/// the MCP gateway, so `ChatPluginPresence` asks it; the Mac holds no
/// credential.
typealias ChatPlugin = ChatPluginRequest.Plugin

/// An `@` mention the composer offers: a connected plugin and the one-line
/// description its popup row shows.
struct ReviewComposerMention: Equatable, Identifiable {
    let plugin: ChatPlugin
    let summary: String

    var id: String { plugin.rawValue }
}

extension ChatPluginRequest.Plugin: Identifiable {
    var id: String { rawValue }

    var title: String {
        switch self {
        case .slack: return "Slack"
        case .linear: return "Linear"
        case .github: return "GitHub"
        case .notion: return "Notion"
        }
    }

    /// The mention's name, without the `@`.
    var mentionName: String { rawValue }

    /// The mention as it reads in the composer and the popup.
    var mentionToken: String { "\(ChatPluginRequest.Mention.sigil)\(mentionName)" }

    /// The plugin's page in the Plugins place.
    var pluginPage: PluginPage {
        switch self {
        case .slack: return .slack
        case .linear: return .linear
        case .github: return .github
        case .notion: return .notion
        }
    }

    var iconAssetName: String {
        switch self {
        case .slack: return "SlackIcon"
        case .linear: return "LinearIcon"
        case .github: return "GitHubIcon"
        case .notion: return "NotionIcon"
        }
    }

    /// GitHub's and Notion's marks are black on light and white on dark, so
    /// they are drawn as templates in the foreground colour; the other two
    /// carry their own colours.
    var iconIsTemplate: Bool { self == .github || self == .notion }

    /// The tool a chat must carry for the mention to be answerable. Study-mode
    /// chats carry a smaller tool surface than agent chats
    /// (`ReviewSessionManager.studySurfaceToolNames`), so the mention is offered
    /// exactly where the model could act on it.
    var requiredToolName: String {
        switch self {
        case .slack: return "read_slack_channel"
        case .linear: return "search_linear_issues"
        case .github: return "list_github_repositories"
        case .notion: return "search_notion"
        }
    }

    /// The plugins a chat in `mode` can answer for, in display order.
    static func availablePlugins(for mode: ReviewSessionManager.InitialPromptMode) -> [ChatPlugin] {
        allCases.filter { plugin in
            mode == .assistant || ReviewSessionManager.studySurfaceToolNames.contains(plugin.requiredToolName)
        }
    }

    /// The popup's one-line description. Slack names the workspaces behind it
    /// when the gateway has told us, since more than one can be connected.
    func mentionSummary(slackWorkspaces: [String]) -> String {
        switch self {
        case .slack:
            let named = slackWorkspaces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !named.isEmpty else { return "Ask Slack, read live" }
            return "Ask Slack · \(ListFormatter.localizedString(byJoining: named))"
        case .linear:
            return "Ask Linear about issues, teams and projects"
        case .github:
            return "Ask GitHub about repositories, issues and pull requests"
        case .notion:
            return "Ask Notion about the pages and databases you shared"
        }
    }

    /// The question a bare mention asks. GitHub reads the Notebook's repository
    /// when the chat has one; without one it starts from what the learner can see.
    func defaultRequest(repository: String?) -> String {
        switch self {
        case .slack:
            return "What has been posted in my Slack channels recently? Read the channels live and summarize what each has been discussing."
        case .linear:
            return "Show my open Linear issues, newest first, and say which are in progress."
        case .github:
            if let repository = repository?.trimmingCharacters(in: .whitespacesAndNewlines), !repository.isEmpty {
                return "Summarize recent activity in \(repository): the latest commits, open pull requests and open issues."
            }
            return "List the GitHub repositories I can read and say which have had activity recently."
        case .notion:
            return "What changed recently in my Notion workspace? List the most recently edited pages and databases and say what each is about."
        }
    }

    /// The mention row the popup offers for this plugin.
    func mention(slackWorkspaces: [String]) -> ReviewComposerMention {
        ReviewComposerMention(plugin: self, summary: mentionSummary(slackWorkspaces: slackWorkspaces))
    }

    /// The tint the composer paints the `@name` token in.
    var composerTokenColor: NSColor {
        switch self {
        case .slack: return .systemPurple
        case .linear: return .systemIndigo
        case .github: return .labelColor
        case .notion: return .labelColor
        }
    }
}

// MARK: - Which plugins are connected

/// The connection state of the workspace plugins, as the gateway last
/// reported it, shared by every chat pane so the answer is fetched once rather
/// than per composer. Four round trips run together; one that fails keeps what
/// it last knew, so a gateway blip never makes a connected Slack disappear
/// from the composer for a moment.
@MainActor
@Observable
final class ChatPluginPresence {
    static let shared = ChatPluginPresence()

    /// Plugins the gateway reports connected for this account.
    private(set) var connected: Set<ChatPlugin> = []
    /// The Slack workspaces behind the connection, for the mention's summary.
    private(set) var slackWorkspaces: [String] = []

    /// How long an answer is trusted before the composer asks again. Connecting
    /// happens on the web, so the app re-asks when it comes back to the front.
    static let staleAfter: TimeInterval = 60

    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init() {}

    /// The connected plugins a chat in `mode` can act on, in display order.
    func plugins(availableIn mode: ReviewSessionManager.InitialPromptMode) -> [ChatPlugin] {
        ChatPlugin.availablePlugins(for: mode).filter { connected.contains($0) }
    }

    func refreshIfStale(now: Date = Date()) async {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.staleAfter { return }
        await refresh()
    }

    /// Asks the gateway once; concurrent callers share the one request.
    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load() async {
        // The four answer .signedOut themselves when there is no managed
        // session, and each is a nonisolated async call, so the Keychain read
        // and the network round trips stay off the main actor.
        async let slack = MCPDataStore.slackWorkspaceConnection()
        async let linear = MCPDataStore.linearConnection()
        async let github = MCPDataStore.githubConnection()
        async let notion = MCPDataStore.notionConnection()
        let answers = await (slack: slack, linear: linear, github: github, notion: notion)
        let next = Self.apply(
            slack: answers.slack,
            linear: answers.linear,
            github: answers.github,
            notion: answers.notion,
            to: (connected: connected, slackWorkspaces: slackWorkspaces)
        )
        connected = next.connected
        slackWorkspaces = next.slackWorkspaces
        lastRefresh = Date()
    }

    /// Pure: folds the gateway's four answers into the last known state. `nil`
    /// — the gateway could not be reached — leaves that plugin as it was.
    static func apply(
        slack: MCPDataStore.SlackWorkspaceConnection?,
        linear: MCPDataStore.LinearConnection?,
        github: MCPDataStore.GitHubConnection?,
        notion: MCPDataStore.NotionConnection? = nil,
        to previous: (connected: Set<ChatPlugin>, slackWorkspaces: [String])
    ) -> (connected: Set<ChatPlugin>, slackWorkspaces: [String]) {
        var connected = previous.connected
        var workspaces = previous.slackWorkspaces
        if let slack {
            if case .connected(let named) = slack {
                connected.insert(.slack)
                workspaces = named.map(\.name)
            } else {
                connected.remove(.slack)
                workspaces = []
            }
        }
        if let linear {
            if linear.isConnected { connected.insert(.linear) } else { connected.remove(.linear) }
        }
        if let github {
            if github.isConnected { connected.insert(.github) } else { connected.remove(.github) }
        }
        if let notion {
            if notion.isConnected { connected.insert(.notion) } else { connected.remove(.notion) }
        }
        return (connected, workspaces)
    }
}

// MARK: - The card that connects a plugin from the transcript

/// What a chat draws under a step that failed because its plugin was not
/// there to read with: the plugin's mark, one line on what is missing, and
/// the button that opens that plugin's page in Plugins, where connecting,
/// reconnecting and adding an organisation live. The chat never sends the
/// learner to sign in to the service in the Browser — the plugin reads it as
/// them once it is connected (product owner, 2026-09-14: "it should ask to set up
/// the github connector").
struct ChatPluginSetupCard: View {
    let need: ChatPluginRequest.SetupNeed

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ChatPluginMark(plugin: need.plugin, size: 18)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(need.title)
                    .font(.callout.weight(.medium))
                Text(need.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(need.actionTitle) {
                need.openSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(need.actionHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(need.title). \(need.body)")
        .accessibilityIdentifier("mac.chatPluginSetup.\(need.plugin.rawValue)")
    }
}

extension ChatPluginRequest.SetupNeed {
    /// Where the button goes.
    enum Destination: Equatable {
        /// Settings, at API Keys, where signing in is, when the Mac is not
        /// signed in at all.
        case settings(SettingsPane)
        /// The plugin's own page in the Plugins place.
        case plugin(PluginPage)
    }

    /// Opens where the card's button goes: the plugin's page, or Settings.
    @MainActor
    func openSetup() {
        switch destination {
        case .settings(let pane):
            NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
        case .plugin(let page):
            PluginsPlace.requestOpen(page)
        }
    }

    var destination: Destination {
        kind == .signIn ? .settings(.aiKeys) : .plugin(plugin.pluginPage)
    }

    var title: String {
        switch kind {
        case .connect: return "\(plugin.title) isn't connected"
        case .installOrganisation: return "The ForeverLM GitHub App isn't installed there"
        case .reconnect: return "\(plugin.title) needs reconnecting"
        case .signIn: return "Sign in to read \(plugin.title)"
        }
    }

    var body: String {
        switch kind {
        case .connect:
            return "ForeverLM reads \(plugin.title) as you, through a read-only connection. Connect it in Plugins › \(plugin.title)."
        case .installOrganisation:
            return "GitHub is connected, but ForeverLM reads only the organisations and accounts where its App is installed. Add the one that owns this repository."
        case .reconnect:
            return "\(plugin.title) no longer honours ForeverLM's connection. Reconnect it in Plugins › \(plugin.title)."
        case .signIn:
            return "ForeverLM reads \(plugin.title) through your ForeverLM account, so this Mac has to be signed in with Apple."
        }
    }

    var actionTitle: String {
        switch kind {
        case .connect: return "Connect \(plugin.title)…"
        case .installOrganisation: return "Add an Organisation…"
        case .reconnect: return "Reconnect…"
        case .signIn: return "Sign in…"
        }
    }

    var actionHelp: String {
        kind == .signIn
            ? "Open Settings to sign in with Apple"
            : "Open Plugins › \(plugin.title)"
    }
}

// MARK: - The mark on a mention

/// A plugin's mark at composer-chrome size, drawn on its popup row.
struct ChatPluginMark: View {
    let plugin: ChatPlugin
    var size: CGFloat = 13

    var body: some View {
        if plugin.iconIsTemplate {
            Image(plugin.iconAssetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
        } else {
            Image(plugin.iconAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
